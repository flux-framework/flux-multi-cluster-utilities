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
# Steps:
#   1. Allocate the source Flux instance on the local system.
#   2. Allocate three target sub-instances, each with 1 node.
#   3. Write a TOML config with target URIs and load the delegate plugin.
#   4. Submit a job with --dependency=delegate:random to trigger random selection.
#   5. Wait for the job to finish, then verify which target instance received it.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PREFIX="$(grep '^prefix = ' "${REPO_ROOT}/Makefile" | awk '{print $3}' || true)"
PREFIX="${PREFIX:-${REPO_ROOT}/install}"
PLUGIN_PATH="${PREFIX}/lib/flux/job-manager/plugins/delegate.so"
CONFIG_PATH="${SCRIPT_DIR}/random-clusters.toml"
JOB_ROW_FORMAT='{id} {status} {name} {nnodes} {ntasks} {nodelist}'

# --- Configuration -----------------------------------------------------------
NUM_TARGETS=3            # Number of target sub-instances
WAIT_TIMEOUT=60          # Seconds to wait for instances/jobs
SETTLE_SECONDS=5         # Wait after loading the plugin
KEEP_CONFIG=0            # Set to 1 to keep the TOML config after exit

declare -a CHILD_IDS=()       # All child job IDs (for cleanup)
declare -a TARGET_URIS=()     # Remote URIs for each target
declare -a TARGET_INSTANCE_IDS=()
SOURCE_INSTANCE=""
JOB_ID=""

