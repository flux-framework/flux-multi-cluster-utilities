#!/usr/bin/env bash
#
# Example: Multi-System Job Delegation with Tuolumne, Corona, and Tioga
#
# This script demonstrates real multi-system Flux job delegation. It:
#   1. Sets up a "trace" — a list of incoming jobs, each with its own
#      requested node count and delegation policy (random, shortest_match,
#      or least_pending).
#   2. Allocates Flux target sub-instances on different physical systems
#      using a layout configuration file.
#   3. Submits each trace job through the source instance, which delegates
#      it to one of the target instances according to the specified policy.
#   4. Logs per-job results and produces a summary tally.
#
# Usage (from within a Tuolumne Flux allocation):
#   bash job-delegation.sh [layout-file]
#
# Default layout uses examples/multisystem-layout-2.conf (Tuolumne + Corona + Tioga).
#
# Steps:
#   1. Load layout configuration from file to determine target systems, queues, and node counts.
#   2. Allocate the source Flux instance on the local system.
#   3. Allocate target sub-instances on each system defined in the layout (local or via SSH).
#   4. Write a TOML config with target URIs and load the delegate plugin into the source instance.
#   5. Submit each trace job through the source instance with the appropriate delegation policy.
#   6. Wait for each job to complete, extract delegation events, and identify which target received it.
#   7. Print a summary report showing per-job results and per-target hit counts.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PREFIX="$(grep '^prefix = ' "${REPO_ROOT}/Makefile" | awk '{print $3}' || true)"
PREFIX="${PREFIX:-${REPO_ROOT}/install}"
PLUGIN_PATH="${PREFIX}/lib/flux/job-manager/plugins/delegate.so"
CONFIG_PATH="${SCRIPT_DIR}/multisystem-clusters.toml"
DEFAULT_LAYOUT_FILE="${SCRIPT_DIR}/multisystem-layout.conf"

# --- Environment-configurable defaults ----------------------------------------
SOURCE_NODES="${SOURCE_NODES:-1}"
BANK="${BANK:-fractale}"
TUO_PARTITION="${TUO_PARTITION:-pdebug}"
TUO_BANK="${TUO_BANK:-${BANK}}"
CORONA_HOST="${CORONA_HOST:-corona.llnl.gov}"
CORONA_TARGET_NODES="${CORONA_TARGET_NODES:-1}"
CORONA_PARTITION="${CORONA_PARTITION:-pdebug}"
CORONA_BANK="${CORONA_BANK:-${BANK}}"
TIOGA_HOST="${TIOGA_HOST:-tioga.llnl.gov}"
TIOGA_TARGET_NODES="${TIOGA_TARGET_NODES:-1}"
TIOGA_PARTITION="${TIOGA_PARTITION:-pdebug}"
TIOGA_BANK="${TIOGA_BANK:-asccasc}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"
SETTLE_SECONDS="${SETTLE_SECONDS:-5}"
KEEP_CONFIG="${KEEP_CONFIG:-0}"
SSH_SUFFIX="${SSH_SUFFIX:-.llnl.gov}"

# --- Data structures ----------------------------------------------------------
declare -a TARGET_SYSTEM=()       # system name (tuolumne, corona, tioga)
declare -a TARGET_QUEUE=()        # queue per target
declare -a TARGET_BANK=()         # bank per target
declare -a TARGET_NODES=()        # nodes per target
declare -a TARGET_KIND=()         # "local" or "remote"
declare -a TARGET_HOST=()         # SSH host (empty for local)
declare -a TARGET_INSTANCE_IDS=() # job id of each sub-instance
declare -a TARGET_URIS=()         # remote URI for each sub-instance
declare -a TARGET_LABELS=()       # human label "<system>:<jobid>"

declare -a LOCAL_CHILD_IDS=()     # local child ids (for cleanup)
declare -A REMOTE_CHILD_IDS=()    # host -> space-separated jobids
declare -a SUBMITTED_JOB_IDS=()   # source-instance job ids

SOURCE_INSTANCE=""
CURRENT_SYSTEM="$(hostname -s 2>/dev/null | sed 's/[0-9]*$//' || echo unknown)"

# --- Trace definition ---------------------------------------------------------
# Each entry: "nodes|policy|description"
# Policies supported: random, shortest_match, least_pending
TRACE_JOBS=(
    "1|random|Simple hostname job via random selection"
    "1|random|Another hostname job via random selection"
    "1|least_pending|CPU-bound job via least_pending"
    "1|shortest_match|I/O job via shortest_match"
    "1|random|Final random job"
)

# --- Helper Functions ---------------------------------------------------------

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

