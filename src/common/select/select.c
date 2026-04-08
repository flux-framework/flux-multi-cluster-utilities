/************************************************************\
 * Copyright 2026 Lawrence Livermore National Security, LLC
 * (c.f. AUTHORS, NOTICE.LLNS, COPYING)
 *
 * This file is part of the Flux resource manager framework.
 * For details, see https://github.com/flux-framework.
 *
 * SPDX-License-Identifier: LGPL-3.0
\************************************************************/

#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <jansson.h>

#include "select.h"

struct cluster_config {
    flux_t *h;
    char **uris;
    size_t count;
    bool random_seeded;
};

enum selection_metric_kind {
    SELECTION_METRIC_MATCH_TIME,
    SELECTION_METRIC_PENDING_JOBS,
};

struct selection_metric {
    enum selection_metric_kind kind;
    union {
        double match_time;
        int64_t pending_jobs;
    } value;
};

static bool selection_has_clusters (struct cluster_config *config,
                                    const char *strategy_name)
{
    if (!config || config->count == 0) {
        errno = ENOENT;
        if (config) {
            flux_log (config->h,
                      LOG_ERR,
                      "No clusters available for %s",
                      strategy_name);
        }
        return false;
    }
    return true;
}

static void seed_random_selection (struct cluster_config *config)
{
    if (!config->random_seeded) {
        srand ((unsigned int)(time (NULL) ^ getpid ()));
        config->random_seeded = true;
    }
}

static size_t select_random_index (struct cluster_config *config)
{
    seed_random_selection (config);
    return (size_t)(rand () % config->count);
}

static const char *select_random_cluster (struct cluster_config *config)
{
    size_t index;

    if (!selection_has_clusters (config, "random selection"))
        return NULL;

    index = select_random_index (config);
    flux_log (config->h, LOG_DEBUG, "Selected cluster %zu: %s", index, config->uris[index]);
    return config->uris[index];
}

static int query_max_match_time (flux_t *h, const char *uri, double *value)
{
    flux_t *remote = NULL;
    flux_future_t *future = NULL;
    int64_t V, E, J;
    double load, max, avg;
    int rc = -1;

    if (!h || !uri || !value) {
        errno = EINVAL;
        return -1;
    }
    if (!(remote = flux_open (uri, 0))) {
        flux_log (h, LOG_ERR, "Failed to open flux instance %s", uri);
        goto out;
    }
    if (!(future = flux_rpc (remote, "sched-fluxion-resource.stats-get", NULL, FLUX_NODEID_ANY, 0))) {
        flux_log (h, LOG_ERR, "Failed to query match statistics for %s", uri);
        goto out;
    }
    if (flux_rpc_get_unpack (future,
                             "{s:I s:I s:f s?{s?{s?I s?{s?f s?f}}}}",
                             "V",
                             &V,
                             "E",
                             &E,
                             "load-time",
                             &load,
                             "match",
                             "succeeded",
                             "njobs",
                             &J,
                             "stats",
                             "max",
                             &max,
                             "avg",
                             &avg)
            < 0) {
        flux_log (h, LOG_ERR, "Failed to unpack match statistics for %s", uri);
        goto out;
    }
    *value = max;
    rc = 0;
out:
    flux_future_destroy (future);
    if (remote)
        flux_close (remote);
    return rc;
}

static int query_pending_jobs (flux_t *h, const char *uri, int64_t *value)
{
    flux_t *remote = NULL;
    flux_future_t *future = NULL;
    json_t *running = NULL;
    int rc = -1;

    if (!h || !uri || !value) {
        errno = EINVAL;
        return -1;
    }
    if (!(remote = flux_open (uri, 0))) {
        flux_log (h, LOG_ERR, "Failed to open flux instance %s", uri);
        goto out;
    }
    if (!(future = flux_rpc (remote, "sched-fluxion-qmanager.stats-get", NULL, FLUX_NODEID_ANY, 0))) {
        flux_log (h, LOG_ERR, "Failed to query queue statistics for %s", uri);
        goto out;
    }
    if (flux_rpc_get_unpack (future,
                             "{s?{s?{s?{s?I} s?{s?o}}}}",
                             "queues",
                             "default",
                             "action_counts",
                             "pending",
                             value,
                             "scheduled_queues",
                             "running",
                             &running)
            < 0) {
        flux_log (h, LOG_ERR, "Failed to unpack queue statistics for %s", uri);
        goto out;
    }
    rc = 0;
out:
    flux_future_destroy (future);
    if (remote)
        flux_close (remote);
    return rc;
}

