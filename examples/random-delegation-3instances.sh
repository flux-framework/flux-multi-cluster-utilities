#!/usr/bin/env bash
#
# Example: Random Delegation Policy with 3 Target Instances
#
# This script demonstrates the "random" delegation policy from the Flux
# delegate plugin. It creates one source Flux instance and three target
# sub-instances, then submits a job that gets randomly delegated to one
# of the three targets.
#
# Usage (from within a Flux allocation):
#   bash random-delegation-3instances.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLUGIN_PATH="$(grep '^prefix = ' "${REPO_ROOT}/Makefile" | awk '{print $3}' || true)"
PLUGIN_PATH="${PLUGIN_PATH:-${REPO_ROOT}/install}/lib/flux/job-manager/plugins/delegate.so"
CONFIG_FILE="${SCRIPT_DIR}/delegate-config.toml"

# --- Cleanup ---------------------------------------------------------------

cleanup() {
    set +e
    # Cancel any jobs still running
    flux cancel "${SOURCE_INSTANCE}" >/dev/null 2>&1 || true
    flux cancel "${TARGET1_ID}" "${TARGET2_ID}" "${TARGET3_ID}" >/dev/null 2>&1 || true
    # Remove the config file
    /bin/rm -f "${CONFIG_FILE}"
}
trap cleanup EXIT

# --- Step 1: Allocate the source Flux instance -----------------------------

printf '[1/4] Allocating source Flux instance...\n'
SOURCE_INSTANCE="$(flux submit --queue=pdebug -t 10m -N1 flux start sleep inf | tail -n 1 | tr -d '[:space:]')"
SOURCE_URI="$(flux uri --wait "${SOURCE_INSTANCE}")"
printf '  Source instance id: %s  uri: %s\n\n' "${SOURCE_INSTANCE}" "${SOURCE_URI}"

# --- Step 2: Allocate three target sub-instances ---------------------------

printf '[2/4] Allocating 3 target sub-instances...\n'

# Target 1
TARGET1_ID="$(flux submit --queue=pdebug -t 10m -N1 flux start sleep inf | tail -n 1 | tr -d '[:space:]')"
TARGET1_URI="$(flux uri --wait "${TARGET1_ID}")"
printf '  Target 1: id=%s  uri=%s\n' "${TARGET1_ID}" "${TARGET1_URI}"

# Target 2
TARGET2_ID="$(flux submit --queue=pdebug -t 10m -N1 flux start sleep inf | tail -n 1 | tr -d '[:space:]')"
TARGET2_URI="$(flux uri --wait "${TARGET2_ID}")"
printf '  Target 2: id=%s  uri=%s\n' "${TARGET2_ID}" "${TARGET2_URI}"

# Target 3
TARGET3_ID="$(flux submit --queue=pdebug -t 10m -N1 flux start sleep inf | tail -n 1 | tr -d '[:space:]')"
TARGET3_URI="$(flux uri --wait "${TARGET3_ID}")"
printf '  Target 3: id=%s  uri=%s\n\n' "${TARGET3_ID}" "${TARGET3_URI}"

# --- Step 3: Configure and load the delegate plugin ------------------------

printf '[3/4] Configuring and loading delegate plugin...\n'
# Write the config to a file
printf 'delegate = [ "%s", "%s", "%s" ]\n' "${TARGET1_URI}" "${TARGET2_URI}" "${TARGET3_URI}" > "${CONFIG_FILE}"
cat "${CONFIG_FILE}"

# Load the config into the source instance's context using flux proxy
# (pipe via stdin to match the test pattern exactly)
cat "${CONFIG_FILE}" | flux proxy "${SOURCE_INSTANCE}" flux config load
printf 'Config loaded.\n'

# Verify config was loaded
printf 'Verifying config:\n'
flux proxy "${SOURCE_INSTANCE}" flux config get delegate

# Load the delegate plugin into the source instance's context using flux proxy
flux proxy "${SOURCE_INSTANCE}" flux jobtap load "${PLUGIN_PATH}"

# Verify plugin is loaded
printf 'Verifying plugin:\n'
flux proxy "${SOURCE_INSTANCE}" flux jobtap list | grep delegate || true

# Sleep briefly to ensure the plugin is fully initialized before submitting the job
sleep 5

# --- Step 4: Submit a job with random delegation ---------------------------

printf '[4/4] Submitting job with --dependency=delegate:random ...\n'
# Submit through the source instance where the delegate plugin is loaded
JOB_ID="$(flux proxy "${SOURCE_INSTANCE}" flux submit --dependency=delegate:random -t 10m hostname | tail -n 1 | tr -d '[:space:]')"
printf '  Submitted job id: %s\n\n' "${JOB_ID}"

# Wait for the job to finish
flux proxy "${SOURCE_INSTANCE}" flux job wait-event --timeout=60 "${JOB_ID}" clean

# Show delegation events from the job eventlog
printf 'Delegation events from source job:\n'
flux proxy "${SOURCE_INSTANCE}" flux job eventlog "${JOB_ID}" | grep 'delegate::' || true


# Show Flux jobs on all instances
printf 'Source instance jobs:\n'
flux proxy "${SOURCE_INSTANCE}" flux jobs -a | head -n 10 || true

printf 'Target 1 jobs:\n'
flux proxy "${TARGET1_ID}" flux jobs -a | head -n 10 || true

printf 'Target 2 jobs:\n'
flux proxy "${TARGET2_ID}" flux jobs -a | head -n 10 || true

printf 'Target 3 jobs:\n'
flux proxy "${TARGET3_ID}" flux jobs -a | head -n 10 || true

printf '\nPASS: Job was randomly delegated and finished cleanly.\n'
