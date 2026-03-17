/************************************************************\
 * Copyright 2026 Lawrence Livermore National Security, LLC
 * (c.f. AUTHORS, NOTICE.LLNS, COPYING)
 *
 * This file is part of the Flux resource manager framework.
 * For details, see https://github.com/flux-framework.
 *
 * SPDX-License-Identifier: LGPL-3.0
\************************************************************/

#include <jansson.h>

#include "select.h"

/* Configuration structure */
struct cluster_config {
    flux_t *h;
    char **uris;     /* Array of cluster URIs */
    int count;       /* Number of clusters */
    int initialized; /* Random seed initialized flag */
};

/* Load cluster URIs from config file */
static int load_config (struct cluster_config *config)
{
    return 0;
}

struct cluster_config *selection_init (flux_t *h)
{
    struct cluster_config *config;
    if (!(config = malloc (sizeof (struct cluster_config))))
        return NULL;
    config->h = h;
    config->count = 0;
    if (load_config (config) < 0) {
        free (config);
        return NULL;
    }
    return config;
}

void selection_destroy (struct cluster_config *config)
{
    free (config);
}

/* Select a random cluster URI */
static const char *select_random_cluster (struct cluster_config *config)
{
    if (config->count == 0) {
        flux_log (config->h, LOG_ERR, "No clusters available");
        return NULL;
    }

    int index = rand () % config->count;
    flux_log (config->h, LOG_DEBUG, "Selected cluster %d: %s", index, config->uris[index]);

    return config->uris[index];
}

static const char *select_shortest_match_cluster (struct cluster_config *config)
{
    int rc = -1;
    int64_t V, E, J;
    double load, max, avg;
    flux_future_t *f = NULL;
    double *shortest_count;
    const char *queue_uri;

    if (!(f = flux_rpc (config->h, "sched-fluxion-resource.stats-get", NULL, FLUX_NODEID_ANY, 0))) {
        flux_log (config->h, LOG_INFO, "RPC itself failed");
        goto out;
    }

    if (f == NULL) {
        flux_log (config->h, LOG_INFO, "I have a NULL ptr.");
    } else {
        flux_log (config->h, LOG_INFO, "I got not null");
    }

    void *json_str = malloc (sizeof (json_t));
    // const void *json_str;
    int ret = flux_future_get (f, (const void **)&json_str);
    if (ret == -1) {
        flux_log (config->h, LOG_INFO, "==== I got -1 with flux_future_get");
    } else {
        flux_log (config->h, LOG_INFO, "==== flux_future_get payload is non-empty");
    }

    // flux_logconfig->h, LOG_INFO, "RECEIVED RPC OBJECT %s", json_dumps((json_t*)json_str,
    // JSON_INDENT(4)));
    // //flux_logconfig->h, LOG_INFO, "RECEIVED RPC OBJECT %s", json_str);

    if ((rc = flux_rpc_get_unpack (f,
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
                                   &avg))
        < 0) {
        flux_log (config->h, LOG_INFO, "Unpack Failed after RPC!");
        goto out;
    }

    flux_log (config->h, LOG_INFO, "Average Match Time is: %lf", avg);

    // Approach A: Statically iterate over URIs of clusters. Query match times and pick the URI with
    // least max match time

    if (config->count == 0) {
        flux_log (config->h, LOG_ERR, "No clusters available");
        goto out;
    }

    shortest_count = (double *)malloc (config->count * sizeof (double));
    int ind_iter;
    for (ind_iter = 0; ind_iter < config->count; ind_iter++) {
        flux_log (config->h,
                  LOG_DEBUG,
                  "Selecting cluster %d: %s",
                  ind_iter,
                  config->uris[ind_iter]);
        queue_uri = config->uris[ind_iter];
        flux_log (config->h,
                  LOG_DEBUG,
                  "Querying match time for cluster %d: %s",
                  ind_iter,
                  config->uris[ind_iter]);

        flux_t *h1 = flux_open (queue_uri, 0);
        if (!h1) {
            flux_log (config->h,
                      LOG_ERR,
                      "Failed to open flux instance for cluster %d: %s",
                      ind_iter,
                      queue_uri);
            continue;
        }

        flux_future_t *f1 =
            flux_rpc (h1, "sched-fluxion-resource.stats-get", NULL, FLUX_NODEID_ANY, 0);
        if (!f1) {
            flux_log (config->h,
                      LOG_ERR,
                      "Failed to send RPC for cluster %d: %s",
                      ind_iter,
                      queue_uri);
            flux_close (h1);
            continue;
        }

        if ((rc = flux_rpc_get_unpack (f,
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
                                       &avg))
            < 0) {
            flux_log (config->h, LOG_INFO, "Unpack Failed after RPC!");
            goto out;
        }
        flux_log (config->h, LOG_INFO, "Queue URI: %s\nMax match time is: %lf", queue_uri, max);
        shortest_count[ind_iter] = max;
        // flux_logconfig->h, LOG_INFO, "Pending job count: %ld Running queues are %s",
        // json_dumps((json_t*) running_queues, JSON_INDENT(4)));
        //  Process the response from the RPC call
        //  ...

        flux_close (h1);
    }

    // Pick the index with least pending job count
    int least_index = 0;
    double max_match = 999999999.9999f;
    for (ind_iter = 0; ind_iter < config->count; ind_iter++) {
        if (max_match >= shortest_count[ind_iter]) {
            least_index = ind_iter;
            max_match = shortest_count[ind_iter];
        }
    }
    free (shortest_count);
    flux_log (config->h,
              LOG_INFO,
              "Queue %s has shortest max match time of %lf",
              config->uris[least_index],
              max_match);

    return config->uris[least_index];

out:
    flux_log (config->h, LOG_INFO, "\n\nEND. Testing Flux RPC Failed!!!\n\n");
    flux_future_destroy (f);
    return NULL;
}

