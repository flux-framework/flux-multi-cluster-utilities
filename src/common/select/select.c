/************************************************************\
 * Copyright 2026 Lawrence Livermore National Security, LLC
 * (c.f. AUTHORS, NOTICE.LLNS, COPYING)
 *
 * This file is part of the Flux resource manager framework.
 * For details, see https://github.com/flux-framework.
 *
 * SPDX-License-Identifier: LGPL-3.0
\************************************************************/

#include "select.h"

/* Configuration structure */
struct cluster_config {
    flux_t *h;
    char **uris;     /* Array of cluster URIs */
    int count;       /* Number of clusters */
    int initialized; /* Random seed initialized flag */
};

struct cluster_config *selection_init(flux_t *h) {
    struct cluster_config *config;
    if (!(config = malloc(sizeof (struct cluster_config))))
        return NULL;
    config->h = h;
    return config;
}

void selection_destroy(struct cluster_config *config){
    free (config);
}

const char *select_cluster (struct cluster_config *config, const char *scheme) {
    return NULL;
}
