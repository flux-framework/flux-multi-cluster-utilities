/************************************************************\
 * Copyright 2024 Lawrence Livermore National Security, LLC
 * (c.f. AUTHORS, NOTICE.LLNS, COPYING)
 *
 * This file is part of the Flux resource manager framework.
 * For details, see https://github.com/flux-framework.
 *
 * SPDX-License-Identifier: LGPL-3.0
\************************************************************/

/*
 * Jobtap plugin for delegating jobs to another Flux instance.
 */

#if HAVE_CONFIG_H
#include "config.h"
#endif

#include <inttypes.h>
#include <jansson.h>
#include <stdint.h>
#include <limits.h>
#include <unistd.h>
#include <errno.h>

#include <flux/core.h>
#include <flux/jobtap.h>
#include "delegate_job.h"

#include "src/common/libutil/idf58.h"
#include "src/common/libutil/eventlog.h"
#include "src/common/select/select.h"
#include "src/common/select/cluster_config.h"

#define DELEGATION_FAILURE_EXCEPTION "DelegationFailure"

static void submit_callback (flux_future_t *f, void *arg);
enum exception_action {
    JOB_EXCEPTION_IGNORED = 0, /* severity > 0: no effect, keep watching     */
    JOB_EXCEPTION_RESUBMITTED, /* severity 0, alloc: handed off to new target */
    JOB_EXCEPTION_TERMINAL,    /* severity 0, non-alloc: job really ends here */
    JOB_EXCEPTION_ERROR = -1   /* bad context or resubmit_job() itself failed */
};
/*
 * Callback firing when job has completed.
 */
static void restore_default_urgency (flux_plugin_t *p,
                                     flux_jobid_t *id,
                                     bool success,
                                     const char *errstr)
{
    if (success) {
        if (flux_jobtap_event_post_pack (p,
                                         *id,
                                         "urgency",
                                         "{s:i s:i}",
                                         "userid",
                                         getuid (),
                                         "urgency",
                                         FLUX_JOB_URGENCY_DEFAULT)
            < 0) {
            errstr = "error unable to update priority";
            flux_log (flux_jobtap_get_flux (p), LOG_DEBUG, "%s", errstr);
        } else {
            return;
        }
    }

    flux_jobtap_raise_exception (p, *id, DELEGATION_FAILURE_EXCEPTION, 0, "Error: %s", errstr);
}

static void cancel_callback (flux_future_t *f, void *arg)
{
    flux_plugin_t *p = arg;
    flux_t *h;
    const char *errstr;
    if (!(h = flux_jobtap_get_flux (p))) {
        flux_future_destroy (f);
        return;
    }
    if (!(errstr = flux_future_error_string (f))) {
        flux_future_destroy (f);
        return;
    }
    flux_log_error (h, "Target Instance job cancel failure, Error: %s", errstr);
    flux_future_destroy (f);
}

static int submit_job (flux_plugin_t *p, struct delegate_job_info *d)
{
    flux_t *h = flux_jobtap_get_flux (p);
    flux_future_t *jobid_future = NULL;
    flux_t *remote = NULL;
    const char *uri;
    char *errstr = "";

    if (!d || !d->job_cluster_config || !d->delegate_policy || !d->clean_jobspec) {
        flux_log_error (h, "empty delegate_job_info");
        return -1;
    }
    if (!(uri = select_cluster (d->job_cluster_config, d->delegate_policy))) {
        errstr = "could not select URI";
        flux_log_error (h, "%s", errstr);
        return -1;
    }
    if (!(remote = flux_open (uri, 0)) || flux_set_reactor (remote, flux_get_reactor (h)) < 0
        || delegate_set_uri (d, uri) < 0) {
        errstr = remote ? "could not attach reactor or record selected URI"
                        : "could not open delegate URI";
        flux_log_error (h, "%s: %s (%s): %s", idf58 (d->id), errstr, uri, strerror (errno));
        flux_close (remote);
        return -1;
    }

    if (!(jobid_future = flux_job_submit (remote, d->clean_jobspec, FLUX_JOB_URGENCY_DEFAULT, 0))
        || flux_future_then (jobid_future, -1, submit_callback, p) < 0
        || flux_future_aux_set (jobid_future, "flux::jobid", &d->id, NULL) < 0) {
        errstr = "could not delegate job to specified Flux instance";
        flux_log_error (h, "%s: %s", idf58 (d->id), errstr);
        flux_future_destroy (jobid_future);
        return -1;
    }
    delegate_set_remote (d, remote);
    return 0;
}

