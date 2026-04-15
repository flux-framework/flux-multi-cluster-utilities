#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PREFIX="$(grep '^prefix = ' "${REPO_ROOT}/Makefile" | awk '{print $3}' || true)"
PREFIX="${PREFIX:-${REPO_ROOT}/install}"
PLUGIN_PATH="${PREFIX}/lib/flux/job-manager/plugins/delegate.so"
CONFIG_PATH="${SCRIPT_DIR}/random-selection-clusters.toml"
JOB_ROW_FORMAT='{id} {status} {name} {nnodes} {ntasks} {nodelist}'

SOURCE_NODES="${SOURCE_NODES:-1}"
TARGET_NODES="${TARGET_NODES:-1}"
NUM_TARGETS="${NUM_TARGETS:-2}"
TARGET_NODE_COUNTS="${TARGET_NODE_COUNTS:-}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"
SETTLE_SECONDS="${SETTLE_SECONDS:-5}"
KEEP_CONFIG="${KEEP_CONFIG:-0}"

declare -a CHILD_IDS=()
declare -a TARGET_URIS=()
declare -a TARGET_INSTANCE_IDS=()
declare -a TARGET_NODE_COUNT_LIST=()
SOURCE_INSTANCE=""
JOB_ID=""
CONFIG_INPUT_PATH=""

fail()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

usage()
{
    printf 'Usage: %s [NUM_TARGETS|CONFIG_FILE]\n' "$0" >&2
    exit 1
}

