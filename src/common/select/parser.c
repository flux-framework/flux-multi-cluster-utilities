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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../libtomlc99/toml.h"
#include "select.h"
#include "select_private.h"

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

static void config_parse_error (flux_t *h, const char *path, const char *message)
{
    flux_log (h, LOG_ERR, "Invalid selection config %s: %s", path, message);
}

static int read_config_text (const char *config_path, char **text)
{
    FILE *fp = NULL;
    long size;
    char *buffer = NULL;

    if (!config_path || !text) {
        errno = EINVAL;
        return -1;
    }
    if (!(fp = fopen (config_path, "r")))
        return -1;
    if (fseek (fp, 0, SEEK_END) < 0
        || (size = ftell (fp)) < 0
        || fseek (fp, 0, SEEK_SET) < 0) {
        fclose (fp);
        return -1;
    }
    if ((unsigned long)size >= SIZE_MAX) {
        fclose (fp);
        errno = EFBIG;
        return -1;
    }
    if (!(buffer = malloc ((size_t)size + 1))) {
        fclose (fp);
        return -1;
    }
    if (size > 0 && fread (buffer, 1, (size_t)size, fp) != (size_t)size) {
        free (buffer);
        fclose (fp);
        return -1;
    }
    buffer[size] = '\0';
    fclose (fp);
    *text = buffer;
    return 0;
}

static int toml_append_uri (char ***uris, size_t *count, size_t *capacity, char *uri)
{
    char **expanded;

    if (*count == *capacity) {
        size_t new_capacity = (*capacity == 0) ? 4 : *capacity * 2;

        if (new_capacity > SIZE_MAX / sizeof (**uris)) {
            errno = EOVERFLOW;
            return -1;
        }
        if (!(expanded = realloc (*uris, new_capacity * sizeof (**uris))))
            return -1;
        *uris = expanded;
        *capacity = new_capacity;
    }
    (*uris)[*count] = uri;
    (*count)++;
    return 0;
}

static int load_config (struct cluster_config *config, const char *config_path)
{
    char *text = NULL;
    toml_table_t *root = NULL;
    toml_array_t *clusters = NULL;
    char **uris = NULL;
    size_t capacity = 0;
    size_t count = 0;
    int total_keys;
    int index;
    char errbuf[200];

    if (!config || !config_path) {
        errno = EINVAL;
        return -1;
    }
    if (read_config_text (config_path, &text) < 0) {
        flux_log (config->h, LOG_ERR, "Failed to read selection config %s", config_path);
        return -1;
    }
    if (!(root = toml_parse (text, errbuf, sizeof (errbuf)))) {
        config_parse_error (config->h,
                            config_path,
                            errbuf[0] ? errbuf : "parse failure");
        errno = EINVAL;
        goto error;
    }

    total_keys = toml_table_nkval (root) + toml_table_narr (root) + toml_table_ntab (root);
    for (index = 0; index < total_keys; index++) {
        const char *key = toml_key_in (root, index);

        if (!key)
            continue;
        if (strcmp (key, "clusters") != 0) {
            config_parse_error (config->h,
                                config_path,
                                "only the 'clusters' key is supported");
            errno = EINVAL;
            goto error;
        }
    }

    if (!(clusters = toml_array_in (root, "clusters"))) {
        flux_log (config->h,
                  LOG_ERR,
                  "Selection config %s is missing a TOML string array named 'clusters'",
                  config_path);
        errno = EINVAL;
        goto error;
    }

    if (toml_array_kind (clusters) != 'v' || toml_array_type (clusters) != 's') {
        config_parse_error (config->h,
                            config_path,
                            "'clusters' must be a TOML array of strings");
        errno = EINVAL;
        goto error;
    }

    count = toml_array_nelem (clusters);
    if (count == 0) {
        flux_log (config->h, LOG_ERR, "Selection config %s contains no clusters", config_path);
        errno = ENOENT;
        goto error;
    }

    count = 0;
    for (index = 0; index < toml_array_nelem (clusters); index++) {
        const char *raw = toml_raw_at (clusters, index);
        char *uri = NULL;

        if (!raw || toml_rtos (raw, &uri) < 0) {
            config_parse_error (config->h,
                                config_path,
                                "'clusters' must contain only strings");
            errno = EINVAL;
            goto error;
        }
        if (*uri == '\0') {
            free (uri);
            config_parse_error (config->h,
                                config_path,
                                "cluster entries must not be empty");
            errno = EINVAL;
            goto error;
        }
        if (toml_append_uri (&uris, &count, &capacity, uri) < 0) {
            free (uri);
            goto error;
        }
    }

    config->uris = uris;
    config->count = count;
    toml_free (root);
    free (text);
    return 0;

error:
    if (root)
        toml_free (root);
    free (text);
    while (count > 0)
        free (uris[--count]);
    free (uris);
    return -1;
}

struct cluster_config *selection_init (flux_t *h, const char *config_path)
{
    struct cluster_config *config;

    if (!h || !config_path) {
        errno = EINVAL;
        return NULL;
    }
    if (!(config = calloc (1, sizeof (*config))))
        return NULL;
    config->h = h;
    if (load_config (config, config_path) < 0) {
        selection_destroy (config);
        return NULL;
    }
    return config;
}

void selection_destroy (struct cluster_config *config)
{
    if (!config)
        return;
    free_uris (config);
    free (config);
}