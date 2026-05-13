/************************************************************\
 * Copyright 2026 Lawrence Livermore National Security, LLC
 * (c.f. AUTHORS, NOTICE.LLNS, COPYING)
 *
 * This file is part of the Flux resource manager framework.
 * For details, see https://github.com/flux-framework.
 *
 * SPDX-License-Identifier: LGPL-3.0
 \************************************************************/

#if HAVE_CONFIG_H
#include "config.h"
#endif

#include <ctype.h>
#include <errno.h>
#include <float.h>
#include <limits.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <jansson.h>

#include "performance.h"
#include "select.h"

struct performance_target {
    char *system;
    char *uri;
    size_t nodes;
    size_t index;
};

struct cluster_config {
    flux_t *h;
    char **uris;
    size_t count;
    bool random_seeded;
    struct performance_target *performance_targets;
    size_t performance_target_count;
    struct performance_provider *performance_provider;
    bool performance_allow_resource_rewrite;
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

static void set_result_reason (struct selection_result *result, const char *fmt, ...)
{
    va_list ap;

    if (!result)
        return;
    va_start (ap, fmt);
    vsnprintf (result->reason, sizeof (result->reason), fmt, ap);
    va_end (ap);
}

static void selection_result_init (struct selection_result *result)
{
    if (result)
        memset (result, 0, sizeof (*result));
}

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
        .value.match_time = DBL_MAX,
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
        .value.pending_jobs = INT64_MAX,
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

/*
 * Parse a non-negative integer from string s.
 * Returns 0 on success and sets *out to the parsed value.
 * Returns -1 and sets errno on failure:
 *   EINVAL     — empty or NULL input, or non-numeric characters
 *   ERANGE     — overflow / out of range for size_t
 */
static int parse_assign_index (const char *s, size_t *out)
{
    char *endptr = NULL;

    if (!s || *s == '\0') {
        errno = EINVAL;
        return -1;
    }
    /* Reject leading whitespace or negative sign */
    if (*s == '-' || !isdigit ((unsigned char)*s)) {
        errno = EINVAL;
        return -1;
    }

    errno = 0;
    unsigned long val = strtoul (s, &endptr, 10);
    if (errno == ERANGE || *endptr != '\0' || val > SIZE_MAX) {
        errno = ERANGE;
        return -1;
    }

    *out = (size_t)val;
    return 0;
}

/*
 * Select cluster by explicit sub-instance index.
 *
 * Strategy string formats:
 *   "assign"          → defaults to index 0
 *   "assign:<N>"      → select cluster at index N
 *
 * Returns the URI on success, or NULL with errno set on failure.
 */
static const char *select_assign_cluster (struct cluster_config *config, const char *strategy)
{
    size_t idx = 0;
    const char *suffix = NULL;

    if (!selection_has_clusters (config, "assign"))
        return NULL;

    suffix = strchr (strategy, ':');
    if (suffix) {
        /* Found colon — parse the index from everything after it */
        if (parse_assign_index (suffix + 1, &idx) < 0) {
            flux_log (config->h,
                      LOG_ERR,
                      "assign: invalid sub-instance ID '%s': %s",
                      suffix + 1,
                      strerror (errno));
            return NULL;
        }
    }

    if (idx >= config->count) {
        flux_log (config->h,
                  LOG_ERR,
                  "assign: sub-instance ID %zu out of range (0..%zu)",
                  idx,
                  config->count - 1);
        errno = ERANGE;
        return NULL;
    }

    flux_log (config->h,
              LOG_INFO,
              "Selected cluster %zu by assign policy: %s",
              idx,
              config->uris[idx]);
    return config->uris[idx];
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
    /* Check for assign policy before falling through to random */
    if (strncmp (strategy, "assign", 6) == 0) {
        const char *colon = strchr (strategy, ':');
        if (!colon || *(colon + 1) == '\0') {
            /* "assign" or "assign:" — both default to index 0 */
            return select_assign_cluster (config, strategy);
        }
        return select_assign_cluster (config, strategy);
    }
    return select_random_cluster (config);
}

static struct performance_target *find_performance_target_by_system (struct cluster_config *config,
                                                                     const char *system,
                                                                     size_t nodes)
{
    if (!config || !system)
        return NULL;
    for (size_t i = 0; i < config->performance_target_count; i++) {
        if (strcmp (config->performance_targets[i].system, system) != 0)
            continue;
        if (nodes > config->performance_targets[i].nodes)
            continue;
        return &config->performance_targets[i];
    }
    return NULL;
}

static bool performance_candidate_is_better (struct performance_candidate *candidate,
                                             struct performance_target *candidate_target,
                                             struct performance_candidate *best,
                                             struct performance_target *best_target)
{
    if (!best)
        return true;
    if (candidate->execution_time != best->execution_time)
        return candidate->execution_time < best->execution_time;
    if (candidate_target->index != best_target->index)
        return candidate_target->index < best_target->index;
    if (candidate->nodes != best->nodes)
        return candidate->nodes < best->nodes;
    return candidate->row_index < best->row_index;
}

static int select_performance_cluster (struct cluster_config *config,
                                       const struct selection_request *request,
                                       struct selection_result *result)
{
    struct performance_query query = {0};
    struct performance_candidate **matches = NULL;
    size_t match_count = 0;
    struct performance_candidate *best = NULL;
    struct performance_target *best_target = NULL;
    char errbuf[256] = "";

