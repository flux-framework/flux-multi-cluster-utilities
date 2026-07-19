#include <jansson.h>
#include "cluster_config.h"

static void free_uris (struct cluster_config *config)
{
    size_t index;

    if (!config || !config->uris)
        return;
    for (index = 0; index < config->count; index++)
        free (config->uris[index]);
    free (config->uris);
    config->uris = NULL;
    config->count = 0;
}

struct cluster_config *copy_config (struct cluster_config *config)
{
    struct cluster_config *new_config;

    if (!(new_config = calloc (1, sizeof (*new_config)))) {
        flux_log_error (config->h, "calloc error, copy_config");
        return NULL;
    }
    new_config->h = config->h;
    new_config->count = config->count;
    new_config->random_seeded = config->random_seeded;

    if (!(new_config->uris = calloc (new_config->count, sizeof (char *)))) {
        flux_log_error (config->h, "calloc error, copy_config uris");
        free (new_config);
        return NULL;
    }
    for (size_t i = 0; i < config->count; i++) {
        if (!(new_config->uris[i] = strdup (config->uris[i]))) {
            flux_log_error (config->h, "strdup error, copy_config");
            free_uris (new_config);
            free (new_config);
            return NULL;
        }
    }
    return new_config;
}

int config_remove_uri (struct cluster_config *config, const char *uri)
{
    bool found = false;

    for (size_t i = 0, j = 0; i < config->count; i++) {
        if (!found && strcmp (config->uris[i], uri) == 0) {
            free (config->uris[i]);
            found = true;
        } else {
            config->uris[j++] = config->uris[i];
        }
    }
    if (!found) {
        errno = ENOENT;
        return -1;
    }
    config->uris[--config->count] = NULL;
    return 0;
}

int load_config (struct cluster_config *config)
{
    flux_error_t error;
    json_t *delegate = NULL;
    const flux_conf_t *conf;
    size_t index;
    json_t *value;

    if (!(conf = flux_get_conf (config->h))) {
        flux_log_error (config->h, "flux_get_conf");
        return -1;
    }

    if (flux_conf_unpack (conf, &error, "{s?o}", "delegate", &delegate) < 0) {
        flux_log (config->h, LOG_ERR, "flux_conf_unpack: %s", error.text);
        return -1;
    }

    if (!delegate || !json_is_array (delegate)) {
        config->count = 0;
        config->uris = NULL;
        return 0;
    }

    config->count = json_array_size (delegate);
    if (config->count == 0) {
        config->uris = NULL;
        return 0;
    }
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

    return 0;
error:
    config->count = index;
    free_uris (config);
    return -1;
}
void cluster_config_destroy (struct cluster_config *config)
{
    if (!config)
        return;
    free_uris (config);
    free (config);
}