static int resubmit_job (flux_plugin_t *p, flux_jobid_t *id)
{
    flux_t *h = flux_jobtap_get_flux (p);
    struct delegate_job_info *d;
    if (!(d = flux_jobtap_job_aux_get (p, *id, "flux::delegate")) || !d->job_cluster_config
        || !d->delegate_policy || !d->clean_jobspec)
        return -1;

    if (config_remove_uri (d->job_cluster_config, d->selected_uri) < 0 || submit_job (p, d) < 0) {
        flux_log_error (h, "%s Unable to resubmit job or change uri", idf58 (*id));
        return -1;
    }
    return 0;
}

static int handle_job_exception (flux_plugin_t *p,
                                 flux_future_t *f,
                                 flux_jobid_t *id,
                                 json_t *context)
{
    const char *type;
    int severity;

    if (json_unpack (context, "{s:s s:i}", "type", &type, "severity", &severity) < 0) {
        errno = EINVAL;
        return JOB_EXCEPTION_ERROR;
    }

    if (severity > 0)
        return JOB_EXCEPTION_IGNORED;

    if (!strcmp (type, "alloc")) {
        if (resubmit_job (p, id) < 0) {
            flux_log_error (flux_jobtap_get_flux (p), "Exception Handling: Unable to resubmit job");
            return JOB_EXCEPTION_ERROR;
        }
        return JOB_EXCEPTION_RESUBMITTED;
    }

    return JOB_EXCEPTION_TERMINAL;
}
/*
 * Callback firing when target events are ready.
 */
static void event_callback (flux_future_t *f, void *arg)
{
    flux_plugin_t *p = arg;
    flux_t *h;
    flux_jobid_t *id;
    json_t *o = NULL;
    json_t *context = NULL;
    struct delegate_job_info *d = NULL;
    const char *name = NULL, *event = NULL;
    double timestamp;

    if (!(h = flux_future_aux_get (f, "flux::handle"))) {
        return;
    }
    if (!(id = flux_future_aux_get (f, "flux::jobid"))) {
        flux_log_error (h, "could not fetch flux::jobid from future");
        return;
    }

    // Decode the event log entry
    if (flux_job_event_watch_get (f, &event) != 0 || !(o = eventlog_entry_decode (event))
        || eventlog_entry_parse (o, &timestamp, &name, &context) < 0) {
        flux_log_error (h, "Error decoding/parsing eventlog entry for %s", idf58 (*id));
        json_decref (o);
        return;
    }

    d = flux_jobtap_job_aux_get (p, *id, "flux::delegate");
    if (!strcmp (name, "start")) {
        /*  'start' event with no cray_port_distribution event.
         *  assume cray-pals jobtap plugin is not loaded.
         */
        if (flux_jobtap_event_post_pack (p, *id, "delegate::start", "{s:f}", "timestamp", timestamp)
            < 0) {
            flux_log_error (h, "could not post delegate::start event for %s", idf58 (*id));
        }
    } else if (!strcmp (name, "exception")) {
        if (!d) {
            flux_future_reset (f);
            return;
        }
        switch (handle_job_exception (p, f, id, context)) {
            case JOB_EXCEPTION_IGNORED:
                /* severity > 0: no effect, this future stays authoritative,
                 * just keep watching  */
                break;

            case JOB_EXCEPTION_RESUBMITTED:
                /* handed off to a new target; this future is retired */
                d->authoritative_future = NULL;
                flux_future_destroy (f);
                return;

            case JOB_EXCEPTION_TERMINAL:
                /* fatal exception, no resubmission attempted; job really
                 * ends here, let the upcoming "clean" report the real failure */
                d->last_attempt_failed = true;
                break;

            case JOB_EXCEPTION_ERROR:
            default:
                flux_log_error (h, "Exception handling failed for the job %s", idf58 (*id));
                d->last_attempt_failed = true;
                break;
        }
    } else if (!strcmp (name, "clean")) {
        /* Only the authoritative future's "clean" reflects the job's real
         * outcome. A retired future's "clean" (e.g. a leftover from an
         * earlier target we've since moved on from) is just discarded. */
        if (!d || f != d->authoritative_future) {
            flux_future_destroy (f);
            return;
        }
        bool success = !d->last_attempt_failed;
        restore_default_urgency (p,
                                 id,
                                 success,
                                 success ? "Successfully delegated job" : "unhandled exception");
        flux_future_destroy (f);
        return;
    }
    flux_future_reset (f);
}

