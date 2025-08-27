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

#include <flux/core.h>
#include <flux/jobtap.h>
#include <inttypes.h>
#include <jansson.h>
#include <stdint.h>
#include <time.h>
#include <string.h>

/* Configuration structure */
typedef struct {
    char **uris;        /* Array of cluster URIs */
    int count;          /* Number of clusters */
    int initialized;    /* Random seed initialized flag */
} cluster_config_t;

static cluster_config_t config = {0};

/* Load cluster URIs from config file */
static int load_config(flux_plugin_t *p, const char *path)
{
    flux_t *h = flux_jobtap_get_flux(p);
    json_t *root;
    json_error_t error;
    
    /* Load JSON config file */
    root = json_load_file(path, 0, &error);
    if (!root) {
        flux_log(h, LOG_ERR, "Failed to load config %s: %s", 
                 path, error.text);
        return -1;
    }
    
    /* Get clusters array */
    json_t *clusters = json_object_get(root, "clusters");
    if (!clusters || !json_is_array(clusters)) {
        flux_log(h, LOG_ERR, "Config missing 'clusters' array");
        json_decref(root);
        return -1;
    }
    
    /* Count and allocate */
    config.count = json_array_size(clusters);
    if (config.count == 0) {
        flux_log(h, LOG_ERR, "No clusters defined in config");
        json_decref(root);
        return -1;
    }
    
    config.uris = calloc(config.count, sizeof(char *));
    if (!config.uris) {
        json_decref(root);
        return -1;
    }
    
    /* Load each URI */
    for (int i = 0; i < config.count; i++) {
        json_t *cluster = json_array_get(clusters, i);
        const char *uri = NULL;
        
        if (json_is_string(cluster)) {
            /* Simple format: just URI strings */
            uri = json_string_value(cluster);
        } else if (json_is_object(cluster)) {
            /* Object format: {"uri": "...", "name": "..."} etc. */
            uri = json_string_value(json_object_get(cluster, "uri"));
        }
        
        if (!uri) {
            flux_log(h, LOG_ERR, "Invalid cluster entry at index %d", i);
            json_decref(root);
            return -1;
        }
        
        config.uris[i] = strdup(uri);
        flux_log(h, LOG_INFO, "Loaded cluster %d: %s", i, uri);
    }
    
    json_decref(root);
    
    /* Initialize random number generator */
    if (!config.initialized) {
        srand(time(NULL));
        config.initialized = 1;
    }
    
    return 0;
}

/* Select a random cluster URI */
static const char *select_random_cluster(flux_plugin_t *p)
{
    flux_t *h = flux_jobtap_get_flux(p);
    
    if (config.count == 0) {
        flux_log(h, LOG_ERR, "No clusters available");
        return NULL;
    }
    
    int index = rand() % config.count;
    flux_log(h, LOG_DEBUG, "Selected cluster %d: %s", 
             index, config.uris[index]);
    
    return config.uris[index];
}


// static const char *select_shortest_match_cluster(flux_plugin_t *p)
int select_shortest_match_cluster(flux_plugin_t *p)
{
    int rc = -1;
    flux_t *h = flux_jobtap_get_flux(p);
    int64_t V, E, J;
    double load, min, max, avg;
    flux_future_t *f = NULL;


    if (!h) {
        errno = EINVAL;
        goto out;
    }

    if (!(f = flux_rpc (h, "sched-fluxion-resource.stats-get", NULL, FLUX_NODEID_ANY, 0))) {
        flux_log(h,LOG_INFO, "RPC itself failed");
        goto out;
    }

    // if (f == NULL){
    //      flux_log(h,LOG_INFO, "I have a NULL ptr.");
    // }
    // else {
    //      flux_log(h,LOG_INFO, "I DO NOT have a NULL ptr.");
    // }

    // void* json_str = malloc(sizeof(json_t));
    // //const void *json_str;
    // flux_future_get(f, (const void**) &json_str);


    // flux_log(h, LOG_INFO, "RECEIVED RPC OBJECT %s", json_dumps((json_t*)json_str, JSON_INDENT(4)));
    // //flux_log(h, LOG_INFO, "RECEIVED RPC OBJECT %s", json_str);
    
    if ((rc = flux_rpc_get_unpack (f,
                                   "{s:I s:I s:f s:I s:f s:f s:f}",
                                   "V",
                                   &V,
                                   "E",
                                   &E,
                                   "load-time",
                                   &load,
                                   "njobs",
                                   &J,
                                   "min-match",
                                   &min,
                                   "max-match",
                                   &max,
                                   "avg-match",
                                   &avg))
        < 0) {
            
        flux_log(h,LOG_INFO, "Unpack Failed after RPC!");
        goto out;
    }

    flux_log(h,LOG_INFO, "Average Match Time is: %lf",avg);

out:
    flux_log(h,LOG_INFO, "\n\nEND. Testing Flux RPC Failed!!!\n\n");
    flux_future_destroy (f);
    return rc;
}


