#if HAVE_CONFIG_H
#include "config.h"
#endif

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include <flux/core.h>

#include "src/common/select/select.h"
#include "delegate_job.h"

struct delegate_job_info *delegate_job_info_create (flux_jobid_t id)
{
    struct delegate_job_info *d;

    if (!(d = calloc (1, sizeof (*d))))
        return NULL;
    d->id = id;
    d->delegated_id = UINT64_MAX;
    d->phase = DELEGATE_HELD;
    d->authoritative_future = NULL;
    d->last_attempt_failed = false;
    return d;
}

void delegate_job_info_destroy (struct delegate_job_info *d)
{
    if (d) {
        int saved_errno = errno;
        flux_close (d->remote);
        free (d->clean_jobspec);
        free (d->selected_uri);
        if (d->job_cluster_config)
            selection_destroy (d->job_cluster_config);
        free (d->delegate_policy);
        free (d);
        errno = saved_errno;
    }
}

int delegate_set_uri (struct delegate_job_info *d, const char *uri)
{
    char *new_uri = strdup (uri);
    if (!new_uri)
        return -1;
    free (d->selected_uri);
    d->selected_uri = new_uri;
    return 0;
}

void delegate_set_remote (struct delegate_job_info *d, flux_t *remote)
{
    flux_close (d->remote);
    d->remote = remote;
}