/*
 * Callback firing when job has been submitted and ID is ready.
 */
static void submit_callback (flux_future_t *f, void *arg)
{
    flux_t *h, *delegated_h;
    flux_plugin_t *p = arg;
    flux_jobid_t delegated_id, *orig_id, *idptr = NULL;
    flux_future_t *wait_future = NULL, *event_future = NULL;
    const char *errstr = "";
    struct delegate_job_info *d;
    if (!(h = flux_jobtap_get_flux (p))) {
        flux_future_destroy (f);
        return;
    }
    if (!(orig_id = flux_future_aux_get (f, "flux::jobid"))
        || (!(d = flux_jobtap_job_aux_get (p, *orig_id, "flux::delegate")))) {
        flux_log_error (h, "in submit callback: couldn't get jobid");
        flux_future_destroy (f);
        return;
    }
    if (!(delegated_h = flux_future_get_flux (f))
        || flux_job_submit_get_id (f, &delegated_id) < 0) {
        if (!(errstr = flux_future_error_string (f)))
            errstr = "flux_job_submit_get_id";
        goto error;
    }

    /* One scratch pointer is reused for each allocation: the ownership-
     * transferring aux_set is the LAST check in each chain, so on failure idptr
     * is NULL or still owned here (local free is safe), and on success the
     * future/job owns it and idptr is free to be reused. The error label
     * therefore only destroys futures, never idptr. */

    if (!(event_future = flux_job_event_watch (delegated_h, delegated_id, "eventlog", 0))
        || flux_future_aux_set (event_future, "flux::handle", h, NULL) < 0
        || flux_future_then (event_future, -1, event_callback, p) < 0
        || !(idptr = malloc (sizeof (*idptr)))
        || flux_future_aux_set (event_future, "flux::jobid", idptr, free) < 0) {
        free (idptr);
        errstr = "flux_job_event_watch";
        goto error;
    }
    *idptr = *orig_id;

    d->delegated_id = delegated_id;
    /*
     * This event future is now the authoritative one for this job: its
     * "clean" event is what will report the job's outcome to the source
     * cluster. Any previously-current future (e.g. an earlier target that
     * excepted and handed off to this one) is retired and its "clean"
     * will be ignored.
     *
     * Reset last_attempt_failed since it describes the outcome of this
     * new attempt, not any prior one.
     */
    d->authoritative_future = event_future;
    d->last_attempt_failed = false;
    if (flux_jobtap_event_post_pack (p,
                                     *orig_id,
                                     "delegate::submit",
                                     "{s:I}",
                                     "jobid",
                                     delegated_id)
        < 0) {
        errstr = "flux_jobtap_event_post_pack";
        goto error;
    }
    flux_future_destroy (f);
    return;
error:
    flux_log_error (h,
                    "%s: submission to specified Flux instance failed: %s",
                    idf58 (*orig_id),
                    errstr);
    flux_jobtap_raise_exception (p, *orig_id, DELEGATION_FAILURE_EXCEPTION, 0, "%s", errstr);
    flux_future_destroy (wait_future);
    flux_future_destroy (event_future);
    flux_future_destroy (f);
    return;
}
/*
 * Remove all dependencies from jobspec.
 *
 * Dependencies may reference jobids that the instance the job is
 * being sent to does not recognize.
 */
