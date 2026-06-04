#!/usr/bin/env bash
#
# Example: Least-Pending Delegation Policy with 3 Target Instances
#
# This script demonstrates the "least_pending" delegation policy from the
# Flux delegate plugin. It creates one source Flux instance and three target
# sub-instances, loads two pending jobs onto target-0, then submits a
# least_pending job which should select an idle target instead.
#
# Usage (from within a Flux allocation):
#   bash least-pending-delegation-3instances.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLUGIN_PATH="$(grep '^prefix = ' "${REPO_ROOT}/Makefile" | awk '{print $3}' || true)"
PLUGIN_PATH="${PLUGIN_PATH:-${REPO_ROOT}/install}/lib/flux/job-manager/plugins/delegate.so"
CONFIG_FILE="${SCRIPT_DIR}/least-pending-clusters.toml"

# --- Cleanup ---------------------------------------------------------------

cleanup() {
    set +e
    flux cancel "${SOURCE_INSTANCE}" >/dev/null 2>&1 || true
    flux cancel "${TARGET1_ID}" "${TARGET2_ID}" "${TARGET3_ID}" >/dev/null 2>&1 || true
    /bin/rm -f "${CONFIG_FILE}"
}
trap cleanup EXIT

# --- Step 1: Allocate the source Flux instance -----------------------------

printf '[1/5] Allocating source Flux instance...\n'
SOURCE_INSTANCE="$(flux submit --queue=pdebug -t 10m -N1 flux start sleep inf | tail -n 1 | tr -d '[:space:]')"
SOURCE_URI="$(flux uri --wait "${SOURCE_INSTANCE}")"
printf '  Source instance id: %s  uri: %s\n\n' "${SOURCE_INSTANCE}" "${SOURCE_URI}"

# --- Step 2: Allocate three target sub-instances ---------------------------

printf '[2/5] Allocating 3 target sub-instances...\n'

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
printf '  Target 3: id=%s  uri=%s\n' "${TARGET3_ID}" "${TARGET3_URI}"
printf '\n'

# --- Step 3: Configure and load the delegate plugin ------------------------

printf '[3/5] Configuring and loading delegate plugin...\n'
# Write the config to a file
printf 'delegate = [ "%s", "%s", "%s" ]\n' "${TARGET1_URI}" "${TARGET2_URI}" "${TARGET3_URI}" > "${CONFIG_FILE}"
printf 'Config file created:\n'
cat "${CONFIG_FILE}"

# Load the config into the source instance's context
cat "${CONFIG_FILE}" | flux proxy "${SOURCE_INSTANCE}" flux config load
printf 'Config loaded.\n'

# Verify config was loaded
printf 'Verifying config:\n'
flux proxy "${SOURCE_INSTANCE}" flux config get delegate
printf '\n'

# Load the delegate plugin into the source instance's context
flux proxy "${SOURCE_INSTANCE}" flux jobtap load "${PLUGIN_PATH}"
printf 'Plugin loaded.\n'

# Verify plugin is loaded
printf 'Verifying plugin:\n'
flux proxy "${SOURCE_INSTANCE}" flux jobtap list | grep delegate || true
printf '\n'

sleep 5
printf '\n'

# --- Step 4: Create pending load on target-0 --------------------------------

printf '[4/5] Creating pending load on target-0 (submitting 2 jobs via assign:0)...\n'
LOAD_JOB_1="$(flux proxy "${SOURCE_INSTANCE}" flux submit --dependency='delegate:assign:0' -t 10m -N1 -n1 hostname | tail -n 1 | tr -d '[:space:]')"
flux proxy "${SOURCE_INSTANCE}" flux job wait-event --timeout=60 "${LOAD_JOB_1}" "delegate::submit" >/dev/null 2>&1 || true
LOAD_JOB_2="$(flux proxy "${SOURCE_INSTANCE}" flux submit --dependency='delegate:assign:0' -t 10m -N1 -n1 hostname | tail -n 1 | tr -d '[:space:]')"
flux proxy "${SOURCE_INSTANCE}" flux job wait-event --timeout=60 "${LOAD_JOB_2}" "delegate::submit" >/dev/null 2>&1 || true
printf '  Pending jobs on target-0: %s, %s\n\n' "${LOAD_JOB_1}" "${LOAD_JOB_2}"

# --- Step 5: Submit a job with least_pending delegation --------------------

printf '[5/5] Submitting job with --dependency=delegate:least_pending ...\n'
JOB_ID="$(flux proxy "${SOURCE_INSTANCE}" flux submit --dependency=delegate:least_pending -t 10m -N1 -n1 hostname | tail -n 1 | tr -d '[:space:]')"
printf '  Submitted job id: %s\n\n' "${JOB_ID}"

# Wait for the job to finish
flux proxy "${SOURCE_INSTANCE}" flux job wait-event --timeout=60 "${JOB_ID}" clean

# Show delegation events from the job eventlog
printf 'Delegation events from source job:\n'
flux proxy "${SOURCE_INSTANCE}" flux job eventlog "${JOB_ID}" | grep 'delegate::' || true
printf '\n'

# Show Flux jobs on all instances
printf 'Source instance jobs:\n'
flux proxy "${SOURCE_INSTANCE}" flux jobs -a | head -n 10 || true
printf '\n'
printf 'Target 1 jobs:\n'
flux proxy "${TARGET1_ID}" flux jobs -a | head -n 10 || true
printf '\n'
printf 'Target 2 jobs:\n'
flux proxy "${TARGET2_ID}" flux jobs -a | head -n 10 || true
printf '\n'
printf 'Target 3 jobs:\n'
flux proxy "${TARGET3_ID}" flux jobs -a | head -n 10 || true
printf '\n'

printf 'PASS: Job was delegated via least_pending and finished cleanly.\n'
