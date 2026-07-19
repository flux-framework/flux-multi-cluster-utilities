#ifndef CLUSTER_CONFIG_H
#define CLUSTER_CONFIG_H
#include <flux/core.h>

struct cluster_config {
    flux_t *h;
    char **uris;        /* Array of cluster URIs */
    size_t count;       /* Number of clusters */
    bool random_seeded; /* Random seed initialized flag */
};

/* Create a deep copy of a cluster_config.
 *
 * config - the cluster_config to copy (must not be NULL)
 *
 * Returns a newly allocated cluster_config on success, or NULL on
 * failure (e.g. allocation failure). The caller is responsible for
 * freeing the returned config via cluster_config_destroy().
 */
struct cluster_config *copy_config (struct cluster_config *config);

/* Remove a URI from a given config.
 *
 * Searches config->uris for an entry matching 'uri' and removes it,
 * shrinking the 'uris' array and decrementing 'count' accordingly.
 * If 'uri' is not found in the config, no changes are made.
 *
 * config - the cluster_config to modify (must not be NULL)
 * uri    - the URI string to remove (must not be NULL)
 *
 * Returns 0 on success (including if the URI was found and removed),
 * or -1 on error (e.g. uri not found, or allocation failure while
 * resizing the array), with errno set appropriately.
 */
int config_remove_uri (struct cluster_config *config, const char *uri);

/* Load cluster configuration from the broker into 'config'.
 *
 * config - the cluster_config to populate; config->h must already
 *          be set to a valid flux_t handle before calling
 *
 * Returns 0 on success, or -1 on failure (e.g. broker communication
 * error or malformed configuration), with errno set appropriately.
 */
int load_config (struct cluster_config *config);

/* Destroy a cluster_config and free all associated resources.
 *
 * config - the cluster_config to destroy; safe to pass NULL, in
 *          which case this function is a no-op
 */
void cluster_config_destroy (struct cluster_config *config);

#endif