static char *remove_dependency_and_encode (json_t *jobspec)
{
    char *encoded_jobspec;
    json_t *attributes, *system;
    if (!(jobspec = json_deep_copy (jobspec))) {
        return NULL;
    }
    attributes = json_object_get (jobspec, "attributes");
    system = attributes ? json_object_get (attributes, "system") : NULL;

    if (system) {
        json_object_del (system, "dependencies");
        json_object_del (system, "delegate");
    }

    encoded_jobspec = json_dumps (jobspec, 0);
    json_decref (jobspec);
    return encoded_jobspec;
}

static int depend_cb (flux_plugin_t *p, const char *topic, flux_plugin_arg_t *args, void *arg)
{
    flux_t *h = flux_jobtap_get_flux (p);
    flux_jobid_t id;
    const char *delegate;
    json_t *jobspec;
    struct delegate_job_info *d;

    if (!h)
        return flux_jobtap_reject_job (p, args, "error processing delegate: %s", strerror (errno));
    if (flux_plugin_arg_unpack (args,
                                FLUX_PLUGIN_ARG_IN,
                                "{s:I s:o}",
                                "id",
                                &id,
                                "jobspec",
                                &jobspec)
        < 0) {
        return flux_jobtap_reject_job (p,
                                       args,
                                       "error processing delegate: %s",
                                       flux_plugin_arg_strerror (args));
    }

    if (json_unpack (jobspec, "{s:{s:{s:s}}}", "attributes", "system", "delegate", &delegate) < 0)
        return 0;
    if (!(d = delegate_job_info_create (id)))
        return flux_jobtap_reject_job (p, args, "error processing delegate: %s", strerror (errno));

    if (flux_jobtap_job_subscribe (p, id) < 0
        || flux_jobtap_event_post_pack (p,
                                        FLUX_JOBTAP_CURRENT_JOB,
                                        "urgency",
                                        "{s:i s:i}",
                                        "userid",
                                        getuid (),
                                        "urgency",
                                        FLUX_JOB_URGENCY_HOLD)
               < 0
        || flux_jobtap_job_aux_set (p,
                                    FLUX_JOBTAP_CURRENT_JOB,
                                    "flux::delegate",
                                    d,
                                    (flux_free_f)delegate_job_info_destroy)
               < 0) {
        delegate_job_info_destroy (d);
        flux_log_error (h, "failed to initialize delegate job state");
        return -1;
    }
    return 0;
}

/*
 * Continuation callback, invoked when alloc-bypass R has been committed
 * to the KVS.
 *
 * Post the alloc (bypass: true) event for the job.
 */
