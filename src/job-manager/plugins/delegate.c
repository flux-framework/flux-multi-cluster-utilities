/************************************************************\
 * Copyright 2024 Lawrence Livermore National Security, LLC
 * (c.f. AUTHORS, NOTICE.LLNS, COPYING)
 *
 * This file is part of the Flux resource manager framework.
 * For details, see https://github.com/flux-framework.
 *
 * SPDX-License-Identifier: LGPL-3.0
\************************************************************/

/*
 * Jobtap plugin for delegating jobs to another Flux instance
 */


#if HAVE_CONFIG_H
#include "config.h"
#endif

#include <flux/core.h>
#include <flux/jobtap.h>


/*
 * Handle job.dependency.delegate requests
 */
static int depend_cb (flux_plugin_t *p,
                      const char *topic,
                      flux_plugin_arg_t *args,
                      void *arg)
{
    flux_jobid_t id;
    const char *s;


    if (flux_plugin_arg_unpack (args,
                                FLUX_PLUGIN_ARG_IN,
                                "{s:I s:{s:s}}",
                                "id", &id,
                                "dependency",
                                  "value", &s) < 0)
        return flux_jobtap_reject_job (p,
                                       args,
                                       "error processing delegate: %s",
                                       flux_plugin_arg_strerror (args));
    return 0;
}

static const struct flux_plugin_handler tab[] = {
    {"job.dependency.delegate", depend_cb, NULL},
    {0},
};

int flux_plugin_init (flux_plugin_t *p)
{
    return flux_plugin_register (p, "delegate", tab);
}
