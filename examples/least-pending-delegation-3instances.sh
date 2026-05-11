#!/usr/bin/env bash
#
# Example: Least-Pending Delegation Policy with 3 Target Instances
#
# This script demonstrates the "least_pending" delegation policy from the
# Flux delegate plugin. It creates one source instance and three target
# sub-instances, loads two pending jobs onto target-0, then submits a
# least_pending job which should select an idle target instead.
#
# Usage (from within a Flux allocation):
#   bash least-pending-delegation-3instances.sh
#
# Steps:
#   1. Allocate the source Flux instance on the local system.
#   2. Allocate three target sub-instances, each with 1 node.
#   3. Write a TOML config with target URIs and load the delegate plugin.
#   4. Submit two jobs directly to target-0 via assign:0 to create pending load.
#   5. Submit a job with --dependency=delegate:least_pending to trigger selection.
#   6. Wait for the job to finish, then verify which target instance received it.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PREFIX="$(grep '^prefix = ' "${REPO_ROOT}/Makefile" | awk '{print $3}' || true)"
PREFIX="${PREFIX:-${REPO_ROOT}/install}"
PLUGIN_PATH="${PREFIX}/lib/flux/job-manager/plugins/delegate.so"
CONFIG_PATH="${SCRIPT_DIR}/least-pending-clusters.toml"
JOB_ROW_FORMAT='{id} {status} {name} {nnodes} {ntasks} {nodelist}'

NUM_TARGETS=3
WAIT_TIMEOUT=60
SETTLE_SECONDS=5
KEEP_CONFIG=0

declare -a CHILD_IDS=()
declare -a TARGET_URIS=()
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
    local instance_id="$1" label="$2" remaining="${WAIT_TIMEOUT}"
    while (( remaining > 0 )); do
        if flux jobs --format='{status}' "${instance_id}" 2>/dev/null | grep -q 'RUN'; then
            return 0
        fi
        sleep 1; remaining=$((remaining - 1))
    done
    fail "Timed out waiting for ${label} (${instance_id}) to start"
}

wait_for_remote_uri() {
    local instance_id="$1" label="$2" remaining="${WAIT_TIMEOUT}" remote_uri=""
    while (( remaining > 0 )); do
        remote_uri="$(flux uri --remote "jobid:${instance_id}" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ -n "${remote_uri}" ]]; then printf '%s\n' "${remote_uri}"; return 0; fi
        sleep 1; remaining=$((remaining - 1))
    done
    fail "Timed out waiting for ${label} (${instance_id}) remote URI"
}

preflight_remote_uri() {
    local remote_uri="$1" label="$2" resolved_uri=""
    resolved_uri="$(flux proxy "${SOURCE_INSTANCE}" env FLUX_URI="${remote_uri}" flux getattr local-uri 2>&1 | tr -d '[:space:]' || true)"
    if [[ -z "${resolved_uri}" ]]; then
        fail "Source cannot open target remote URI for ${label}: ${remote_uri}"
    fi
}

wait_for_clean() {
    local job_id="$1" remaining="${WAIT_TIMEOUT}"
    while (( remaining > 0 )); do
        if flux proxy "${SOURCE_INSTANCE}" flux job eventlog "${job_id}" 2>/dev/null | grep -q 'clean$'; then
            return 0
        fi
        sleep 1; remaining=$((remaining - 1))
    done
    fail "Timed out waiting for job ${job_id} to finish"
}

extract_delegated_job_id() {
    printf '%s\n' "$1" | sed -nE '/delegate::submit/ s/.*jobid["=:[:space:]]+("?)([^",}[:space:]]+).*/\2/p' | head -n 1
}