    if (!request || !request->performance_params) {
        errno = EINVAL;
        set_result_reason (result, "performance requires typed job parameters");
        return -1;
    }
    if (!config->performance_provider) {
        errno = ENOENT;
        set_result_reason (result, "performance provider is not configured");
        return -1;
    }
    query.params = request->performance_params;
    if (performance_provider_lookup (config->performance_provider,
                                     &query,
                                     &matches,
                                     &match_count,
                                     errbuf,
                                     sizeof (errbuf))
        < 0) {
        set_result_reason (result, "performance lookup failed: %s", errbuf);
        return -1;
    }
    for (size_t i = 0; i < match_count; i++) {
        struct performance_target *target = find_performance_target_by_system (config,
                                                                               matches[i]->system,
                                                                               matches[i]->nodes);
        if (!target)
            continue;
        if (performance_candidate_is_better (matches[i], target, best, best_target)) {
            best = matches[i];
            best_target = target;
        }
    }
    free (matches);
    if (!best || !best_target) {
        errno = ENOENT;
        set_result_reason (result, "performance found no configured matching target");
        return -1;
    }
    result->uri = best_target->uri;
    result->system = best_target->system;
    result->target_index = best_target->index;
    result->selected_nodes = best->nodes;
    result->original_nodes = request->original_nodes;
    result->predicted_execution_time = best->execution_time;
    result->performance_candidate_id = best->id;
    result->requires_jobspec_rewrite = request->original_nodes != 0
                                       && best->nodes != request->original_nodes;
    result->rewrite_allowed = config->performance_allow_resource_rewrite
                              && request->allow_resource_rewrite;
    if (result->requires_jobspec_rewrite && !result->rewrite_allowed) {
        errno = EPERM;
        set_result_reason (result,
                           "performance selected nodes=%zu but resource rewrite is not allowed",
                           best->nodes);
        return -1;
    }
    set_result_reason (result,
                       "performance selected system=%s nodes=%zu execution_time=%lf",
                       best->system,
                       best->nodes,
                       best->execution_time);
    flux_log (config->h,
              LOG_INFO,
              "performance selected system=%s target=%zu nodes=%zu execution_time=%lf candidate=%s",
              best->system,
              best_target->index,
              best->nodes,
              best->execution_time,
              best->id ? best->id : "");
    return 0;
}

static size_t legacy_uri_index (struct cluster_config *config, const char *uri)
{
    for (size_t i = 0; config && i < config->count; i++) {
        if (config->uris[i] == uri)
            return i;
    }
    return SIZE_MAX;
}

int select_cluster_with_result (struct cluster_config *config,
                                const struct selection_request *request,
                                struct selection_result *result)
{
    const char *uri;