bool eventlog_entry_validate (json_t *entry)
{
    json_t *name;
    json_t *timestamp;
    json_t *context;

    if (!json_is_object (entry) || !(name = json_object_get (entry, "name"))
        || !json_is_string (name) || !(timestamp = json_object_get (entry, "timestamp"))
        || !json_is_number (timestamp))
        return false;

    if ((context = json_object_get (entry, "context"))) {
        if (!json_is_object (context))
            return false;
    }

    return true;
}

static json_t *eventlog_entry_decode (const char *entry)
{
    int len;
    char *ptr;
    json_t *o;

    if (!entry)
        goto einval;

    if (!(len = strlen (entry)))
        goto einval;

    if (entry[len - 1] != '\n')
        goto einval;

    if (entry[len - 1] != '\n')
        goto einval;

    ptr = strchr (entry, '\n');
    if (ptr != &entry[len - 1])
        goto einval;

    if (!(o = json_loads (entry, JSON_ALLOW_NUL, NULL)))
        goto einval;

    if (!eventlog_entry_validate (o)) {
        json_decref (o);
        goto einval;
    }

    return o;

einval:
    errno = EINVAL;
    return NULL;
}

static int eventlog_entry_parse (json_t *entry,
                                 double *timestamp,
                                 const char **name,
                                 json_t **context)
{
    double t;
    const char *n;
    json_t *c;

    if (!entry) {
        errno = EINVAL;
        return -1;
    }

    if (json_unpack (entry, "{ s:F s:s }", "timestamp", &t, "name", &n) < 0) {
        errno = EINVAL;
        return -1;
    }

    if (!json_unpack (entry, "{ s:o }", "context", &c)) {
        if (!json_is_object (c)) {
            errno = EINVAL;
            return -1;
        }
    } else
        c = NULL;

    if (timestamp)
        (*timestamp) = t;
    if (name)
        (*name) = n;
    if (context)
        (*context) = c;

    return 0;
}

/*
 * Callback firing when job has completed.
 */
static void wait_callback (flux_future_t *f, void *arg)
{
    flux_plugin_t *p = arg;
    json_int_t *id;
    bool success;
    const char *errstr;

    if (!(id = flux_future_aux_get (f, "flux::jobid"))) {
        return;
    }
    if (flux_job_wait_get_status (f, &success, &errstr) < 0) {
        flux_jobtap_raise_exception (p,
                                     *id,
                                     "DelegationFailure",
                                     0,
                                     "Could not fetch result of job");
        return;
    }
    if (success) {
        flux_jobtap_raise_exception (p, *id, "DelegationSuccess", 0, "");
    } else {
        flux_jobtap_raise_exception (p,
                                     *id,
                                     "DelegationFailure",
                                     0,
                                     "errstr %s",
                                     errstr);
    }
    flux_future_destroy (f);
}

/*
 * Callback firing when events are ready.
 */
static void event_callback (flux_future_t *f, void *arg)
{
    flux_plugin_t *p = arg;
    flux_t *h;
    json_int_t *json_id;
    flux_jobid_t id;
    json_t *o = NULL;
    json_t *context = NULL;
    const char *name = NULL, *event = NULL;
    double timestamp;

    if (!(h = flux_future_aux_get (f, "flux::handle"))) {
        return;
    }
    if (!(json_id = flux_future_aux_get (f, "flux::jobid"))) {
        flux_log_error (h, "could not fetch flux::jobid from future");
        return;
    }
    id = (flux_jobid_t)*json_id;
    if (flux_job_event_watch_get (f, &event) != 0
        || !(o = eventlog_entry_decode (event))
        || eventlog_entry_parse (o, &timestamp, &name, &context) < 0) {
        json_decref (o);
        flux_log_error (h, "Error decoding/parsing eventlog entry for %" PRIu64, id);
        return;
    }
    if (!strcmp (name, "start")) {
        /*  'start' event with no cray_port_distribution event.
         *  assume cray-pals jobtap plugin is not loaded.
         */
        if (flux_jobtap_event_post_pack (p,
                                         id,
                                         "delegate::start",
                                         "{s:f}",
                                         "timestamp",
                                         timestamp)
            < 0) {
            flux_log_error (h, "could not post delegate::start event for %" PRIu64, id);
        }
    }

    if (!strcmp (name, "clean")) {
        // clean event, no more events needed
        flux_future_destroy (f);
    } else {
        flux_future_reset (f);
    }
    return;
}

