#
#  Export variables for flux-multi-cluster-utilities testsuite
#

#
#  Unset variables important to Flux
#
unset FLUX_CONFIG
unset FLUX_MODULE_PATH
unset FLUX_PMI_CLIENT_SEARCHPATH
unset FLUX_PMI_CLIENT_METHODS

# Unset any user defined output defaults
unset FLUX_JOBS_FORMAT_DEFAULT
unset FLUX_RESOURCE_LIST_FORMAT_DEFAULT
unset FLUX_RESOURCE_DRAIN_FORMAT_DEFAULT
unset FLUX_RESOURCE_STATUS_FORMAT_DEFAULT
unset FLUX_QUEUE_LIST_FORMAT_DEFAULT
unset FLUX_PGREP_FORMAT_DEFAULT

#
#  FLUX_BUILD_DIR and FLUX_SOURCE_DIR are set to build and source paths
#
if test -z "$FLUX_BUILD_DIR"; then
    if test -z "${builddir}"; then
        FLUX_BUILD_DIR="$(cd .. && pwd)"
    else
        FLUX_BUILD_DIR="$(cd ${builddir}/.. && pwd))"
    fi
    export FLUX_BUILD_DIR
fi
if test -z "$FLUX_SOURCE_DIR"; then
    if test -z "${srcdir}"; then
        FLUX_SOURCE_DIR="$(cd ${SHARNESS_TEST_SRCDIR}/.. && pwd)"
    else
        FLUX_SOURCE_DIR="$(cd ${srcdir}/.. && pwd)"
    fi
    export FLUX_SOURCE_DIR
fi

#
#  Check if flux command is available in PATH
#  (Required to run most tests, but not all)
#
if command -v flux >/dev/null 2>&1; then
    FLUX_FOUND=1
    export FLUX_FOUND

    # Get FLUX_PREFIX if not already set
    if test -z "$FLUX_PREFIX"; then
        FLUX_PREFIX="$(flux getattr config.path 2>/dev/null | sed 's|/etc/flux$||')"
        export FLUX_PREFIX
    fi
fi

# vi: ts=4 sw=4 expandtab
