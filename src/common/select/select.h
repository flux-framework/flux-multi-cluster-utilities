/************************************************************\
 * Copyright 2026 Lawrence Livermore National Security, LLC
 * (c.f. AUTHORS, NOTICE.LLNS, COPYING)
 *
 * This file is part of the Flux resource manager framework.
 * For details, see https://github.com/flux-framework.
 *
 * SPDX-License-Identifier: LGPL-3.0
\************************************************************/

#include <stdbool.h>
#include <stddef.h>

#include <flux/core.h>
#include <jansson.h>

struct selection_request {
	const char *strategy;
	json_t *jobspec;            /* borrowed, optional for legacy policies */
	json_t *performance_params; /* borrowed typed object */
	bool allow_resource_rewrite;
	size_t original_nodes;
};

struct selection_result {
	const char *uri;    /* borrowed from cluster_config */
	const char *system; /* borrowed from cluster_config/provider-owned data */
	size_t target_index;
	size_t selected_nodes;
	size_t original_nodes;
	bool requires_jobspec_rewrite;
	bool rewrite_allowed;
	double predicted_execution_time;
	const char *performance_candidate_id;
	char reason[256];
};

/* Initialize the selection logic.
 */
struct cluster_config *selection_init (flux_t *h);

/* Tear down the selection logic.
 */
void selection_destroy (struct cluster_config *config);

/* Select and return a URI to delegate an incoming job to.
 */
const char *select_cluster (struct cluster_config *config, const char *strategy);

/* Select a cluster and fill richer selection metadata.  The URI and string
 * pointers in result are borrowed from selection-owned storage.
 */
int select_cluster_with_result (struct cluster_config *config,
								const struct selection_request *request,
								struct selection_result *result);