/*
 * Callback firing when job has been submitted and ID is ready.
 */
static void submit_callback (flux_future_t *f, void *arg)
{
    flux_t *h, *delegated_h;
    flux_plugin_t *p = arg;
    json_int_t *orig_id;
    flux_jobid_t delegated_id;
    flux_future_t *wait_future = NULL, *event_future = NULL;
    const char *errstr;

    if (!(h = flux_jobtap_get_flux (p))) {
        flux_future_destroy (f);
        return;
    } else if (!(orig_id = flux_future_aux_get (f, "flux::jobid"))) {
        flux_log_error (h, "in submit callback: couldn't get jobid");
        flux_future_destroy (f);
        return;
    }
    if (!(delegated_h = flux_future_get_flux (f))
        || flux_job_submit_get_id (f, &delegated_id) < 0
        || !(wait_future = flux_job_wait (delegated_h, delegated_id))
        || flux_future_aux_set (wait_future, "flux::jobid", orig_id, NULL) < 0
        || flux_future_then (wait_future, -1, wait_callback, p) < 0
        || !(event_future =
                 flux_job_event_watch (delegated_h, delegated_id, "eventlog", 0))
        || flux_future_aux_set (event_future, "flux::jobid", orig_id, NULL) < 0
        || flux_future_aux_set (event_future, "flux::handle", h, NULL) < 0
        || flux_future_then (event_future, -1, event_callback, p) < 0
        || flux_jobtap_event_post_pack (p,
                                        *orig_id,
                                        "delegate::submit",
                                        "{s:I}",
                                        "jobid",
                                        (json_int_t)delegated_id)
               < 0) {
        if (!(errstr = flux_future_error_string (f))) {
            errstr = "";
        }
        flux_log_error (h,
                        "%" JSON_INTEGER_FORMAT
                        ": submission to specified Flux instance failed",
                        *orig_id);
        flux_jobtap_raise_exception (p, *orig_id, "DelegationFailure", 0, errstr);
        flux_future_destroy (wait_future);
        flux_future_destroy (event_future);
        flux_future_destroy (f);
        return;
    }
    flux_future_destroy (f);
}

/*
 * Remove all dependencies from jobspec.
 *
 * Dependencies may reference jobids that the instance the job is
 * being sent to does not recognize.
 *
 * Also, if the 'delegate' dependency in particular were not removed,
 * one of two things would happen. If the instance the job is sent to
 * does not have this jobtap plugin loaded, then the job would be
 * rejected. Otherwise, if the instance DOES have this jobtap plugin
 * loaded, it would attempt to delegate to itself in an infinite
 * loop.
 */
static char *encode_jobspec (json_t *jobspec)
{
    char *encoded_jobspec;

    if (!(jobspec = json_deep_copy (jobspec))) {
        return NULL;
    }
    encoded_jobspec = json_dumps (jobspec, 0);
    json_decref (jobspec);
    return encoded_jobspec;
}

/*
 * Handle job.dependency.delegate requests
 */
