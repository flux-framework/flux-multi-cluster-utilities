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
#include <ctype.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "select.h"
#include "select_private.h"

struct toml_parser {
    flux_t *h;
    const char *path;
    const char *input;
    size_t length;
    size_t pos;
    size_t line;
};

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

static void config_parse_error (struct toml_parser *parser, const char *message)
{
    flux_log (parser->h,
              LOG_ERR,
              "Invalid selection config %s at line %zu: %s",
              parser->path,
              parser->line,
              message);
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

static void toml_skip_space (struct toml_parser *parser)
{
    while (parser->pos < parser->length) {
        char c = parser->input[parser->pos];

        if (c == ' ' || c == '\t' || c == '\r') {
            parser->pos++;
        } else if (c == '\n') {
            parser->line++;
            parser->pos++;
        } else if (c == '#') {
            while (parser->pos < parser->length && parser->input[parser->pos] != '\n')
                parser->pos++;
        } else {
            break;
        }
    }
}

static int toml_expect_char (struct toml_parser *parser, char expected, const char *message)
{
    if (parser->pos >= parser->length || parser->input[parser->pos] != expected) {
        config_parse_error (parser, message);
        errno = EINVAL;
        return -1;
    }
    parser->pos++;
    return 0;
}

static int toml_parse_key (struct toml_parser *parser, char **key)
{
    size_t start;

    if (parser->pos >= parser->length
        || (!isalpha ((unsigned char)parser->input[parser->pos])
            && parser->input[parser->pos] != '_')) {
        config_parse_error (parser, "expected a bare key");
        errno = EINVAL;
        return -1;
    }
    start = parser->pos;
    while (parser->pos < parser->length) {
        char c = parser->input[parser->pos];

        if (!isalnum ((unsigned char)c) && c != '_' && c != '-')
            break;
        parser->pos++;
    }
    if (!(*key = strndup (parser->input + start, parser->pos - start)))
        return -1;
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

static int toml_parse_string (struct toml_parser *parser, char **value)
{
    char quote;
    size_t capacity = 16;
    size_t length = 0;
    char *buffer;

    if (parser->pos >= parser->length
        || (parser->input[parser->pos] != '"' && parser->input[parser->pos] != '\'')) {
        config_parse_error (parser, "expected a quoted string");
        errno = EINVAL;
        return -1;
    }
    if (!(buffer = malloc (capacity)))
        return -1;
    quote = parser->input[parser->pos++];
    while (parser->pos < parser->length) {
        char c = parser->input[parser->pos++];

        if (c == '\n') {
            parser->line++;
            if (quote == '\'')
                break;
        }
        if (c == quote) {
            buffer[length] = '\0';
            *value = buffer;
            return 0;
        }
        if (quote == '"' && c == '\\') {
            if (parser->pos >= parser->length) {
                config_parse_error (parser, "unterminated escape sequence");
                errno = EINVAL;
                free (buffer);
                return -1;
            }
            c = parser->input[parser->pos++];
            if (c == 'n')
                c = '\n';
            else if (c == 'r')
                c = '\r';
            else if (c == 't')
                c = '\t';
            else if (c != '\\' && c != '"') {
                config_parse_error (parser, "unsupported escape sequence");
                errno = EINVAL;
                free (buffer);
                return -1;
            }
        }
        if (length + 2 > capacity) {
            char *expanded;

            if (capacity > SIZE_MAX / 2) {
                errno = EOVERFLOW;
                free (buffer);
                return -1;
            }
            capacity *= 2;
            if (!(expanded = realloc (buffer, capacity))) {
                free (buffer);
                return -1;
            }
            buffer = expanded;
        }
        buffer[length++] = c;
    }
    config_parse_error (parser, "unterminated string");
    errno = EINVAL;
    free (buffer);
    return -1;
}

static int toml_parse_clusters (struct toml_parser *parser,
                                char ***uris,
                                size_t *count)
{
    size_t capacity = 0;

    if (toml_expect_char (parser, '[', "expected '[' to start clusters array") < 0)
        return -1;
    toml_skip_space (parser);
    if (parser->pos < parser->length && parser->input[parser->pos] == ']') {
        parser->pos++;
        return 0;
    }
    while (parser->pos < parser->length) {
        char *uri = NULL;

        if (toml_parse_string (parser, &uri) < 0)
            goto error;
        if (*uri == '\0') {
            free (uri);
            config_parse_error (parser, "cluster entries must not be empty");
            errno = EINVAL;
            goto error;
        }
        if (toml_append_uri (uris, count, &capacity, uri) < 0) {
            free (uri);
            goto error;
        }
        toml_skip_space (parser);
        if (parser->pos < parser->length && parser->input[parser->pos] == ']') {
            parser->pos++;
            return 0;
        }
        if (toml_expect_char (parser, ',', "expected ',' between cluster entries") < 0)
            goto error;
        toml_skip_space (parser);
        if (parser->pos < parser->length && parser->input[parser->pos] == ']') {
            parser->pos++;
            return 0;
        }
    }
    config_parse_error (parser, "unterminated clusters array");
    errno = EINVAL;
error:
    while (*count > 0)
        free ((*uris)[--(*count)]);
    free (*uris);
    *uris = NULL;
    return -1;
}

static int load_config (struct cluster_config *config, const char *config_path)
{
    struct toml_parser parser;
    char *text = NULL;
    char *key = NULL;
    char **uris = NULL;
    size_t count = 0;
    bool saw_clusters = false;

    if (!config || !config_path) {
        errno = EINVAL;
        return -1;
    }
    if (read_config_text (config_path, &text) < 0) {
        flux_log (config->h, LOG_ERR, "Failed to read selection config %s", config_path);
        return -1;
    }
    parser = (struct toml_parser){
        .h = config->h,
        .path = config_path,
        .input = text,
        .length = strlen (text),
        .line = 1,
    };
    toml_skip_space (&parser);
    while (parser.pos < parser.length) {
        if (toml_parse_key (&parser, &key) < 0)
            goto error;
        toml_skip_space (&parser);
        if (toml_expect_char (&parser, '=', "expected '=' after key") < 0)
            goto error;
        toml_skip_space (&parser);
        if (strcmp (key, "clusters") != 0) {
            config_parse_error (&parser, "only the 'clusters' key is supported");
            errno = EINVAL;
            goto error;
        }
        if (saw_clusters) {
            config_parse_error (&parser, "duplicate 'clusters' key");
            errno = EINVAL;
            goto error;
        }
        if (toml_parse_clusters (&parser, &uris, &count) < 0)
            goto error;
        saw_clusters = true;
        free (key);
        key = NULL;
        toml_skip_space (&parser);
    }
    if (!saw_clusters) {
        flux_log (config->h,
                  LOG_ERR,
                  "Selection config %s is missing a TOML string array named 'clusters'",
                  config_path);
        errno = EINVAL;
        goto error;
    }
    if (count == 0) {
        flux_log (config->h, LOG_ERR, "Selection config %s contains no clusters", config_path);
        errno = ENOENT;
        goto error;
    }
    config->uris = uris;
    config->count = count;
    free (text);
    return 0;

error:
    free (key);
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