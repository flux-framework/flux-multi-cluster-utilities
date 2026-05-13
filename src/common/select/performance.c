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

#include <errno.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <flux/core.h>
#include <jansson.h>

#include "performance.h"

struct performance_provider {
    struct performance_candidate *candidates;
    size_t candidate_count;
};

static void set_error (char *errbuf, size_t errbuf_size, const char *fmt, ...)
{
    va_list ap;

    if (!errbuf || errbuf_size == 0)
        return;
    va_start (ap, fmt);
    vsnprintf (errbuf, errbuf_size, fmt, ap);
    va_end (ap);
}

static bool json_number_equal (json_t *a, json_t *b)
{
    if (json_is_integer (a) && json_is_integer (b))
        return json_integer_value (a) == json_integer_value (b);
    if ((json_is_integer (a) || json_is_real (a)) && (json_is_integer (b) || json_is_real (b)))
        return json_number_value (a) == json_number_value (b);
    return false;
}

static bool json_param_value_matches (json_t *candidate, json_t *query)
{
    if (!candidate || !query)
        return false;
    if ((json_is_integer (candidate) || json_is_real (candidate))
        && (json_is_integer (query) || json_is_real (query)))
        return json_number_equal (candidate, query);
    if (json_is_string (candidate) && json_is_string (query))
        return strcmp (json_string_value (candidate), json_string_value (query)) == 0;
    if (json_is_boolean (candidate) && json_is_boolean (query))
        return json_boolean_value (candidate) == json_boolean_value (query);
    return false;
}

static bool candidate_matches_query (const struct performance_candidate *candidate,
                                     const struct performance_query *query)
{
    const char *key;
    json_t *query_value;

    if (!candidate || !query || !json_is_object (candidate->params) || !json_is_object (query->params))
        return false;

    json_object_foreach (query->params, key, query_value) {
        json_t *candidate_value = json_object_get (candidate->params, key);
        if (!json_param_value_matches (candidate_value, query_value))
            return false;
    }
    return true;
}

static void performance_candidate_destroy (struct performance_candidate *candidate)
{
    if (!candidate)
        return;
    free (candidate->id);
    free (candidate->system);
    json_decref (candidate->params);
}

void performance_provider_destroy (struct performance_provider *provider)
{
    if (!provider)
        return;
    if (provider->candidates) {
        for (size_t i = 0; i < provider->candidate_count; i++)
            performance_candidate_destroy (&provider->candidates[i]);
        free (provider->candidates);
    }
    free (provider);
}

static int parse_candidate (json_t *entry,
                            size_t row_index,
                            struct performance_candidate *candidate,
                            char *errbuf,
                            size_t errbuf_size)
{
    const char *id = NULL;
    const char *system = NULL;
    json_t *params = NULL;
    json_t *match = NULL;
    json_int_t nodes;
    double execution_time;

    if (!json_is_object (entry)) {
        errno = EINVAL;
        set_error (errbuf, errbuf_size, "candidate %zu is not a table", row_index);
        return -1;
    }
    match = json_object_get (entry, "match");
    if (match) {
        errno = ENOTSUP;
        set_error (errbuf,
                   errbuf_size,
                   "candidate %zu uses unsupported [candidate.match] syntax",
                   row_index);
        return -1;
    }
    if (json_unpack (entry,
                     "{s?s s:s s:I s:F s:o}",
                     "id",
                     &id,
                     "system",
                     &system,
                     "nodes",
                     &nodes,
                     "execution_time",
                     &execution_time,
                     "params",
                     &params)
        < 0) {
        errno = EINVAL;
        set_error (errbuf,
                   errbuf_size,
                   "candidate %zu must define system, nodes, execution_time, and params",
                   row_index);
        return -1;
    }
    if (nodes <= 0) {
        errno = EINVAL;
        set_error (errbuf, errbuf_size, "candidate %zu nodes must be positive", row_index);
        return -1;
    }
    if (!json_is_object (params)) {
        errno = EINVAL;
        set_error (errbuf, errbuf_size, "candidate %zu params must be a table", row_index);
        return -1;
    }
    if (!(candidate->system = strdup (system)) || (id && !(candidate->id = strdup (id)))) {
        errno = ENOMEM;
        set_error (errbuf, errbuf_size, "out of memory parsing candidate %zu", row_index);
        return -1;
    }
    candidate->nodes = (size_t)nodes;
    candidate->execution_time = execution_time;
    candidate->params = json_deep_copy (params);
    candidate->row_index = row_index;
    if (!candidate->params) {
        errno = ENOMEM;
        set_error (errbuf, errbuf_size, "out of memory copying params for candidate %zu", row_index);
        return -1;
    }
    return 0;
}