static int new_cb (flux_plugin_t *p,
                      const char *topic,
                      flux_plugin_arg_t *args,
                      void *arg)
{
    flux_t *h = flux_jobtap_get_flux (p);
    json_int_t *id;
    flux_t *delegated;
    const char *selected_uri;
    json_t *jobspec;
    char *encoded_jobspec = NULL;
    flux_future_t *jobid_future = NULL;

    flux_log (h, LOG_INFO, "Entered new_cb\n");

    char *env_var_val = NULL;
    
    if (!h || !(id = malloc (sizeof (json_int_t)))) {
        return flux_jobtap_reject_job (p,
                                       args,
                                       "error processing select_and_delegate: %s",
                                       flux_plugin_arg_strerror (args));
    }

    if (flux_plugin_arg_unpack (args,
                                FLUX_PLUGIN_ARG_IN,
                                "{s:I s:o s?{s?{s?{s?s}}}}",
                                "id",
                                id,
                                "jobspec",
                                &jobspec, 
                                "jobspec",
                                    "attributes",
                                        "system",
                                            "FLUX_DELEGATE_SELECTION_POLICY",
                                                &env_var_val)
            < 0
        || flux_jobtap_job_aux_set (p, *id, "flux::jobid", id, free) < 0) {
            free (id);
            return flux_jobtap_reject_job (p,
                                            args,
                                            "error processing delegate: %s",
                                            flux_plugin_arg_strerror (args));
        }

    // flux_log (h, LOG_INFO, "selected id is %d" JSON_INTEGER_FORMAT, id);
    flux_log(h, LOG_INFO, "JOBSPEC is %s", json_dumps((json_t*) jobspec, JSON_INDENT(4)));

    if(env_var_val) {
        flux_log(h, LOG_INFO, "%s is set to %s", "FLUX_DELEGATE_SELECTION_POLICY", env_var_val);
    }
    else {
        env_var_val = "random"; 
        flux_log(h, LOG_INFO, "No attribute is set by the user. Using random selection as default.\n");
        flux_log(h, LOG_INFO, "%s is set to %s", "FLUX_DELEGATE_SELECTION_POLICY", env_var_val);
    }
    
    if (strcmp(env_var_val, "least_pending") == 0) {
        selected_uri = select_random_cluster(p);  
        // TODO Implement the logic for this use case
        // selected_uri = select_least_pending_cluster(p);
    }
    else if (strcmp(env_var_val, "shortest_match") == 0) {
        select_shortest_match_cluster(p);  
        selected_uri = select_random_cluster(p);  
        // TODO Implement the logic for this use case
        // selected_uri = select_shortest_match_cluster(p);
    }
    else {
         selected_uri = select_random_cluster(p);     
    }

    if (!selected_uri) {
        flux_log(h, LOG_ERR, "No URI was selected.");
        return -1;
    }

    if (!(delegated = flux_open (selected_uri, 0))) {
        flux_log_error (h, "%" JSON_INTEGER_FORMAT ": could not open URI %s", *id, selected_uri);
        return -1;
    }

    if (flux_jobtap_dependency_add (p, *id, "delegated") < 0
        || flux_jobtap_job_aux_set (p,
                                    *id,
                                    "flux::delegated_handle",
                                    delegated,
                                    (flux_free_f)flux_close)
               < 0
        || flux_set_reactor (delegated, flux_get_reactor (h)) < 0) {
        flux_log_error (h, "%" JSON_INTEGER_FORMAT ": flux_jobtap_dependency_add", *id);
        flux_close (delegated);
        return -1;
    }
    // submit the job to the specified instance and attach a callback for fetching the
    // ID

    if (!(encoded_jobspec = encode_jobspec (jobspec))
        || !(jobid_future =
                 flux_job_submit (delegated, encoded_jobspec, 16, FLUX_JOB_WAITABLE))
        || flux_future_then (jobid_future, -1, submit_callback, p) < 0
        || flux_future_aux_set (jobid_future, "flux::jobid", id, NULL) < 0) {
        flux_log_error (h,
                        "%" JSON_INTEGER_FORMAT
                        ": could not delegate job to specified Flux "
                        "instance",
                        *id);
        flux_future_destroy (jobid_future);
        free (encoded_jobspec);
        return -1;
    }
    free (encoded_jobspec);
    return 0;
}

static const struct flux_plugin_handler tab[] = {
    {"job.new", new_cb, NULL},
    {0},
};

int flux_plugin_init (flux_plugin_t *p)
{
    flux_t *h = flux_jobtap_get_flux(p);
    flux_log(h, LOG_ERR, "ENTERED INIT. NEW START.");

    if (flux_plugin_register (p, "select_and_delegate", tab) < 0) {
        flux_log(h, LOG_ERR, "Failed to register select_and_delegate plugin");
        return -1;
    }

    const char *config_path;

    if (flux_plugin_conf_unpack (p, "{s:s}", 
                                    "config", &config_path) < 0){
        flux_log(h, LOG_ERR, "No config file specified. "
                 "Use: flux jobtap load plugin.so config=/path/to/config.json");
        return -1;
    }
    
    /* Load configuration */
    if (load_config(p, config_path) < 0) {
        flux_log(h, LOG_ERR, "Failed to load configuration");
        return -1;
    }
    
    flux_log(h, LOG_INFO, "Random cluster selector loaded with %d clusters", 
             config.count);
    
    return 0;
}
