#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PREFIX="$(grep '^prefix = ' "${REPO_ROOT}/Makefile" | awk '{print $3}' || true)"
PREFIX="${PREFIX:-${REPO_ROOT}/install}"
PLUGIN_PATH="${PREFIX}/lib/flux/job-manager/plugins/delegate.so"
CONFIG_PATH="${SCRIPT_DIR}/random-selection-clusters.toml"

SOURCE_NODES="${SOURCE_NODES:-1}"
TARGET_NODES="${TARGET_NODES:-1}"
NUM_TARGETS="${NUM_TARGETS:-2}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"
SETTLE_SECONDS="${SETTLE_SECONDS:-5}"
KEEP_CONFIG="${KEEP_CONFIG:-0}"

declare -a CHILD_IDS=()
declare -a CHILD_URIS=()
declare -a TEST_JOB_IDS=()
SOURCE_INSTANCE=""

cleanup()
{
    set +e

    if [[ ${#TEST_JOB_IDS[@]} -gt 0 && -n "${SOURCE_INSTANCE}" ]]; then
        flux proxy "${SOURCE_INSTANCE}" flux cancel "${TEST_JOB_IDS[@]}" >/dev/null 2>&1 || true
    fi

    if [[ ${#CHILD_IDS[@]} -gt 0 ]]; then
        flux cancel "${CHILD_IDS[@]}" >/dev/null 2>&1 || true
    fi

    if [[ "${KEEP_CONFIG}" != "1" ]]; then
        rm -f "${CONFIG_PATH}"
    fi
}

trap cleanup EXIT

fail()
{
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

allocation_guidance()
{
    cat <<'EOF' >&2
This test must be run from an allocation-local top-level Flux instance.

Suggested workflow:
1. Obtain an interactive allocation first.
   - Flux-native example: flux alloc -N<needed-nodes>
   - Slurm example: salloc -N<needed-nodes>
2. If your site uses Slurm, start a top-level Flux instance inside that allocation.
3. Run this script from inside that top-level Flux instance.

If you run this from a site-wide instance, nested child Flux instances may queue
instead of starting immediately.
EOF
}

require_command()
{
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

wait_for_running()
{
    local instance_id="$1"
    local label="$2"
    local timeout_remaining="${WAIT_TIMEOUT}"

    while ! flux jobs --format='{status}' "${instance_id}" 2>/dev/null | grep -q 'RUN'; do
        sleep 2
        timeout_remaining=$((timeout_remaining - 2))
        if [[ ${timeout_remaining} -le 0 ]]; then
            printf 'Timed out waiting for %s (%s) to enter RUN\n' "${label}" "${instance_id}" >&2
            printf '\nCurrent job table entry:\n' >&2
            flux jobs -a "${instance_id}" >&2 || true
            printf '\nCurrent queue view:\n' >&2
            (flux queue list || flux queue status) >&2 || true
            printf '\nCurrent eventlog:\n' >&2
            flux job eventlog "${instance_id}" >&2 || true
            printf '\n' >&2
            allocation_guidance
            return 1
        fi
    done
}

wait_for_local_uri()
{
    local instance_id="$1"
    local label="$2"
    local timeout_remaining="${WAIT_TIMEOUT}"
    local local_uri=""

    while [[ ${timeout_remaining} -gt 0 ]]; do
        local_uri="$(flux proxy "${instance_id}" flux getattr local-uri 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ -n "${local_uri}" ]]; then
            printf '%s\n' "${local_uri}"
            return 0
        fi
        sleep 2
        timeout_remaining=$((timeout_remaining - 2))
    done

    printf 'Timed out waiting for %s (%s) local URI to become available\n' "${label}" "${instance_id}" >&2
    printf '\nCurrent job table entry:\n' >&2
    flux jobs -a "${instance_id}" >&2 || true
    printf '\nCurrent eventlog:\n' >&2
    flux job eventlog "${instance_id}" >&2 || true
    return 1
}

write_config()
{
    local uri
    {
        printf 'clusters = [\n'
        for index in "${!CHILD_URIS[@]}"; do
            uri="${CHILD_URIS[$index]}"
            if [[ ${index} -lt $((${#CHILD_URIS[@]} - 1)) ]]; then
                printf '  "%s",\n' "${uri}"
            else
                printf '  "%s"\n' "${uri}"
            fi
        done
        printf ']\n'
    } >"${CONFIG_PATH}"
}

load_plugin_into_top()
{
    flux proxy "${SOURCE_INSTANCE}" bash <<EOF
set -euo pipefail
if flux jobtap list | grep -q 'delegate.so'; then
    flux jobtap remove delegate.so
fi
flux jobtap load "${PLUGIN_PATH}" config="${CONFIG_PATH}"
flux jobtap list
EOF
}

available_free_nodes()
{
    flux resource list | awk 'NR > 1 && $1 == "free" {sum += $3} END {print sum + 0}'
}

run_random_test()
{
    local submit_output="" job_id="" job_status="" eventlog_output=""

    printf '\n=== Strategy: random ===\n'

    if ! submit_output="$(flux proxy "${SOURCE_INSTANCE}" flux submit --dependency='delegate:random' -N1 -n1 hostname 2>&1)"; then
        printf 'Submission failed for strategy random\n'
        printf '%s\n' "${submit_output}"
        printf '\nRecent Flux logs from top instance:\n'
        flux proxy "${SOURCE_INSTANCE}" flux dmesg | tail -n 50 || true
        return 1
    fi

    job_id="$(printf '%s\n' "${submit_output}" | tail -n 1 | tr -d '[:space:]')"
    TEST_JOB_IDS+=("${job_id}")
    printf 'Submitted job id: %s\n' "${job_id}"

    sleep "${SETTLE_SECONDS}"

    job_status="$(flux proxy "${SOURCE_INSTANCE}" flux jobs --format='{id} {status}' "${job_id}" 2>/dev/null || true)"
    eventlog_output="$(flux proxy "${SOURCE_INSTANCE}" flux job eventlog "${job_id}" 2>&1 || true)"

    printf 'Job status: %s\n' "${job_status}"

    if ! printf '%s\n' "${eventlog_output}" | grep -q 'clean$'; then
        printf 'Job did not complete successfully for strategy random\n'
        printf '%s\n' "${eventlog_output}"
        return 1
    fi

    if printf '%s\n' "${eventlog_output}" | grep -q 'DelegationFailure'; then
        printf 'Delegation failure observed for strategy random\n'
        printf '%s\n' "${eventlog_output}"
        return 1
    fi

    if ! printf '%s\n' "${eventlog_output}" | grep -Eq 'delegate::submit|delegate::start'; then
        printf 'Delegate events were not observed for strategy random\n'
        printf '%s\n' "${eventlog_output}"
        return 1
    fi
}

require_command flux
require_command grep
require_command awk

printf '==========================================\n'
printf 'Random Selection And Delegate Test\n'
printf '==========================================\n'
printf 'Repo root: %s\n' "${REPO_ROOT}"
printf 'Script dir: %s\n' "${SCRIPT_DIR}"
printf 'Install prefix: %s\n' "${PREFIX}"
printf 'Plugin path: %s\n' "${PLUGIN_PATH}"
printf 'Config path: %s\n' "${CONFIG_PATH}"
printf 'Source child nodes: %s\n' "${SOURCE_NODES}"
printf 'Target child nodes: %s\n' "${TARGET_NODES}"
printf 'Target child clusters: %s\n' "${NUM_TARGETS}"

printf '\n1-- Verifying prebuilt plugin...\n'
cd "${REPO_ROOT}"
[[ -f "${PLUGIN_PATH}" ]] || fail "Plugin not found: ${PLUGIN_PATH}. Build and install the repo first."

printf '\n2-- Verifying current top-level Flux instance resources...\n'
required_nodes=$((SOURCE_NODES + (NUM_TARGETS * TARGET_NODES)))
free_nodes="$(available_free_nodes)"
printf 'Required free nodes: %s\n' "${required_nodes}"
printf 'Observed free nodes: %s\n' "${free_nodes}"
if [[ "${free_nodes}" -lt "${required_nodes}" ]]; then
    fail "Insufficient free nodes in current top-level Flux instance. Run this from an interactive allocation with enough free resources."
fi

printf '\n3-- Launching child instances...\n'
SOURCE_INSTANCE="$(flux submit -N"${SOURCE_NODES}" flux start sleep inf | tail -n 1)"
CHILD_IDS+=("${SOURCE_INSTANCE}")
printf 'Source instance id: %s\n' "${SOURCE_INSTANCE}"
wait_for_running "${SOURCE_INSTANCE}" "source instance" || fail "Source instance failed to start"

for index in $(seq 1 "${NUM_TARGETS}"); do
    child_id="$(flux submit -N"${TARGET_NODES}" flux start sleep inf | tail -n 1)"
    CHILD_IDS+=("${child_id}")
    printf 'Target instance %s id: %s\n' "${index}" "${child_id}"
    wait_for_running "${child_id}" "target instance ${index}" || fail "Target instance ${index} failed to start"
    child_local_uri="$(wait_for_local_uri "${child_id}" "target instance ${index}")" || fail "Target instance ${index} local URI was not published"
    child_uri="$(flux uri --remote "${child_local_uri}" | tr -d '[:space:]')"
    CHILD_URIS+=("${child_uri}")
    printf 'Target instance %s remote uri: %s\n' "${index}" "${child_uri}"
done

printf '\n4-- Writing cluster TOML configuration...\n'
write_config
cat "${CONFIG_PATH}"

printf '\n5-- Loading delegate plugin into source instance...\n'
load_plugin_into_top || fail "Failed to load delegate plugin into source instance"
sleep "${SETTLE_SECONDS}"

printf '\n6-- Submitting one random-selection delegation test...\n'
run_random_test || fail "Random selection delegation test failed"

printf '\n==========================================\n'
printf 'Summary\n'
printf '==========================================\n'
printf 'Random selection test passed.\n'