static int query_cluster_metric (flux_t *h,
                                 const char *uri,
                                 enum selection_metric_kind kind,
                                 struct selection_metric *metric)
{
    if (!metric) {
        errno = EINVAL;
        return -1;
    }

    metric->kind = kind;
    switch (kind) {
    case SELECTION_METRIC_MATCH_TIME:
        return query_max_match_time (h, uri, &metric->value.match_time);
    case SELECTION_METRIC_PENDING_JOBS:
        return query_pending_jobs (h, uri, &metric->value.pending_jobs);
    default:
        errno = EINVAL;
        return -1;
    }
}

static bool selection_metric_is_better (const struct selection_metric *candidate,
                                        const struct selection_metric *best)
{
    if (candidate->kind != best->kind)
        return false;
    if (candidate->kind == SELECTION_METRIC_MATCH_TIME)
        return candidate->value.match_time < best->value.match_time;
    return candidate->value.pending_jobs < best->value.pending_jobs;
}

static const char *select_cluster_by_metric (struct cluster_config *config,
                                             const char *strategy_name,
                                             const char *failure_message,
                                             struct selection_metric *best_metric)
{
    size_t index;
    const char *best_uri = NULL;

    if (!selection_has_clusters (config, strategy_name))
        return NULL;
    for (index = 0; index < config->count; index++) {
        struct selection_metric metric;

        if (query_cluster_metric (config->h,
                                  config->uris[index],
                                  best_metric->kind,
                                  &metric)
                < 0)
            continue;
        if (!best_uri || selection_metric_is_better (&metric, best_metric)) {
            *best_metric = metric;
            best_uri = config->uris[index];
        }
    }
    if (!best_uri) {
        errno = EIO;
        flux_log (config->h, LOG_ERR, "%s", failure_message);
    }
    return best_uri;
}

static const char *select_shortest_match_cluster (struct cluster_config *config)
{
    struct selection_metric best_metric = {
        .kind = SELECTION_METRIC_MATCH_TIME,
        .value.match_time = 0.0,
    };
    const char *best_uri = select_cluster_by_metric (config,
                                                     "shortest_match",
                                                     "Unable to compute shortest_match for any cluster",
                                                     &best_metric);

    if (!best_uri) {
        return NULL;
    }
    flux_log (config->h,
              LOG_INFO,
              "Selected %s with max match time %lf",
              best_uri,
              best_metric.value.match_time);
    return best_uri;
}

static const char *select_least_pending_cluster (struct cluster_config *config)
{
    struct selection_metric best_metric = {
        .kind = SELECTION_METRIC_PENDING_JOBS,
        .value.pending_jobs = 0,
    };
    const char *best_uri = select_cluster_by_metric (config,
                                                     "least_pending",
                                                     "Unable to compute least_pending for any cluster",
                                                     &best_metric);

    if (!best_uri) {
        return NULL;
    }
    flux_log (config->h,
              LOG_INFO,
              "Selected %s with pending job count %ld",
              best_uri,
              best_metric.value.pending_jobs);
    return best_uri;
}

const char *select_cluster (struct cluster_config *config, const char *strategy)
{
    if (!strategy || !config) {
        errno = EINVAL;
        return NULL;
    }
    if (strcmp (strategy, "least_pending") == 0)
        return select_least_pending_cluster (config);
    if (strcmp (strategy, "shortest_match") == 0)
        return select_shortest_match_cluster (config);
    return select_random_cluster (config);
}