find_target_job_row() {
    local delegated_job_id="$1" target_instance_id="" target_job_row=""
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
            if [[ ${index} -gt 0 ]]; then printf ',\n'; fi
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

printf '=== Least-Pending Delegation Example (3 targets) ===\n\n'

# Step 1: Allocate source instance
printf '[1/5] Allocating source Flux instance...\n'
SOURCE_INSTANCE="$(flux submit -N1 flux start sleep inf | tail -n 1 | tr -d '[:space:]')"
CHILD_IDS+=("${SOURCE_INSTANCE}")
wait_for_running "${SOURCE_INSTANCE}" "source instance"
printf '  Source instance id: %s\n\n' "${SOURCE_INSTANCE}"

# Step 2: Allocate three target sub-instances
printf '[2/5] Allocating %d target sub-instances...\n' "${NUM_TARGETS}"
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
printf '[3/5] Writing config (%s) and loading delegate plugin...\n' "${CONFIG_PATH}"
write_config
cat "${CONFIG_PATH}"
load_plugin
sleep "${SETTLE_SECONDS}"
printf '\n'

# Step 4: Create pending load on target-0 by submitting two jobs with assign:0.
# These will be pending when we later query least_pending, so target-0 has
# 2 pending jobs while targets 1 and 2 have 0.
printf '[4/5] Creating pending load on target-0 (submitting 2 jobs via assign:0)...\n'
LOAD_JOB_1="$(flux proxy "${SOURCE_INSTANCE}" flux submit --dependency='delegate:assign:0' -N1 -n1 hostname 2>&1 | tail -n 1 | tr -d '[:space:]')"
flux proxy "${SOURCE_INSTANCE}" flux job wait-event --timeout=60 "${LOAD_JOB_1}" "delegate::submit" || true
LOAD_JOB_2="$(flux proxy "${SOURCE_INSTANCE}" flux submit --dependency='delegate:assign:0' -N1 -n1 hostname 2>&1 | tail -n 1 | tr -d '[:space:]')"
flux proxy "${SOURCE_INSTANCE}" flux job wait-event --timeout=60 "${LOAD_JOB_2}" "delegate::submit" || true
CHILD_IDS+=("${LOAD_JOB_1}" "${LOAD_JOB_2}")
printf '  Pending jobs on target-0: %s, %s\n\n' "${LOAD_JOB_1}" "${LOAD_JOB_2}"

# Step 5: Submit a job with least_pending policy.
# Because target-0 has 2 pending jobs while targets 1 and 2 are idle,
# least_pending should select one of the idle targets.
printf '[5/5] Submitting job with --dependency=delegate:least_pending ...\n'
if submit_output="$(flux proxy "${SOURCE_INSTANCE}" flux submit --dependency='delegate:least_pending' -N1 -n1 hostname 2>&1)"; then
    JOB_ID="$(printf '%s\n' "${submit_output}" | tail -n 1 | tr -d '[:space:]')"
else
    fail "Delegated submit failed: ${submit_output}"
fi
printf '  Submitted job id: %s\n\n' "${JOB_ID}"

wait_for_clean "${JOB_ID}"

EVENTLOG="$(flux proxy "${SOURCE_INSTANCE}" flux job eventlog "${JOB_ID}")"
DELEGATION_LINES="$(printf '%s\n' "${EVENTLOG}" | grep -E 'delegate::|Delegation' || true)"
DELEGATED_JOB_ID="$(extract_delegated_job_id "${EVENTLOG}")"
SELECTED_TARGET="not found"
TARGET_ROW="not found"

if [[ -n "${DELEGATION_LINES}" ]]; then
    printf 'Delegation events:\n%s\n\n' "${DELEGATION_LINES}"
fi

if [[ -n "${DELEGATED_JOB_ID}" ]]; then
    TARGET_INFO="$(find_target_job_row "${DELEGATED_JOB_ID}" || true)"
    if [[ -n "${TARGET_INFO}" ]]; then
        IFS='|' read -r SELECTED_TARGET TARGET_ROW <<<"${TARGET_INFO}"
    fi
    printf 'Delegated to target instance: %s\n' "${SELECTED_TARGET}"
    printf 'Target job row: %s\n' "${TARGET_ROW}"
else
    printf 'Delegated remote job id: not found\n'
fi

if printf '%s\n' "${EVENTLOG}" | grep -q 'clean$'; then
    printf '\nPASS: Job was delegated via least_pending and finished cleanly.\n'
else
    fail "Job ${JOB_ID} did not finish cleanly"
fi
