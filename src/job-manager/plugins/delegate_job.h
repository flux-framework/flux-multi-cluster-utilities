#ifndef _DELEGATE_JOB_H
#define _DELEGATE_JOB_H

#include <flux/core.h>
#include "src/common/select/select.h"

enum delegate_phase {
    DELEGATE_HELD,
    DELEGATE_RESUMED,
};

struct delegate_job_info {
    flux_jobid_t id;

    flux_jobid_t delegated_id;

    flux_t *remote;  // Open handle to the remote instance the job is
                     // currently delegated to. Used to cancel the
                     // delegated job if the source job gets an exception.

    char *clean_jobspec;  // Jobspec with dependencies/delegate attributes
                          // stripped, ready to resubmit as-is to whichever
                          // target is selected next.

    char *selected_uri;

    char *delegate_policy;

    bool last_attempt_failed;  // True if the current/most recent delegated attempt
                               // ended in an exception with no further target to
                               // fall back to. Read only when authoritative_future's
                               // "clean" fires, to decide the outcome reported to the
                               // source job.

    flux_future_t *authoritative_future;  // The one event-watch future currently entitled to
                                          // report this job's outcome to the source instance.
                                          // Reassigned on every successful resubmission; set to
                                          // NULL the moment a future hands off responsibility to
                                          // a not-yet-created successor. Any other future's
                                          // "clean" is a leftover from an abandoned target and is
                                          // ignored.

    struct cluster_config *job_cluster_config;

    enum delegate_phase phase;  // Tracks where this job is in the two-pass hold/resume
                                // sequence used to delay alloc-bypass until scheduling
                                // has a hold to act against (see priority_cb/sched_cb).
};

/* Allocate delegate state for job `id`. Returns NULL on failure (ENOMEM). */
struct delegate_job_info *delegate_job_info_create (flux_jobid_t id);

/*
 * Destroy delegate state: closes any open remote handle and frees all
 * owned strings/config. Safe to call with d == NULL. Preserves errno,
 * since this is commonly used as an aux destructor.
 */
void delegate_job_info_destroy (struct delegate_job_info *d);

/*
 * Replace d->selected_uri with a copy of `uri`, freeing any previous
 * value. Returns 0 on success, -1 on failure (errno set by strdup).
 * On failure, d->selected_uri is left unchanged.
 */
int delegate_set_uri (struct delegate_job_info *d, const char *uri);

/*
 * Replace d->remote, closing any previously-open handle. Takes
 * ownership of `remote` (do not flux_close it after calling this).
 */
void delegate_set_remote (struct delegate_job_info *d, flux_t *remote);

#endif /* !_DELEGATE_JOB_H */
