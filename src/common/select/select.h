/************************************************************\
 * Copyright 2026 Lawrence Livermore National Security, LLC
 * (c.f. AUTHORS, NOTICE.LLNS, COPYING)
 *
 * This file is part of the Flux resource manager framework.
 * For details, see https://github.com/flux-framework.
 *
 * SPDX-License-Identifier: LGPL-3.0
\************************************************************/

#include <flux/core.h>

/* Initialize the selection logic.
 */
struct cluster_config *selection_init (flux_t *h, const char *config_path);

/* Tear down the selection logic.
 */
void selection_destroy (struct cluster_config *config);

/* Select and return a URI to delegate an incoming job to.
 */
const char *select_cluster (struct cluster_config *config, const char *strategy);