static void alloc_continuation (flux_future_t *f, void *arg)
{
    flux_plugin_t *p = arg;
    flux_jobid_t *id;

    flux_t *h = flux_jobtap_get_flux (p);

    if (!f || !(id = flux_future_aux_get (f, "flux::jobid"))) {
        flux_log_error (h, "alloc_continuation: failed to get jobid from future");
        goto done;
    }

    if (flux_future_get (f, NULL) < 0) {
        flux_log_error (h, "alloc_continuation: flux_future_get failed for %s", idf58 (*id));

        flux_jobtap_raise_exception (p,
                                     *id,
                                     "alloc",
                                     0,
                                     "failed to commit R to kvs: %s",
                                     strerror (errno));
        goto done;
    }

    if (flux_jobtap_event_post_pack (p, *id, "alloc", "{s:b}", "bypass", true) < 0) {
        flux_log_error (h,
                        "alloc_continuation: flux_jobtap_event_post_pack for "
                        "%s",
                        idf58 (*id));
        flux_jobtap_raise_exception (p,
                                     *id,
                                     "alloc",
                                     0,
                                     "failed to post alloc event: %s",
                                     strerror (errno));
        goto done;
    }

done:
    flux_future_destroy (f);
}
/*
 * Delegation hold via priority:
 *
 * When we delegate a job, we "hold" it by setting its priority to 0.
 * Once the job finishes on the target cluster, we restore the urgency
 * to the default value of 16.
 *
 * This restore triggers a second pass through the priority and sched
 * callbacks, and that second pass is where we set the alloc-bypass flag in the priority_cb.
 *
 * Why the second pass? The job hold takes effect during the sched phase.
 * If we set alloc-bypass during the first pass, there is no schedule to
 * hold the job against, so the priority hold has no effect. Setting
 * alloc-bypass on the second pass avoids this problem.
 */
static int priority_cb (flux_plugin_t *p, const char *topic, flux_plugin_arg_t *args, void *arg)
{
    flux_t *h = flux_jobtap_get_flux (p);
    struct delegate_job_info *d;
    json_t *jobspec = NULL;
    struct cluster_config *config;
    char *encoded_jobspec = NULL;
    const char *strategy = NULL;
    const char *errstr = NULL;

    if (!(d = flux_jobtap_job_aux_get (p, FLUX_JOBTAP_CURRENT_JOB, "flux::delegate")))
        return 0;
    if (d->phase == DELEGATE_RESUMED) {
        if (flux_jobtap_job_set_flag (p, FLUX_JOBTAP_CURRENT_JOB, "alloc-bypass") < 0) {
            errstr = "failed to set alloc-bypass";
            flux_log_error (h, "%s: %s", idf58 (d->id), errstr);
            goto error;
        }
        return 0;
    }
    if (flux_plugin_arg_unpack (args, FLUX_PLUGIN_ARG_IN, "{s:o}", "jobspec", &jobspec) < 0
        || json_unpack (jobspec, "{s:{s:{s:s}}}", "attributes", "system", "delegate", &strategy)
               < 0) {
        errstr = "could not unpack jobspec";
        flux_log_error (h, "%s: %s", idf58 (d->id), errstr);
        goto error;
    }

    if (!(config = flux_plugin_aux_get (p, "flux::delegate::selection_config"))
        || !(encoded_jobspec = remove_dependency_and_encode (jobspec))) {
        flux_log_error (h, "Unable to encode jobspec");
        goto error;
    }
    d->delegate_policy = strdup (strategy);
    d->job_cluster_config = copy_config (config);
    d->clean_jobspec = encoded_jobspec;
    encoded_jobspec = NULL;
    if (submit_job (p, d) < 0) {
        flux_log_error (h, "priority_cb: job submission failure");
        goto error;
    }

    return 0;

error:
    flux_jobtap_raise_exception (p,
                                 FLUX_JOBTAP_CURRENT_JOB,
                                 DELEGATION_FAILURE_EXCEPTION,
                                 0,
                                 "%s: %s",
                                 idf58 (d->id),
                                 errstr);
    free (encoded_jobspec);
    return 0;
}

/*
 * job.state.sched callback. Job enters this state two times,first when we hold the job and do
 * nothing and second time we generates an alloc-bypass R for the job and passes it to the job
 * manager. Then starts a KVS transaction to post the R to the KVS. Once that is complete, the
 * `alloc` event should be posted, but that is handled asynchronously.
 *
 */