system_host() {
    local system="$1"
    case "${system}" in
        "${CURRENT_SYSTEM}") printf '\n' ;;
        tuolumne) printf '%s%s\n' "${system}" "${SSH_SUFFIX}" ;;
        corona) printf '%s\n' "${CORONA_HOST}" ;;
        tioga) printf '%s\n' "${TIOGA_HOST}" ;;
        *) printf '%s%s\n' "${system}" "${SSH_SUFFIX}" ;;
    esac
}

system_bank() {
    local system="$1"
    case "${system}" in
        tuolumne) printf '%s\n' "${TUO_BANK}" ;;
        corona) printf '%s\n' "${CORONA_BANK}" ;;
        tioga) printf '%s\n' "${TIOGA_BANK}" ;;
        *) printf '%s\n' "${BANK}" ;;
    esac
}

load_layout() {
    local layout_file="$1"
    local line system rest queue counts node_count host bank

    [[ -r "${layout_file}" ]] || fail "Layout file not readable: ${layout_file}"

    # Try shell-source first (layout.conf style with TARGET_LAYOUT array)
    if source "${layout_file}" 2>/dev/null && [[ ${#TARGET_LAYOUT[@]} -gt 0 ]]; then
        : # layout_array_set
    else
        TARGET_LAYOUT=()
        while IFS= read -r line || [[ -n "${line}" ]]; do
            line="${line%%#*}"
            line="$(printf '%s' "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            [[ -z "${line}" ]] && continue
            TARGET_LAYOUT+=("${line}")
        done <"${layout_file}"
    fi

    [[ ${#TARGET_LAYOUT[@]} -gt 0 ]] || fail "Layout file contained no entries"

    for line in "${TARGET_LAYOUT[@]}"; do
        [[ "${line}" == *:*:* ]] || fail "Bad layout line: ${line}"
        system="${line%%:*}"
        rest="${line#*:}"
        queue="${rest%%:*}"
        counts="${rest#*:}"

        for node_count in ${counts}; do
            [[ "${node_count}" =~ ^[1-9][0-9]*$ ]] \
                || fail "Bad node count: ${node_count} (line: ${line})"
            TARGET_SYSTEM+=("${system}")
            TARGET_QUEUE+=("${queue}")
            TARGET_BANK+=("$(system_bank "${system}")")
            TARGET_NODES+=("${node_count}")
            if [[ "${system}" == "${CURRENT_SYSTEM}" ]]; then
                TARGET_KIND+=("local")
                TARGET_HOST+=("")
            else
                TARGET_KIND+=("remote")
                host="$(system_host "${system}")"
                [[ -n "${host}" ]] || fail "No SSH host for: ${system}"
                TARGET_HOST+=("${host}")
            fi
        done
    done
}

cleanup() {
    set +e
    local host ids
    if [[ ${#SUBMITTED_JOB_IDS[@]} -gt 0 && -n "${SOURCE_INSTANCE}" ]]; then
        timeout 30 flux proxy "${SOURCE_INSTANCE}" flux cancel "${SUBMITTED_JOB_IDS[@]}" >/dev/null 2>&1 || true
    fi
    if [[ ${#LOCAL_CHILD_IDS[@]} -gt 0 ]]; then
        flux cancel "${LOCAL_CHILD_IDS[@]}" >/dev/null 2>&1 || true
    fi
    for host in "${!REMOTE_CHILD_IDS[@]}"; do
        ids="${REMOTE_CHILD_IDS[$host]}"
        [[ -n "${ids}" ]] || continue
        ssh "${host}" "flux cancel ${ids}" >/dev/null 2>&1 || true
    done
    if [[ "${KEEP_CONFIG}" != "1" ]]; then
        rm -f "${CONFIG_PATH}"
    fi
}
trap cleanup EXIT

build_local_submit_flags() {
    local queue="$1" bank="$2"
    if flux queue list 2>/dev/null | awk 'NR>1 {found=1} END {exit !found}'; then
        printf -- '--queue=%s --bank=%s' "${queue}" "${bank}"
    fi
}

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

wait_for_remote_running() {
    local host="$1" instance_id="$2" label="$3" remaining="${WAIT_TIMEOUT}"
    while (( remaining > 0 )); do
        if ssh "${host}" "flux jobs --format='{status}' ${instance_id}" 2>/dev/null | grep -q 'RUN'; then
            return 0
        fi
        sleep 1; remaining=$((remaining - 1))
    done
    fail "Timed out waiting for ${label} (${instance_id}) on ${host}"
}

wait_for_uri() {
    local instance_id="$1" label="$2" remaining="${WAIT_TIMEOUT}" remote_uri=""
    while (( remaining > 0 )); do
        remote_uri="$(flux uri --remote "jobid:${instance_id}" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ -n "${remote_uri}" ]]; then printf '%s\n' "${remote_uri}"; return 0; fi
        sleep 1; remaining=$((remaining - 1))
    done
    fail "Timed out waiting for URI of ${label} (${instance_id})"
}

wait_for_remote_uri() {
    local host="$1" instance_id="$2" label="$3" remaining="${WAIT_TIMEOUT}" remote_uri=""
    while (( remaining > 0 )); do
        remote_uri="$(ssh "${host}" "flux uri --remote jobid:${instance_id}" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ -n "${remote_uri}" ]]; then printf '%s\n' "${remote_uri}"; return 0; fi
        sleep 1; remaining=$((remaining - 1))
    done
    fail "Timed out waiting for remote URI of ${label} (${instance_id}) on ${host}"
}

preflight_remote_uri() {
    local remote_uri="$1" label="$2" resolved_uri=""
    resolved_uri="$(flux proxy "${SOURCE_INSTANCE}" env FLUX_URI="${remote_uri}" flux getattr local-uri 2>&1 | tr -d '[:space:]' || true)"
    if [[ -z "${resolved_uri}" ]]; then
        fail "Source cannot open target URI for ${label}: ${remote_uri}"
    fi
}

extract_delegated_job_id() {
    printf '%s\n' "$1" | sed -nE '/delegate::submit/ s/.*jobid["=:[:space:]]+("?)([^",}[:space:]]+).*/\2/p' | head -n 1
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

LAYOUT_FILE="${1:-${DEFAULT_LAYOUT_FILE}}"

cd "${REPO_ROOT}"
[[ -f "${PLUGIN_PATH}" ]] || fail "Plugin not found: ${PLUGIN_PATH}"

printf '=============================================================\n'
printf '  Multi-System Job Delegation Example\n'
printf '  Source system: %s\n' "${CURRENT_SYSTEM}"
printf '=============================================================\n\n'

# Step 1: Load layout configuration
printf '[Step 1] Loading layout from %s ...\n' "${LAYOUT_FILE}"
load_layout "${LAYOUT_FILE}"
printf '  Loaded %d target sub-instance(s):\n' "${#TARGET_NODES[@]}"
for index in "${!TARGET_NODES[@]}"; do
    printf '    [%d] %-8s queue=%-8s nodes=%s kind=%-6s bank=%s\n' \
        "${index}" "${TARGET_SYSTEM[$index]}" "${TARGET_QUEUE[$index]}" \
        "${TARGET_NODES[$index]}" "${TARGET_KIND[$index]}" "${TARGET_BANK[$index]}"
done
printf '\n'

# Step 2: Allocate source (top-level) instance
read -r -a SOURCE_FLAGS <<<"$(build_local_submit_flags "${TUO_PARTITION}" "${TUO_BANK}")"
printf '[Step 2] Allocating source instance (%d nodes)...\n' "${SOURCE_NODES}"
SOURCE_INSTANCE="$(flux submit "${SOURCE_FLAGS[@]}" -N"${SOURCE_NODES}" flux start sleep inf | tail -n 1 | tr -d '[:space:]')"
LOCAL_CHILD_IDS+=("${SOURCE_INSTANCE}")
wait_for_running "${SOURCE_INSTANCE}" "source instance"
printf '  Source instance id: %s\n\n' "${SOURCE_INSTANCE}"

# Step 3: Allocate target sub-instances per layout
printf '[Step 3] Allocating target sub-instances...\n'
for index in "${!TARGET_NODES[@]}"; do
    nodes="${TARGET_NODES[$index]}"
    queue="${TARGET_QUEUE[$index]}"
    bank="${TARGET_BANK[$index]}"
    system="${TARGET_SYSTEM[$index]}"
    kind="${TARGET_KIND[$index]}"
    host="${TARGET_HOST[$index]}"
    label_prefix="target[${index}] ${system}:${queue}:${bank}:${nodes}"

    if [[ "${kind}" == "local" ]]; then
        read -r -a local_flags <<<"$(build_local_submit_flags "${queue}" "${bank}")"
        child_id="$(flux submit "${local_flags[@]}" -N"${nodes}" flux start sleep inf | tail -n 1 | tr -d '[:space:]')"
        LOCAL_CHILD_IDS+=("${child_id}")
        wait_for_running "${child_id}" "${label_prefix}"
        remote_uri="$(wait_for_uri "${child_id}" "${label_prefix}")"
    else
        child_id="$(ssh "${host}" "flux submit --queue=${queue} --bank=${bank} -N${nodes} flux start sleep inf" | tail -n 1 | tr -d '[:space:]')"
        REMOTE_CHILD_IDS["${host}"]="${REMOTE_CHILD_IDS[${host}]:-} ${child_id}"
        wait_for_remote_running "${host}" "${child_id}" "${label_prefix}"
        remote_uri="$(wait_for_remote_uri "${host}" "${child_id}" "${label_prefix}")"
    fi
    preflight_remote_uri "${remote_uri}" "${label_prefix}"
    TARGET_INSTANCE_IDS+=("${child_id}")
    TARGET_URIS+=("${remote_uri}")
    TARGET_LABELS+=("${system}:${child_id}")
    printf '  %s -> job id: %s, uri: %s\n' "${label_prefix}" "${child_id}" "${remote_uri}"
done
printf '\n'

# Step 4: Write TOML config and load plugin
printf '[Step 4] Writing config and loading delegate plugin...\n'
write_config
cat "${CONFIG_PATH}"
load_plugin
sleep "${SETTLE_SECONDS}"
printf '\n'

# Step 5: Submit trace jobs with their respective policies
printf '[Step 5] Submitting %d trace jobs...\n' "${#TRACE_JOBS[@]}"
declare -A TARGET_HIT_COUNT=()
declare -a JOB_RESULTS=()

for ((j = 0; j < ${#TRACE_JOBS[@]}; j++)); do
    IFS='|' read -r req_nodes policy description <<<"${TRACE_JOBS[$j]}"
    dep_str="delegate:${policy}"
    printf '  [%d] nodes=%s policy=%-15s %s\n' "${j}" "${req_nodes}" "${policy}" "${description}"

    if submit_output="$(flux proxy "${SOURCE_INSTANCE}" flux submit --dependency="${dep_str}" -N"${req_nodes}" -n1 hostname 2>&1)"; then
        job_id="$(printf '%s\n' "${submit_output}" | tail -n 1 | tr -d '[:space:]')"
        SUBMITTED_JOB_IDS+=("${job_id}")

        # Wait for the delegation event to appear
        flux proxy "${SOURCE_INSTANCE}" flux job wait-event --timeout=60 "${job_id}" "delegate::submit" >/dev/null 2>&1 || true

        EVENTLOG="$(flux proxy "${SOURCE_INSTANCE}" flux job eventlog "${job_id}" 2>/dev/null || true)"
        DELEGATED_ID="$(extract_delegated_job_id "${EVENTLOG}")"
        F58_ID="$(flux job id --to=f58 "${DELEGATED_ID}" 2>/dev/null || echo "${DELEGATED_ID}")"

        # Locate which target received this job
        found_target=-1
        for tidx in "${!TARGET_URIS[@]}"; do
            if timeout 15 flux proxy "${TARGET_URIS[$tidx]}" flux job eventlog "${F58_ID}" >/dev/null 2>&1; then
                found_target="${tidx}"
                break
            fi
        done

        if [[ "${found_target}" -ge 0 ]]; then
            TARGET_HIT_COUNT["${found_target}"]=$(( ${TARGET_HIT_COUNT["${found_target}"]:-0} + 1 ))
            JOB_RESULTS+=("Job ${job_id} (${policy}) -> target[${found_target}] ${TARGET_LABELS[$found_target]} (delegated id: ${F58_ID})")
        else
            JOB_RESULTS+=("Job ${job_id} (${policy}) -> delegated id ${F58_ID} (not located on any target)")
        fi
    else
        fail "Submit failed for trace job ${j}: ${submit_output}"
    fi
done
printf '\n'

# Step 6: Summary report
printf '=============================================================\n'
printf '  Delegation Results Summary\n'
printf '=============================================================\n\n'

printf 'Per-job results:\n'
for line in "${JOB_RESULTS[@]}"; do
    printf '  %s\n' "${line}"
done

printf '\nPer-target tally:\n'
total_hits=0
for index in "${!TARGET_LABELS[@]}"; do
    hits="${TARGET_HIT_COUNT[$index]:-0}"
    total_hits=$((total_hits + hits))
    printf '  [%d] %-40s nodes=%s queue=%s hits=%d\n' \
        "${index}" "${TARGET_LABELS[$index]}" \
        "${TARGET_NODES[$index]}" "${TARGET_QUEUE[$index]}" "${hits}"
done
printf '  Total accounted: %d / %d\n' "${total_hits}" "${#TRACE_JOBS[@]}"

if (( total_hits == ${#TRACE_JOBS[@]} )); then
    printf '\nPASS: All %d trace jobs were successfully delegated.\n' "${#TRACE_JOBS[@]}"
else
    printf '\nNOTE: %d of %d trace jobs confirmed on targets.\n' "${total_hits}" "${#TRACE_JOBS[@]}"
fi
