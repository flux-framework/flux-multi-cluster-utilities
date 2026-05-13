/************************************************************\
 * Copyright 2026 Lawrence Livermore National Security, LLC
 * (c.f. AUTHORS, NOTICE.LLNS, COPYING)
 *
 * This file is part of the Flux resource manager framework.
 * For details, see https://github.com/flux-framework.
 *
 * SPDX-License-Identifier: LGPL-3.0
\************************************************************/

#ifndef FLUX_MULTI_CLUSTER_PERFORMANCE_H
#define FLUX_MULTI_CLUSTER_PERFORMANCE_H

#include <stddef.h>

#include <jansson.h>

struct performance_query {
    const char *table_id;
    json_t *params; /* borrowed typed object */
};

struct performance_candidate {
    char *id;
    char *system;
    size_t nodes;
    double execution_time;
    json_t *params;
    size_t row_index;
};

struct performance_provider;

/* Load a performance provider from an external TOML file.
 *
 * Ownership: on success, *provider must be released with
 * performance_provider_destroy().  Candidate data returned by lookup remains
 * owned by the provider; callers only free the match pointer array.
 */
int performance_provider_load_from_toml (const char *path,
                                         struct performance_provider **provider,
                                         char *errbuf,
                                         size_t errbuf_size);

/* Return provider-owned matching candidates in a newly allocated pointer array.
 * The caller frees *matches, but not the pointed-to candidates.
 */
int performance_provider_lookup (struct performance_provider *provider,
                                 const struct performance_query *query,
                                 struct performance_candidate ***matches,
                                 size_t *match_count,
                                 char *errbuf,
                                 size_t errbuf_size);

void performance_provider_destroy (struct performance_provider *provider);

#endif /* FLUX_MULTI_CLUSTER_PERFORMANCE_H */
