#!/usr/bin/env bash
#
# Example: Multi-System Job Delegation with Tuolumne, Corona, and Tioga
#
# This script demonstrates real multi-system Flux job delegation across
# three physical systems. It:
#   1. Allocates a source Flux instance on the local system (Tuolumne).
#   2. Allocates target sub-instances on Tuolumne, Corona, and Tioga.
#   3. Writes a delegate config with the target URIs and loads the
#      delegate jobtap plugin into the source instance.
#   4. Submits a trace of jobs through the source instance, each using
#      a different delegation policy (random, least_pending, shortest_match).
#   5. Prints per-job results and a summary tally.
#
# Usage (from within a Tuolumne Flux allocation):
#   bash job-delegation.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLUGIN_PATH="$(grep '^prefix = ' "${REPO_ROOT}/Makefile" | awk '{print $3}' || true)"
PLUGIN_PATH="${PLUGIN_PATH:-${REPO_ROOT}/install}/lib/flux/job-manager/plugins/delegate.so"
CONFIG_FILE="${SCRIPT_DIR}/multisystem-clusters.toml"

# --- Data structures --------------------------------------------------------
declare -a LOCAL_CHILD_IDS=()
declare -A REMOTE_CHILD_IDS=()
declare -a SUBMITTED_JOB_IDS=()

# --- Trace policies to demonstrate ------------------------------------------
# Policies supported: random, least_pending, shortest_match
TRACE_POLICIES=(random random least_pending shortest_match random)

# --- Cleanup ---------------------------------------------------------------