load_target_layout()
{
    local index

    if [[ $# -gt 1 ]]; then
        usage
    fi

    if [[ $# -eq 1 ]]; then
        if [[ "$1" =~ ^[0-9]+$ ]]; then
            NUM_TARGETS="$1"
            TARGET_NODES=1
            TARGET_NODE_COUNTS=""
        else
            CONFIG_INPUT_PATH="$1"
            [[ -r "${CONFIG_INPUT_PATH}" ]] || fail "Config file not found: ${CONFIG_INPUT_PATH}"
            # shellcheck disable=SC1090
            source "${CONFIG_INPUT_PATH}"
        fi
    fi

    if [[ -n "${TARGET_NODE_COUNTS}" ]]; then
        read -r -a TARGET_NODE_COUNT_LIST <<<"${TARGET_NODE_COUNTS}"
    else
        for index in $(seq 1 "${NUM_TARGETS}"); do
            TARGET_NODE_COUNT_LIST+=("${TARGET_NODES}")
        done
    fi
}

report_submit_failure()
{
    local submit_output="$1"
    local dmesg_tail=""

    dmesg_tail="$(flux proxy "${SOURCE_INSTANCE}" flux dmesg 2>&1 | tail -n 40 || true)"

    {
        printf 'delegated submit failed\n'
        printf -- '--- submit stdout/stderr ---\n'
        printf '%s\n' "${submit_output}"
        printf -- '--- config path ---\n'
        printf '%s\n' "${CONFIG_PATH}"
        printf -- '--- config contents ---\n'
        cat "${CONFIG_PATH}"
        printf -- '--- source dmesg tail ---\n'
        printf '%s\n' "${dmesg_tail}"
        printf -- '--- end diagnostics ---\n'
    } >&2
}

cleanup()
{
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

wait_for_running()
{
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

wait_for_remote_uri()
{
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

preflight_remote_uri()
{
    local remote_uri="$1"
    local label="$2"
    local preflight_output=""
    local resolved_uri=""

    preflight_output="$(flux proxy "${SOURCE_INSTANCE}" env FLUX_URI="${remote_uri}" flux getattr local-uri 2>&1 || true)"
    resolved_uri="$(printf '%s' "${preflight_output}" | tr -d '[:space:]')"

    if [[ -z "${resolved_uri}" ]]; then
        fail "Source instance cannot open target remote URI for ${label}: ${remote_uri} (environment/runtime URI connectivity problem, not a TOML parser problem)"
    fi
}

wait_for_clean()
{
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

extract_delegated_job_id()
{
    printf '%s\n' "$1" | sed -nE '/delegate::submit/ s/.*jobid["=:[:space:]]+("?)([^",}[:space:]]+).*/\2/p' | head -n 1
}

find_target_job_row()
{
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

wait_for_target_job_row()
{
    local delegated_job_id="$1"
    local remaining="${WAIT_TIMEOUT}"
    local target_job_info=""

    while (( remaining > 0 )); do
        target_job_info="$(find_target_job_row "${delegated_job_id}" || true)"
        if [[ -n "${target_job_info}" ]]; then
            printf '%s\n' "${target_job_info}"
            return 0
        fi
        sleep 1
        remaining=$((remaining - 1))
    done

    return 1
}

write_config()
{
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

load_plugin()
{
    flux proxy "${SOURCE_INSTANCE}" bash <<EOF
set -euo pipefail
if flux jobtap list | grep -q 'delegate.so'; then
    flux jobtap remove delegate.so
fi
flux jobtap load "${PLUGIN_PATH}" config="${CONFIG_PATH}" >/dev/null
EOF
}

load_target_layout "$@"

cd "${REPO_ROOT}"
[[ -f "${PLUGIN_PATH}" ]] || fail "Plugin not found: ${PLUGIN_PATH}"

SOURCE_INSTANCE="$(flux submit -N"${SOURCE_NODES}" flux start sleep inf | tail -n 1 | tr -d '[:space:]')"
CHILD_IDS+=("${SOURCE_INSTANCE}")
wait_for_running "${SOURCE_INSTANCE}" "source instance"
printf 'source instance id: %s\n' "${SOURCE_INSTANCE}"

for index in $(seq 1 "${NUM_TARGETS}"); do
    target_nodes="${TARGET_NODE_COUNT_LIST[$((index - 1))]}"
    child_id="$(flux submit -N"${target_nodes}" flux start sleep inf | tail -n 1 | tr -d '[:space:]')"
    CHILD_IDS+=("${child_id}")
    TARGET_INSTANCE_IDS+=("${child_id}")
    wait_for_running "${child_id}" "target instance ${index}"
    remote_uri="$(wait_for_remote_uri "${child_id}" "target instance ${index}")"
    preflight_remote_uri "${remote_uri}" "target instance ${index}"
    TARGET_URIS+=("${remote_uri}")
    printf 'target instance id: %s\n' "${child_id}"
    printf 'target remote uri: %s\n' "${remote_uri}"
done

write_config
load_plugin
sleep "${SETTLE_SECONDS}"

if submit_output="$(flux proxy "${SOURCE_INSTANCE}" flux submit --dependency='delegate:random' -N1 -n1 hostname 2>&1)"; then
    JOB_ID="$(printf '%s\n' "${submit_output}" | tail -n 1 | tr -d '[:space:]')"
else
    report_submit_failure "${submit_output}"
    fail 'Delegated submit failed'
fi

printf 'submitted job id: %s\n' "${JOB_ID}"

wait_for_clean "${JOB_ID}"
EVENTLOG="$(flux proxy "${SOURCE_INSTANCE}" flux job eventlog "${JOB_ID}")"
DELEGATION_LINES="$(printf '%s\n' "${EVENTLOG}" | grep -E 'delegate::|Delegation' || true)"
DELEGATED_JOB_ID="$(extract_delegated_job_id "${EVENTLOG}")"
TARGET_JOB_INFO=""
SELECTED_TARGET_INSTANCE_ID="not found"
TARGET_JOB_ROW="not found"

[[ -n "${DELEGATION_LINES}" ]] || fail "No delegation events found for ${JOB_ID}"
printf '%s\n' "${DELEGATION_LINES}"

if [[ -n "${DELEGATED_JOB_ID}" ]]; then
    TARGET_JOB_INFO="$(wait_for_target_job_row "${DELEGATED_JOB_ID}" || true)"
    if [[ -n "${TARGET_JOB_INFO}" ]]; then
        IFS='|' read -r SELECTED_TARGET_INSTANCE_ID TARGET_JOB_ROW <<<"${TARGET_JOB_INFO}"
    fi
    printf 'Delegated remote job id: %s\n' "${DELEGATED_JOB_ID}"
else
    printf 'Delegated remote job id: not found\n'
fi

printf 'Selected target instance id: %s\n' "${SELECTED_TARGET_INSTANCE_ID}"
printf 'Target job row: %s\n' "${TARGET_JOB_ROW}"

if printf '%s\n' "${EVENTLOG}" | grep -q 'clean$'; then
    printf 'PASS: job delegated and finished cleanly\n'
else
    fail "Job ${JOB_ID} did not finish cleanly"
fi