# --- Helper Functions --------------------------------------------------------

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    set +e
    if [[ -n "${JOB_ID}" && -n "${SOURCE_INSTANCE}" ]]; then
        flux proxy "${SOURCE_INSTANCE}" flux cancel "${JOB_ID}" >/dev/null 2>&1 || true
    fi
    if [[ ${#CHILD_IDS[@]} -gt 0 ]]; then
        flux cancel "${CHILD_IDS[@]}" >/dev/null 2>&1 || true
    fi
    if [[ "${KEEP_CONFIG}" != "1" ]]; then
        rm -f "${CONFIG_PATH}"
    fi
}
trap cleanup EXIT

wait_for_running() {
    local instance_id="$1"
    local label="$2"
    local remaining="${WAIT_TIMEOUT}"

    while (( remaining > 0 )); do
        if flux jobs --format='{status}' "${instance_id}" 2>/dev/null | grep -q 'RUN'; then
            return 0
        fi
        sleep 1
        remaining=$((remaining - 1))
    done
    fail "Timed out waiting for ${label} (${instance_id}) to start"
}

wait_for_remote_uri() {
    local instance_id="$1"
    local label="$2"
    local remaining="${WAIT_TIMEOUT}"
    local remote_uri=""

    while (( remaining > 0 )); do
        remote_uri="$(flux uri --remote "jobid:${instance_id}" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ -n "${remote_uri}" ]]; then
            printf '%s\n' "${remote_uri}"
            return 0
        fi
        sleep 1
        remaining=$((remaining - 1))
    done
    fail "Timed out waiting for ${label} (${instance_id}) remote URI"
}

preflight_remote_uri() {
    local remote_uri="$1"
    local label="$2"
    local resolved_uri=""

    resolved_uri="$(flux proxy "${SOURCE_INSTANCE}" env FLUX_URI="${remote_uri}" flux getattr local-uri 2>&1 | tr -d '[:space:]' || true)"
    if [[ -z "${resolved_uri}" ]]; then
        fail "Source cannot open target remote URI for ${label}: ${remote_uri}"
    fi
}

wait_for_clean() {
    local job_id="$1"
    local remaining="${WAIT_TIMEOUT}"

    while (( remaining > 0 )); do
        if flux proxy "${SOURCE_INSTANCE}" flux job eventlog "${job_id}" 2>/dev/null | grep -q 'clean$'; then
            return 0
        fi
        sleep 1
        remaining=$((remaining - 1))
    done
    fail "Timed out waiting for job ${job_id} to finish"
}

extract_delegated_job_id() {
    printf '%s\n' "$1" | sed -nE '/delegate::submit/ s/.*jobid["=:[:space:]]+("?)([^",}[:space:]]+).*/\2/p' | head -n 1
}

find_target_job_row() {
    local delegated_job_id="$1"
    local target_instance_id="" target_job_row=""

    for target_instance_id in "${TARGET_INSTANCE_IDS[@]}"; do
        target_job_row="$(flux proxy "${target_instance_id}" flux jobs -a --format="${JOB_ROW_FORMAT}" "${delegated_job_id}" 2>/dev/null || true)"
        if [[ -n "${target_job_row}" ]]; then
            printf '%s|%s\n' "${target_instance_id}" "${target_job_row}"
            return 0
        fi
    done
    return 1
}

write_config() {
    local index
    {
        printf 'clusters = [\n'
        for index in "${!TARGET_URIS[@]}"; do
            if [[ ${index} -gt 0 ]]; then
                printf ',\n'
            fi
            printf '  "%s"' "${TARGET_URIS[$index]}"
        done
        printf '\n]\n'
    } >"${CONFIG_PATH}"
}

load_plugin() {
    flux proxy "${SOURCE_INSTANCE}" bash <<EOF
set -euo pipefail
if flux jobtap list | grep -q 'delegate.so'; then
    flux jobtap remove delegate.so
fi
flux jobtap load "${PLUGIN_PATH}" config="${CONFIG_PATH}" >/dev/null
EOF
}

# --- Main --------------------------------------------------------------------

cd "${REPO_ROOT}"
[[ -f "${PLUGIN_PATH}" ]] || fail "Plugin not found: ${PLUGIN_PATH}"

printf '=== Random Delegation Example (3 targets) ===\n\n'

# Step 1: Allocate source instance
printf '[1/4] Allocating source Flux instance...\n'
SOURCE_INSTANCE="$(flux submit -N1 flux start sleep inf | tail -n 1 | tr -d '[:space:]')"
CHILD_IDS+=("${SOURCE_INSTANCE}")
wait_for_running "${SOURCE_INSTANCE}" "source instance"
printf '  Source instance id: %s\n\n' "${SOURCE_INSTANCE}"

# Step 2: Allocate three target sub-instances
printf '[2/4] Allocating %d target sub-instances...\n' "${NUM_TARGETS}"
for index in $(seq 1 "${NUM_TARGETS}"); do
    child_id="$(flux submit -N1 flux start sleep inf | tail -n 1 | tr -d '[:space:]')"
    CHILD_IDS+=("${child_id}")
    TARGET_INSTANCE_IDS+=("${child_id}")
    wait_for_running "${child_id}" "target instance ${index}"
    remote_uri="$(wait_for_remote_uri "${child_id}" "target instance ${index}")"
    preflight_remote_uri "${remote_uri}" "target instance ${index}"
    TARGET_URIS+=("${remote_uri}")
    printf '  Target %d: id=%s  uri=%s\n' "${index}" "${child_id}" "${remote_uri}"
done
printf '\n'

# Step 3: Write TOML config and load plugin
printf '[3/4] Writing config (%s) and loading delegate plugin...\n' "${CONFIG_PATH}"
write_config
cat "${CONFIG_PATH}"
load_plugin
sleep "${SETTLE_SECONDS}"
printf '\n'

# Step 4: Submit a job with random delegation policy
printf '[4/4] Submitting job with --dependency=delegate:random ...\n'
if submit_output="$(flux proxy "${SOURCE_INSTANCE}" flux submit --dependency='delegate:random' -N1 -n1 hostname 2>&1)"; then
    JOB_ID="$(printf '%s\n' "${submit_output}" | tail -n 1 | tr -d '[:space:]')"
else
    fail "Delegated submit failed: ${submit_output}"
fi
printf '  Submitted job id: %s\n\n' "${JOB_ID}"

# Wait for completion and verify result
wait_for_clean "${JOB_ID}"

EVENTLOG="$(flux proxy "${SOURCE_INSTANCE}" flux job eventlog "${JOB_ID}")"
DELEGATION_LINES="$(printf '%s\n' "${EVENTLOG}" | grep -E 'delegate::|Delegation' || true)"
DELEGATED_JOB_ID="$(extract_delegated_job_id "${EVENTLOG}")"
SELECTED_TARGET_INSTANCE_ID="not found"
TARGET_JOB_ROW="not found"

if [[ -n "${DELEGATION_LINES}" ]]; then
    printf 'Delegation events:\n%s\n\n' "${DELEGATION_LINES}"
fi

if [[ -n "${DELEGATED_JOB_ID}" ]]; then
    TARGET_INFO="$(find_target_job_row "${DELEGATED_JOB_ID}" || true)"
    if [[ -n "${TARGET_INFO}" ]]; then
        IFS='|' read -r SELECTED_TARGET_INSTANCE_ID TARGET_JOB_ROW <<<"${TARGET_INFO}"
    fi
    printf 'Delegated to target instance: %s\n' "${SELECTED_TARGET_INSTANCE_ID}"
    printf 'Target job row: %s\n' "${TARGET_JOB_ROW}"
else
    printf 'Delegated remote job id: not found\n'
fi

if printf '%s\n' "${EVENTLOG}" | grep -q 'clean$'; then
    printf '\nPASS: Job was randomly delegated and finished cleanly.\n'
else
    fail "Job ${JOB_ID} did not finish cleanly"
fi