cleanup() {
    set +e
    # Cancel submitted jobs through the source instance
    if [[ ${#SUBMITTED_JOB_IDS[@]} -gt 0 && -n "${SOURCE_INSTANCE}" ]]; then
        timeout 30 flux proxy "${SOURCE_INSTANCE}" flux cancel "${SUBMITTED_JOB_IDS[@]}" >/dev/null 2>&1 || true
    fi
    # Cancel local child instances
    if [[ ${#LOCAL_CHILD_IDS[@]} -gt 0 ]]; then
        flux cancel "${LOCAL_CHILD_IDS[@]}" >/dev/null 2>&1 || true
    fi
    # Cancel remote child instances via SSH
    for host in "${!REMOTE_CHILD_IDS[@]}"; do
        ids="${REMOTE_CHILD_IDS[$host]}"
        [[ -n "${ids}" ]] || continue
        ssh "${host}" "flux cancel ${ids}" >/dev/null 2>&1 || true
    done
    # Remove config file
    /bin/rm -f "${CONFIG_FILE}"
}
trap cleanup EXIT

# --- Helper: wait for a local job to start ----------------------------------

wait_for_running() {
    flux job wait-event --timeout=180 "$1" start >/dev/null 2>&1 || \
        { printf 'FAIL: Timed out waiting for %s (%s) to start\n' "$2" "$1" >&2; exit 1; }
}

# --- Helper: wait for a remote job to start via SSH -------------------------

wait_for_remote_running() {
    ssh "$1" "flux job wait-event --timeout=180 $2 start" >/dev/null 2>&1 || \
        { printf 'FAIL: Timed out waiting for %s (%s) on %s to start\n' "$3" "$2" "$1" >&2; exit 1; }
}

# --- Helper: get URI for a job (local or remote) ----------------------------
# Uses flux uri --wait which blocks until the URI is available.
# For remote targets, runs via SSH on the target host.

wait_for_uri() {
    local id="$1" label="$2"
    flux uri --remote --wait "jobid:${id}" 2>/dev/null || \
        { printf 'FAIL: Timed out waiting for URI of %s (%s)\n' "${label}" "${id}" >&2; exit 1; }
}

wait_for_remote_uri() {
    local host="$1" id="$2" label="$3"
    ssh "${host}" "flux uri --remote --wait jobid:${id}" 2>/dev/null || \
        { printf 'FAIL: Timed out waiting for remote URI of %s (%s) on %s\n' "${label}" "${id}" "${host}" >&2; exit 1; }
}

# --- Helper: verify source can resolve the target URI -----------------------

preflight_remote_uri() {
    local remote_uri="$1"
    local label="$2"
    local resolved_uri=""
    resolved_uri="$(flux proxy "${SOURCE_INSTANCE}" env FLUX_URI="${remote_uri}" flux getattr local-uri 2>&1 | tr -d '[:space:]' || true)"
    if [[ -z "${resolved_uri}" ]]; then
        printf 'FAIL: Source cannot open target URI for %s: %s\n' "${label}" "${remote_uri}" >&2
        exit 1
    fi
}

# --- Helper: extract delegated job ID from eventlog -------------------------

extract_delegated_job_id() {
    printf '%s\n' "$1" | sed -nE '/delegate::submit/ s/.*jobid["=:[:space:]]+("?)([^",}[:space:]]+).*/\2/p' | head -n 1
}

# --- Step 1: Allocate the source Flux instance (local/Tuolumne) -------------

printf '[1/6] Allocating source Flux instance on Tuolumne...\n'
SOURCE_INSTANCE="$(flux submit -t 10m -N1 flux start sleep inf | tail -n 1 | tr -d '[:space:]')"
LOCAL_CHILD_IDS+=("${SOURCE_INSTANCE}")
wait_for_running "${SOURCE_INSTANCE}" "source instance"
printf '  Source instance id: %s\n' "${SOURCE_INSTANCE}"

# --- Step 2: Allocate Tioga target instance ---------------------------------

printf '[2/6] Allocating Tioga target instance...\n'
TIOGA_HOST="tioga.llnl.gov"
TIOGA_CHILD_ID="$(ssh "${TIOGA_HOST}" "flux submit --queue=pdebug --bank=asccasc -t 10m -N1 flux start sleep inf" | tail -n 1 | tr -d '[:space:]')"
REMOTE_CHILD_IDS["${TIOGA_HOST}"]="${TIOGA_CHILD_ID}"
wait_for_remote_running "${TIOGA_HOST}" "${TIOGA_CHILD_ID}" "Tioga target"
TIOGA_URI="$(wait_for_remote_uri "${TIOGA_HOST}" "${TIOGA_CHILD_ID}" "Tioga target")"
preflight_remote_uri "${TIOGA_URI}" "Tioga target"
TARGET_TIOGA_ID="${TIOGA_CHILD_ID}"
TARGET_TIOGA_URI="${TIOGA_URI}"
TARGET_TIOGA_LABEL="tioga:${TIOGA_CHILD_ID}"
printf '  Tioga target:\n    id: %s\n    uri: %s\n' "${TIOGA_CHILD_ID}" "${TIOGA_URI}"

# --- Step 3: Allocate Corona target instance --------------------------------

printf '[3/6] Allocating Corona target instance...\n'
CORONA_HOST="corona.llnl.gov"
CORONA_CHILD_ID="$(ssh "${CORONA_HOST}" "flux submit --queue=pdebug --bank=fractale -t 10m -N1 flux start sleep inf" | tail -n 1 | tr -d '[:space:]')"
REMOTE_CHILD_IDS["${CORONA_HOST}"]="${CORONA_CHILD_ID}"
wait_for_remote_running "${CORONA_HOST}" "${CORONA_CHILD_ID}" "Corona target"
CORONA_URI="$(wait_for_remote_uri "${CORONA_HOST}" "${CORONA_CHILD_ID}" "Corona target")"
preflight_remote_uri "${CORONA_URI}" "Corona target"
TARGET_CORONA_ID="${CORONA_CHILD_ID}"
TARGET_CORONA_URI="${CORONA_URI}"
TARGET_CORONA_LABEL="corona:${CORONA_CHILD_ID}"
printf '  Corona target:\n    id: %s\n    uri: %s\n' "${CORONA_CHILD_ID}" "${CORONA_URI}"

# --- Step 4: Allocate Tuolumne target instance ------------------------------

printf '[4/6] Allocating Tuolumne target instance...\n'
TUO_CHILD_ID="$(flux submit -t 10m -N1 flux start sleep inf | tail -n 1 | tr -d '[:space:]')"
LOCAL_CHILD_IDS+=("${TUO_CHILD_ID}")
wait_for_running "${TUO_CHILD_ID}" "Tuolumne target"
TUO_URI="$(wait_for_uri "${TUO_CHILD_ID}" "Tuolumne target")"
preflight_remote_uri "${TUO_URI}" "Tuolumne target"
TARGET_TUO_ID="${TUO_CHILD_ID}"
TARGET_TUO_URI="${TUO_URI}"
TARGET_TUO_LABEL="tuolumne:${TUO_CHILD_ID}"
printf '  Tuolumne target:\n    id: %s\n    uri: %s\n' "${TUO_CHILD_ID}" "${TUO_URI}"

# --- Step 5: Write config and load delegate plugin --------------------------

printf '[5/6] Writing config and loading delegate plugin...\n'
# Write the delegate config with all three target URIs
printf 'delegate = [ "%s", "%s", "%s" ]\n' \
    "${TARGET_TIOGA_URI}" "${TARGET_CORONA_URI}" "${TARGET_TUO_URI}" > "${CONFIG_FILE}"
cat "${CONFIG_FILE}"

# Load the delegate plugin into the source instance with the config
flux proxy "${SOURCE_INSTANCE}" bash <<EOF
set -euo pipefail
if flux jobtap list | grep -q 'delegate.so'; then
    flux jobtap remove delegate.so
fi
flux jobtap load "${PLUGIN_PATH}" config="${CONFIG_FILE}" >/dev/null
EOF

sleep 5

# --- Step 6: Submit trace jobs with their respective policies ---------------

printf '[6/6] Submitting %d trace jobs...\n' "${#TRACE_POLICIES[@]}"

for ((j = 0; j < ${#TRACE_POLICIES[@]}; j++)); do
    policy="${TRACE_POLICIES[$j]}"
    dep_str="delegate:${policy}"
    printf '  [%d] policy=%s\n' "${j}" "${policy}"

    if submit_output="$(flux proxy "${SOURCE_INSTANCE}" flux submit --dependency="${dep_str}" -N1 -n1 hostname 2>&1)"; then
        job_id="$(printf '%s\n' "${submit_output}" | tail -n 1 | tr -d '[:space:]')"
        SUBMITTED_JOB_IDS+=("${job_id}")

        # Wait for the delegation event to appear
        flux proxy "${SOURCE_INSTANCE}" flux job wait-event --timeout=60 "${job_id}" "delegate::submit" >/dev/null 2>&1 || true

        EVENTLOG="$(flux proxy "${SOURCE_INSTANCE}" flux job eventlog "${job_id}" 2>/dev/null || true)"
        DELEGATED_ID="$(extract_delegated_job_id "${EVENTLOG}")"
        F58_ID="$(flux job id --to=f58 "${DELEGATED_ID}" 2>/dev/null || echo "${DELEGATED_ID}")"

        # Locate which target received this job
        found_target=-1
        for tidx in 0 1 2; do
            case "${tidx}" in
                0) target_uri="${TARGET_TIOGA_URI}" ;;
                1) target_uri="${TARGET_CORONA_URI}" ;;
                2) target_uri="${TARGET_TUO_URI}" ;;
            esac
            if timeout 15 flux proxy "${target_uri}" flux job eventlog "${F58_ID}" >/dev/null 2>&1; then
                found_target="${tidx}"
                break
            fi
        done

        if [[ "${found_target}" -ge 0 ]]; then
            case "${found_target}" in
                0) target_label="${TARGET_TIOGA_LABEL}" ;;
                1) target_label="${TARGET_CORONA_LABEL}" ;;
                2) target_label="${TARGET_TUO_LABEL}" ;;
            esac
            printf '    -> %s (delegated id: %s)\n' "${target_label}" "${F58_ID}"
        else
            printf '    -> delegated id %s (not located on any target)\n' "${F58_ID}"
        fi
    else
        printf 'FAIL: Submit failed for trace job %d: %s\n' "${j}" "${submit_output}" >&2
        exit 1
    fi
done