static int sched_cb (flux_plugin_t *p, const char *topic, flux_plugin_arg_t *args, void *arg)
{
    flux_t *h = flux_jobtap_get_flux (p);
    struct delegate_job_info *d;
    flux_kvs_txn_t *txn = NULL;
    json_t *R = NULL;
    char key[256];
    char hostname[HOST_NAME_MAX + 1];
    flux_future_t *alloc_future = NULL;

    if (!h)
        return -1;

    if (!(d = flux_jobtap_job_aux_get (p, FLUX_JOBTAP_CURRENT_JOB, "flux::delegate")))
        return 0;

    /*  First pass: establish the hold and wait for the remote job to finish. */
    if (d->phase == DELEGATE_HELD) {
        d->phase = DELEGATE_RESUMED;
        return 0;
    }

    if (gethostname (hostname, sizeof (hostname)) < 0) {
        flux_jobtap_raise_exception (p,
                                     FLUX_JOBTAP_CURRENT_JOB,
                                     "alloc",
                                     0,
                                     "delegate: gethostname: %s",
                                     flux_plugin_arg_strerror (args));
        flux_log_error (h, "gethostname for %s", idf58 (d->id));
        return -1;
    }

    /* Create a fake R without properties */
    if (!(R = json_pack ("{s:i s:{s:[{s:s s:{s:s}}] s:f s:f s:[s]}}",
                         "version",
                         1,
                         "execution",
                         "R_lite",
                         "rank",
                         "0",
                         "children",
                         "core",
                         "0",
                         "starttime",
                         0.0,
                         "expiration",
                         0.0,
                         "nodelist",
                         hostname))
        || flux_plugin_arg_pack (args, FLUX_PLUGIN_ARG_OUT, "{s:O}", "R", R) < 0) {
        json_decref (R);
        flux_log_error (h, "failed to output fake R for %s", idf58 (d->id));
        return flux_jobtap_raise_exception (p,
                                            d->id,
                                            "alloc",
                                            0,
                                            "failed to post alloc event: %s",
                                            strerror (errno));
    }

    /* Create KVS transaction posting the R */
    if (!(txn = flux_kvs_txn_create ()) || flux_job_kvs_key (key, sizeof (key), d->id, "R") < 0
        || flux_kvs_txn_pack (txn, 0, key, "O", R) < 0
        || !(alloc_future = flux_kvs_commit (h, NULL, 0, txn))
        || flux_future_then (alloc_future, -1, alloc_continuation, p) < 0) {
        flux_log_error (h, "failed processing R KVS transaction");
        flux_kvs_txn_destroy (txn);
        flux_future_destroy (alloc_future);
        json_decref (R);
        return flux_jobtap_raise_exception (p,
                                            d->id,
                                            "alloc",
                                            0,
                                            "failed to post alloc event: %s",
                                            strerror (errno));
    }
    json_decref (R);
    flux_kvs_txn_destroy (txn);

    if (flux_future_aux_set (alloc_future, "flux::jobid", &d->id, NULL) < 0) {
        flux_future_destroy (alloc_future);
        return flux_jobtap_raise_exception (p, d->id, "alloc", 0, "flux_future_aux_set");
    }
    return 0;
}

/*
 * job.state.run callback. Sends `job-exec.override` RPCs to make the job skip
 * execution, since execution is handled by another Flux instance.
 */