static const char *select_least_pending_cluster (struct cluster_config *config)
{
    int rc = -1;
    int64_t pending_jobs;
    json_t *running_queues = NULL;
    int *pending_count = NULL;
    // int64_t V, E, J;
    // double load, max, avg;
    const char *queue_uri;
    flux_future_t *f = NULL;

    //------------------------------------------
    // Approach: We can do this in one of two ways.
    //           Approach A is static. Approach B is dynamic:
    //     A. We already have the configs with URIs of each cluster at plugin load
    //        We iterate over each URI, try to get the pending jobs for each and pick the one with
    //        the least.
    //     B. We query the cluster manager to get queue ID for each cluster, try to query pending
    //     jobs for each
    //        and make a decision based on that. Not sure which one is easiest to implement, so
    //        attempting both for reference. We can pick whichever works first, followed by
    //        whichever is most stable.

    if (!(f = flux_rpc (config->h, "sched-fluxion-qmanager.stats-get", NULL, FLUX_NODEID_ANY, 0))) {
        flux_log (config->h, LOG_INFO, "sched-fluxion-qmanager.stats-get RPC failed");
        goto out;
    } else {
        flux_log (config->h, LOG_INFO, "f from RPC call is not null");
    }

    void *json_str = malloc (sizeof (json_t));
    // const void *json_str;
    int ret = flux_future_get (f, (const void **)&json_str);
    if (ret == -1) {
        flux_log (config->h, LOG_INFO, "==== I got -1 with flux_future_get");
    } else {
        flux_log (config->h, LOG_INFO, "==== flux_future_get payload is non-empty");
    }

    // flux_logconfig->h, LOG_INFO, "RECEIVED RPC OBJECT %s", json_dumps((json_t*)json_str,
    // JSON_INDENT(4)));
    // //flux_logconfig->h, LOG_INFO, "RECEIVED RPC OBJECT %s", json_str);

    if ((rc = flux_rpc_get_unpack (f,
                                   "{s?{s?{s?{s?I} s?{s?o}}}}",
                                   "queues",
                                   "default",
                                   "action_counts",
                                   "pending",
                                   &pending_jobs,
                                   "scheduled_queues",
                                   "running",
                                   &running_queues))
        < 0) {
        flux_log (config->h, LOG_INFO, "Unpack Failed after RPC!");
        goto out;
    }

    // pending jobs at top level instance is useless, but keeping it here for reference
    flux_log (config->h, LOG_INFO, "Pending job count is: %ld", pending_jobs);
    flux_log (config->h,
              LOG_INFO,
              "Running queues are %s",
              json_dumps ((json_t *)running_queues, JSON_INDENT (4)));

    // Approach A: Statically iterate over URIs of clusters. Try to query pending jobs

    if (config->count == 0) {
        flux_log (config->h, LOG_ERR, "No clusters available");
        goto out;
    }

    pending_count = (int *)malloc (config->count * sizeof (int));
    int ind_iter;
    for (ind_iter = 0; ind_iter < config->count; ind_iter++) {
        flux_log (config->h,
                  LOG_DEBUG,
                  "Selecting cluster %d: %s",
                  ind_iter,
                  config->uris[ind_iter]);
        queue_uri = config->uris[ind_iter];
        flux_log (config->h,
                  LOG_DEBUG,
                  "Querying pending jobs for cluster %d: %s",
                  ind_iter,
                  config->uris[ind_iter]);

        flux_t *h1 = flux_open (queue_uri, 0);
        if (!h1) {
            flux_log (config->h,
                      LOG_ERR,
                      "Failed to open flux instance for cluster %d: %s",
                      ind_iter,
                      queue_uri);
            continue;
        }

        flux_future_t *f1 =
            flux_rpc (h1, "sched-fluxion-qmanager.stats-get", NULL, FLUX_NODEID_ANY, 0);
        if (!f1) {
            flux_log (config->h,
                      LOG_ERR,
                      "Failed to send RPC for cluster %d: %s",
                      ind_iter,
                      queue_uri);
            flux_close (h1);
            continue;
        }

        if ((rc = flux_rpc_get_unpack (f1,
                                       "{s?{s?{s?{s?I} s?{s?o}}}}",
                                       "queues",
                                       "default",
                                       "action_counts",
                                       "pending",
                                       &pending_jobs,
                                       "scheduled_queues",
                                       "running",
                                       &running_queues))
            < 0) {
            flux_log (config->h, LOG_INFO, "Unpack Failed after RPC!");
            goto out;
        }
        flux_log (config->h,
                  LOG_INFO,
                  "Queue URI: %s\nPending job count is: %ld",
                  queue_uri,
                  pending_jobs);
        pending_count[ind_iter] = pending_jobs;
        // flux_logconfig->h, LOG_INFO, "Pending job count: %ld Running queues are %s",
        // json_dumps((json_t*) running_queues, JSON_INDENT(4)));
        //  Process the response from the RPC call
        //  ...

        flux_close (h1);
    }

    // Pick the index with least pending job count
    int least_index = 0;
    int min_pending = 9999999;
    for (ind_iter = 0; ind_iter < config->count; ind_iter++) {
        if (min_pending >= pending_count[ind_iter]) {
            least_index = ind_iter;
            min_pending = pending_count[ind_iter];
        }
    }
    free (pending_count);
    flux_log (config->h,
              LOG_INFO,
              "Queue %s has least no. of jobs %d",
              config->uris[least_index],
              min_pending);

    return config->uris[least_index];
out:
    flux_log (config->h, LOG_INFO, "\n\nEND. Testing Flux RPC Failed!!!\n\n");
    flux_future_destroy (f);
    return NULL;
}

const char *select_cluster (struct cluster_config *config, const char *strategy)
{
    if (!strategy || !config) {
        errno = EINVAL;
        return NULL;
    }
    if (strcmp (strategy, "least_pending") == 0) {
        return select_least_pending_cluster (config);
    } else if (strcmp (strategy, "shortest_match") == 0) {
        return select_shortest_match_cluster (config);
    } else {
        return select_random_cluster (config);
    }
}