int performance_provider_load_from_toml (const char *path,
                                         struct performance_provider **provider,
                                         char *errbuf,
                                         size_t errbuf_size)
{
    flux_error_t error;
    flux_conf_t *conf = NULL;
    json_t *candidate_array = NULL;
    json_t *entry;
    size_t index;
    struct performance_provider *p = NULL;

    if (!path || !provider) {
        errno = EINVAL;
        set_error (errbuf, errbuf_size, "performance provider path is required");
        return -1;
    }
    *provider = NULL;
    if (!(conf = flux_conf_parse (path, &error))) {
        set_error (errbuf, errbuf_size, "failed to parse %s: %s", path, error.text);
        return -1;
    }
    if (flux_conf_unpack (conf, &error, "{s:o}", "candidate", &candidate_array) < 0) {
        flux_conf_decref (conf);
        errno = EINVAL;
        set_error (errbuf, errbuf_size, "performance table %s: %s", path, error.text);
        return -1;
    }
    if (!json_is_array (candidate_array)) {
        flux_conf_decref (conf);
        errno = EINVAL;
        set_error (errbuf, errbuf_size, "performance table %s candidate must be an array", path);
        return -1;
    }
    if (!(p = calloc (1, sizeof (*p)))) {
        flux_conf_decref (conf);
        errno = ENOMEM;
        set_error (errbuf, errbuf_size, "out of memory allocating performance provider");
        return -1;
    }
    p->candidate_count = json_array_size (candidate_array);
    if (p->candidate_count > 0 && !(p->candidates = calloc (p->candidate_count, sizeof (*p->candidates)))) {
        flux_conf_decref (conf);
        performance_provider_destroy (p);
        errno = ENOMEM;
        set_error (errbuf, errbuf_size, "out of memory allocating performance candidates");
        return -1;
    }
    json_array_foreach (candidate_array, index, entry) {
        if (parse_candidate (entry, index, &p->candidates[index], errbuf, errbuf_size) < 0) {
            flux_conf_decref (conf);
            performance_provider_destroy (p);
            return -1;
        }
    }
    flux_conf_decref (conf);
    *provider = p;
    return 0;
}

int performance_provider_lookup (struct performance_provider *provider,
                                 const struct performance_query *query,
                                 struct performance_candidate ***matches,
                                 size_t *match_count,
                                 char *errbuf,
                                 size_t errbuf_size)
{
    struct performance_candidate **out = NULL;
    size_t count = 0;

    if (!provider || !query || !matches || !match_count) {
        errno = EINVAL;
        set_error (errbuf, errbuf_size, "invalid performance lookup arguments");
        return -1;
    }
    *matches = NULL;
    *match_count = 0;
    if (provider->candidate_count > 0 && !(out = calloc (provider->candidate_count, sizeof (*out)))) {
        errno = ENOMEM;
        set_error (errbuf, errbuf_size, "out of memory allocating performance matches");
        return -1;
    }
    for (size_t i = 0; i < provider->candidate_count; i++) {
        if (candidate_matches_query (&provider->candidates[i], query))
            out[count++] = &provider->candidates[i];
    }
    *matches = out;
    *match_count = count;
    return 0;
}