static int run_cb (flux_plugin_t *p, const char *topic, flux_plugin_arg_t *args, void *arg)
{
    flux_t *h = flux_jobtap_get_flux (p);
    flux_jobid_t job_id;
    flux_future_t *run_future;

    if (!h)
        return -1;

    if (!flux_jobtap_job_aux_get (p, FLUX_JOBTAP_CURRENT_JOB, "flux::delegate"))
        return 0;

    if (flux_plugin_arg_unpack (args, FLUX_PLUGIN_ARG_IN, "{s:I}", "id", &job_id) < 0) {
        flux_jobtap_raise_exception (p,
                                     FLUX_JOBTAP_CURRENT_JOB,
                                     "alloc",
                                     0,
                                     "delegate: unpack: %s",
                                     flux_plugin_arg_strerror (args));
        flux_log_error (h, "flux_plugin_arg_unpack");
        return -1;
    }
    // send `job-exec.override` start and finish events. TODO: check the RPC
    // return status and handle errors.
    if (!(run_future = flux_rpc_pack (h,
                                      "job-exec.override",
                                      FLUX_NODEID_ANY,
                                      0,
                                      "{s:s s:I}",
                                      "event",
                                      "start",
                                      "jobid",
                                      job_id))) {
        flux_log_error (h, "flux_rpc_pack failed for %s job-exec.override: start", idf58 (job_id));
        return -1;
    }
    flux_future_destroy (run_future);
    if (!(run_future = flux_rpc_pack (h,
                                      "job-exec.override",
                                      FLUX_NODEID_ANY,
                                      0,
                                      "{s:s s:I}",
                                      "event",
                                      "finish",
                                      "jobid",
                                      job_id))) {
        flux_log_error (h,
                        "flux_rpc_pack failed for %s in job-exec.override: "
                        "finish",
                        idf58 (job_id));
        return -1;
    }
    flux_future_destroy (run_future);

    return 0;
}

static int exception_cb (flux_plugin_t *p, const char *topic, flux_plugin_arg_t *args, void *arg)
{
    flux_t *h = flux_jobtap_get_flux (p);
    flux_jobid_t job_id;
    int severity = 1;
    json_t *context = NULL;
    const char *name = NULL, *type = NULL;
    flux_future_t *cancel_future = NULL;
    struct delegate_job_info *d;
    if (!h)
        return -1;
    if (!(d = flux_jobtap_job_aux_get (p, FLUX_JOBTAP_CURRENT_JOB, "flux::delegate"))
        || d->delegated_id == UINT64_MAX)
        return 0;
    if (flux_plugin_arg_unpack (args,
                                FLUX_PLUGIN_ARG_IN,
                                "{s:I s:{s:s s:o}}",
                                "id",
                                &job_id,
                                "entry",
                                "name",
                                &name,
                                "context",
                                &context)
        < 0) {
        flux_log_error (h, "flux_plugin_arg_unpack");
        return 0;
    }
    if (!name || strcmp (name, "exception") != 0)
        return 0;

    if (json_unpack (context, "{s:s s:i}", "type", &type, "severity", &severity) < 0) {
        flux_log_error (h, "unpacking exception context");
        return 0;
    }
    if (severity != 0 || strcmp (type, DELEGATION_FAILURE_EXCEPTION) == 0)
        return 0;
    if (!(d->remote)) {
        flux_log_error (h, "job is delegated but its handle not found");
        return -1;
    }

    if (!(cancel_future =
              flux_job_cancel (d->remote, d->delegated_id, "Cancelled by parent cluster"))
        || flux_future_then (cancel_future, -1, cancel_callback, p) < 0) {
        flux_log_error (h, "error cancel");
        flux_future_destroy (cancel_future);
        return 0;
    }
    return 0;
}

static const struct flux_plugin_handler tab[] = {
    {"job.state.depend", depend_cb, NULL},
    {"job.state.priority", priority_cb, NULL},
    {"job.state.sched", sched_cb, NULL},
    {"job.state.run", run_cb, NULL},
    {"job.event.exception", exception_cb, NULL},
    {0},
};

int flux_plugin_init (flux_plugin_t *p)
{
    struct cluster_config *config;
    flux_t *h = flux_jobtap_get_flux (p);

    if (!h || flux_plugin_register (p, "delegate", tab) < 0 || !(config = selection_init (h))
        || flux_plugin_aux_set (p,
                                "flux::delegate::selection_config",
                                config,
                                (flux_free_f)selection_destroy)
               < 0) {
        return -1;
    }
    return 0;
}