    if (!request || !request->strategy || !config || !result) {
        errno = EINVAL;
        return -1;
    }
    selection_result_init (result);
    if (strcmp (request->strategy, "performance") == 0)
        return select_performance_cluster (config, request, result);
    if (!(uri = select_cluster (config, request->strategy)))
        return -1;
    result->uri = uri;
    result->target_index = legacy_uri_index (config, uri);
    return 0;
}

static void clear_legacy_targets (struct cluster_config *config)
{
    if (!config || !config->uris)
        return;
    for (size_t i = 0; i < config->count; i++)
        free (config->uris[i]);
    free (config->uris);
    config->uris = NULL;
    config->count = 0;
}

static void clear_performance_targets (struct cluster_config *config)
{
    if (!config || !config->performance_targets)
        return;
    for (size_t i = 0; i < config->performance_target_count; i++) {
        free (config->performance_targets[i].system);
        free (config->performance_targets[i].uri);
    }
    free (config->performance_targets);
    config->performance_targets = NULL;
    config->performance_target_count = 0;
}

static int append_performance_target (struct cluster_config *config,
                                      const char *system,
                                      const char *uri,
                                      size_t nodes)
{
    struct performance_target *targets;
    size_t index = config->performance_target_count;

    if (!system || !uri || nodes == 0) {
        errno = EINVAL;
        return -1;
    }
    if (!(targets = realloc (config->performance_targets, (index + 1) * sizeof (*targets))))
        return -1;
    config->performance_targets = targets;
    memset (&config->performance_targets[index], 0, sizeof (config->performance_targets[index]));
    if (!(config->performance_targets[index].system = strdup (system)))
        return -1;
    if (!(config->performance_targets[index].uri = strdup (uri)))
        return -1;
    config->performance_targets[index].nodes = nodes;
    config->performance_targets[index].index = index;
    config->performance_target_count++;
    return 0;
}

static int load_performance_targets (struct cluster_config *config, json_t *delegate_targets)
{
    size_t index;
    json_t *value;

    if (!delegate_targets)
        return 0;
    if (!json_is_array (delegate_targets)) {
        errno = EINVAL;
        flux_log (config->h, LOG_ERR, "delegate_targets must be an array");
        return -1;
    }
    json_array_foreach (delegate_targets, index, value) {
        const char *system = NULL;
        const char *uri = NULL;
        json_int_t nodes;

        if (json_unpack (value,
                         "{s:s s:s s:I}",
                         "system",
                         &system,
                         "uri",
                         &uri,
                         "nodes",
                         &nodes)
            < 0
            || nodes <= 0) {
            errno = EINVAL;
            flux_log (config->h,
                      LOG_ERR,
                      "delegate_targets[%zu] must define system, uri, and positive nodes",
                      index);
            return -1;
        }
        if (append_performance_target (config, system, uri, (size_t)nodes) < 0) {
            flux_log_error (config->h, "append_performance_target");
            return -1;
        }
    }
    return 0;
}

static int load_performance_config (struct cluster_config *config, json_t *performance)
{
    const char *provider = NULL;
    const char *path = NULL;
    bool allow_resource_rewrite = false;
    char errbuf[256] = "";

    if (!performance)
        return 0;
    if (!json_is_object (performance)) {
        errno = EINVAL;
        flux_log (config->h, LOG_ERR, "performance config must be a table");
        return -1;
    }
    if (json_unpack (performance,
                     "{s?s s?s s?b}",
                     "provider",
                     &provider,
                     "path",
                     &path,
                     "allow_resource_rewrite",
                     &allow_resource_rewrite)
        < 0) {
        errno = EINVAL;
        flux_log (config->h, LOG_ERR, "invalid performance config");
        return -1;
    }
    if (!provider)
        return 0;
    if (strcmp (provider, "toml") != 0) {
        errno = EINVAL;
        flux_log (config->h, LOG_ERR, "unsupported performance provider %s", provider);
        return -1;
    }
    if (!path) {
        errno = EINVAL;
        flux_log (config->h, LOG_ERR, "performance provider toml requires path");
        return -1;
    }
    if (performance_provider_load_from_toml (path,
                                             &config->performance_provider,
                                             errbuf,
                                             sizeof (errbuf))
        < 0) {
        flux_log (config->h, LOG_ERR, "%s", errbuf[0] ? errbuf : "failed to load performance provider");
        return -1;
    }
    config->performance_allow_resource_rewrite = allow_resource_rewrite;
    return 0;
}

/* Load cluster URIs from the Flux runtime configuration.
 * Expects a top-level "delegate" key whose value is an array of URI
 * strings.  An absent or empty array yields a zero-cluster config.
 */
static int load_config (struct cluster_config *config)
{
    flux_error_t error;
    json_t *delegate = NULL;
    json_t *delegate_targets = NULL;
    json_t *performance = NULL;
    const flux_conf_t *conf;
    size_t index;
    json_t *value;

    if (!(conf = flux_get_conf (config->h))) {
        flux_log_error (config->h, "flux_get_conf");
        return -1;
    }

    if (flux_conf_unpack (conf,
                          &error,
                          "{s?o s?o s?o}",
                          "delegate",
                          &delegate,
                          "delegate_targets",
                          &delegate_targets,
                          "performance",
                          &performance)
        < 0) {
        flux_log (config->h, LOG_ERR, "flux_conf_unpack: %s", error.text);
        return -1;
    }

    if (!delegate || !json_is_array (delegate)) {
        config->count = 0;
        config->uris = NULL;
    } else {
        config->count = json_array_size (delegate);
        if (config->count == 0) {
            config->uris = NULL;
        } else {
            if (!(config->uris = calloc (config->count, sizeof (char *)))) {
                flux_log_error (config->h, "calloc");
                return -1;
            }

            json_array_foreach (delegate, index, value) {
                const char *uri;
                if (!json_is_string (value)) {
                    flux_log (config->h, LOG_ERR, "delegate array contains non-string");
                    goto error;
                }
                uri = json_string_value (value);
                if (!(config->uris[index] = strdup (uri))) {
                    flux_log_error (config->h, "strdup");
                    goto error;
                }
            }
        }
    }

    if (load_performance_targets (config, delegate_targets) < 0
        || load_performance_config (config, performance) < 0)
        goto error;

    return 0;
error:
    clear_legacy_targets (config);
    clear_performance_targets (config);
    performance_provider_destroy (config->performance_provider);
    config->performance_provider = NULL;
    return -1;
}

struct cluster_config *selection_init (flux_t *h)
{
    struct cluster_config *config;

    if (!h) {
        errno = EINVAL;
        return NULL;
    }
    if (!(config = calloc (1, sizeof (*config))))
        return NULL;
    config->h = h;
    if (load_config (config) < 0) {
        selection_destroy (config);
        return NULL;
    }
    return config;
}

void selection_destroy (struct cluster_config *config)
{
    if (!config)
        return;
    clear_legacy_targets (config);
    clear_performance_targets (config);
    performance_provider_destroy (config->performance_provider);
    free (config);
}
