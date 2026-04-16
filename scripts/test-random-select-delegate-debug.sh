#!/usr/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PREFIX="$(grep '^prefix = ' "${REPO_ROOT}/Makefile" | awk '{print $3}' || true)"
PREFIX="${PREFIX:-${REPO_ROOT}/install}"
PLUGIN_PATH="${PREFIX}/lib/flux/job-manager/plugins/delegate.so"
CONFIG_PATH="${SCRIPT_DIR}/random-selection-clusters-debug.toml"
JOB_ROW_FORMAT='{id} {status} {name} {nnodes} {ntasks} {nodelist}'

SOURCE_NODES="${SOURCE_NODES:-1}"
TARGET_NODES="${TARGET_NODES:-1}"
NUM_TARGETS="${NUM_TARGETS:-2}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"
SETTLE_SECONDS="${SETTLE_SECONDS:-5}"
KEEP_CONFIG="${KEEP_CONFIG:-0}"

declare -a CHILD_IDS=()
declare -a TARGET_URIS=()
declare -a TARGET_INSTANCE_IDS=()
SOURCE_INSTANCE=""
JOB_ID=""

fail()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}



### ---- cleanup resources
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

##------ check status of "running" jobs. Later will be replaced by wait on a real job?

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


# ----------------------------------------------------------
# Setup remote URI and validate 
preflight_remote_uri()
{
    local remote_uri="$1"
    local label="$2"
    local preflight_output=""
    local resolved_uri=""

    preflight_output="$(flux proxy "${SOURCE_INSTANCE}" env FLUX_URI="${remote_uri}" flux getattr local-uri 2>&1 || true)"
    resolved_uri="$(printf '%s' "${preflight_output}" | tr -d '[:space:]')"

    if [[ -z "${resolved_uri}" ]]; then
        fail "Source instance cannot open target remote URI for ${label}: ${remote_uri}"
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

convert_job_id_to_f58()
{
    local delegated_job_id="$1"

    [[ -n "${delegated_job_id}" ]] || return 0
    flux job id --to=f58 "${delegated_job_id}" 2>/dev/null || true
}

query_target_job_row()
{
    local target_instance_id="$1"
    local lookup_id="$2"

    [[ -n "${lookup_id}" ]] || return 1
    flux proxy "${target_instance_id}" \
        flux jobs -a --format="${JOB_ROW_FORMAT}" "${lookup_id}" 2>/dev/null || true
}

query_target_eventlog()
{
    local target_instance_id="$1"
    local lookup_id="$2"

    [[ -n "${lookup_id}" ]] || return 1
    flux proxy "${target_instance_id}" flux job eventlog "${lookup_id}" 2>/dev/null || true
}

extract_selected_cluster_uri()
{
    printf '%s\n' "$1" | sed -nE 's/.*Selected cluster [0-9]+: ([^[:space:]]+).*/\1/p' | tail -n 1
}

map_target_uri_to_instance_id()
{
    local target_uri="$1"
    local position

    for position in "${!TARGET_URIS[@]}"; do
        if [[ "${TARGET_URIS[$position]}" == "${target_uri}" ]]; then
            printf '%s\n' "${TARGET_INSTANCE_IDS[$position]}"
            return 0
        fi
    done

    return 1
}

find_target_job_row()
{
    local delegated_job_id_raw="$1"
    local delegated_job_id_f58="$2"
    local target_instance_id=""
    local target_job_row=""
    local lookup_id=""

    for target_instance_id in "${TARGET_INSTANCE_IDS[@]}"; do
        for lookup_id in "${delegated_job_id_raw}" "${delegated_job_id_f58}"; do
            [[ -n "${lookup_id}" ]] || continue
            target_job_row="$(query_target_job_row "${target_instance_id}" "${lookup_id}")"
            if [[ -n "${target_job_row}" ]]; then
                printf '%s|%s|%s\n' "${target_instance_id}" "${lookup_id}" "${target_job_row}"
                return 0
            fi
        done
    done

    return 1
}

find_target_eventlog_info()
{
    local delegated_job_id_raw="$1"
    local delegated_job_id_f58="$2"
    local target_instance_id=""
    local lookup_id=""

    for target_instance_id in "${TARGET_INSTANCE_IDS[@]}"; do
        for lookup_id in "${delegated_job_id_f58}" "${delegated_job_id_raw}"; do
            [[ -n "${lookup_id}" ]] || continue
            if [[ -n "$(query_target_eventlog "${target_instance_id}" "${lookup_id}")" ]]; then
                printf '%s|%s\n' "${target_instance_id}" "${lookup_id}"
                return 0
            fi
        done
    done

    return 1
}

wait_for_target_job_row()
{
    local delegated_job_id_raw="$1"
    local delegated_job_id_f58="$2"
    local remaining="${WAIT_TIMEOUT}"
    local target_job_info=""

    while (( remaining > 0 )); do
        target_job_info="$(find_target_job_row "${delegated_job_id_raw}" "${delegated_job_id_f58}" || true)"
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
    local position

    {
        printf 'clusters = [\n'
        for position in "${!TARGET_URIS[@]}"; do
            if [[ ${position} -gt 0 ]]; then
                printf ',\n'
            fi
            printf '  "%s"' "${TARGET_URIS[$position]}"
        done
        printf '\n]\n'
    } >"${CONFIG_PATH}"
}

#---- run steps to load delegate (reload if previously loaded)
load_plugin()
{
    flux proxy "${SOURCE_INSTANCE}" bash <<EOF
if flux jobtap list | grep -q 'delegate.so'; then
    flux jobtap remove delegate.so
fi
flux jobtap load "${PLUGIN_PATH}" config="${CONFIG_PATH}" >/dev/null
EOF
}

print_target_debug()
{
    local delegated_job_id_raw="$1"
    local delegated_job_id_f58="$2"
    local source_dmesg_tail="$3"
    local target_instance_id=""
    local target_jobs=""
    local raw_row=""
    local f58_row=""
    local f58_eventlog=""

    printf 'DEBUG: source eventlog delegated raw id: %s\n' "${delegated_job_id_raw:-not found}"
    printf 'DEBUG: source eventlog delegated f58 id: %s\n' "${delegated_job_id_f58:-not found}"
    printf 'DEBUG: source job table row: %s\n' "$(flux proxy "${SOURCE_INSTANCE}" flux jobs -a --format="${JOB_ROW_FORMAT}" "${JOB_ID}" 2>/dev/null || printf not\ found)"
    printf 'DEBUG: source jobtap list:\n'
    flux proxy "${SOURCE_INSTANCE}" flux jobtap list || true
    printf 'DEBUG: source dmesg tail:\n'
    printf '%s\n' "${source_dmesg_tail}"

    for target_instance_id in "${TARGET_INSTANCE_IDS[@]}"; do
        printf 'DEBUG: target instance id: %s\n' "${target_instance_id}"
        target_jobs="$(flux proxy "${target_instance_id}" flux jobs -a --format="${JOB_ROW_FORMAT}" 2>/dev/null || true)"
        raw_row="$(query_target_job_row "${target_instance_id}" "${delegated_job_id_raw}")"
        f58_row="$(query_target_job_row "${target_instance_id}" "${delegated_job_id_f58}")"
        f58_eventlog="$(query_target_eventlog "${target_instance_id}" "${delegated_job_id_f58}")"
        printf 'DEBUG: target jobs:\n'
        if [[ -n "${target_jobs}" ]]; then
            printf '%s\n' "${target_jobs}"
        else
            printf '(none)\n'
        fi
        printf 'DEBUG: raw-id probe result: %s\n' "${raw_row:-not found}"
        printf 'DEBUG: f58-id probe result: %s\n' "${f58_row:-not found}"
        printf 'DEBUG: f58 eventlog probe: %s\n' "$(if [[ -n "${f58_eventlog}" ]]; then printf found; else printf not\ found; fi)"
    done
}

cd "${REPO_ROOT}"
[[ -f "${PLUGIN_PATH}" ]] || fail "Plugin not found: ${PLUGIN_PATH}"

printf 'DEBUG: top-level broker local-uri: %s\n' "$(flux getattr local-uri 2>/dev/null | tr -d '[:space:]' || printf unknown)"
printf 'DEBUG: top-level broker size: %s\n' "$(flux getattr size 2>/dev/null | tr -d '[:space:]' || printf unknown)"
printf 'DEBUG: top-level resource view:\n'
flux resource list || true

#-----------------------------------------------------------------------
#  setup top instance

SOURCE_INSTANCE="$(flux submit -N"${SOURCE_NODES}" flux start sleep inf | tail -n 1 | tr -d '[:space:]')"
CHILD_IDS+=("${SOURCE_INSTANCE}")
wait_for_running "${SOURCE_INSTANCE}" "source instance"
printf 'source instance id: %s\n' "${SOURCE_INSTANCE}"


#-----------------------------------------------------------------------
# Initial setup according to README -- setup cluster instances and URIs

for index in $(seq 1 "${NUM_TARGETS}"); do
    child_id="$(flux submit -N"${TARGET_NODES}" flux start sleep inf | tail -n 1 | tr -d '[:space:]')"
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
printf 'DEBUG: config path: %s\n' "${CONFIG_PATH}"
printf 'DEBUG: config contents:\n'
cat "${CONFIG_PATH}"

load_plugin
printf 'DEBUG: source jobtap list after load:\n'
flux proxy "${SOURCE_INSTANCE}" flux jobtap list || true
sleep "${SETTLE_SECONDS}"

if submit_output="$(flux proxy "${SOURCE_INSTANCE}" flux submit --dependency='delegate:random' -N1 -n1 hostname 2>&1)"; then
    JOB_ID="$(printf '%s\n' "${submit_output}" | tail -n 1 | tr -d '[:space:]')"
else
    printf 'DEBUG: submit stdout/stderr:\n%s\n' "${submit_output}" >&2
    fail 'Delegated submit failed'
fi

printf 'submitted job id: %s\n' "${JOB_ID}"

wait_for_clean "${JOB_ID}"
EVENTLOG="$(flux proxy "${SOURCE_INSTANCE}" flux job eventlog "${JOB_ID}")"
SOURCE_DMESG_TAIL="$(flux proxy "${SOURCE_INSTANCE}" flux dmesg | tail -n 40 || true)"
DELEGATION_LINES="$(printf '%s\n' "${EVENTLOG}" | grep -E 'delegate::|Delegation' || true)"
DELEGATED_JOB_ID_RAW="$(extract_delegated_job_id "${EVENTLOG}")"
DELEGATED_JOB_ID_F58="$(convert_job_id_to_f58 "${DELEGATED_JOB_ID_RAW}")"
SELECTED_TARGET_URI="$(extract_selected_cluster_uri "${SOURCE_DMESG_TAIL}")"
TARGET_JOB_INFO=""
TARGET_EVENTLOG_INFO=""
SELECTED_TARGET_INSTANCE_ID="$(map_target_uri_to_instance_id "${SELECTED_TARGET_URI}" || true)"
SELECTED_TARGET_INSTANCE_ID="${SELECTED_TARGET_INSTANCE_ID:-not found}"
TARGET_LOOKUP_ID="not found"
TARGET_JOB_ROW="not found"
TARGET_EVENTLOG_FOUND="not found"

[[ -n "${DELEGATION_LINES}" ]] || fail "No delegation events found for ${JOB_ID}"
printf '%s\n' "${DELEGATION_LINES}"

print_target_debug "${DELEGATED_JOB_ID_RAW}" "${DELEGATED_JOB_ID_F58}" "${SOURCE_DMESG_TAIL}"

if [[ -n "${DELEGATED_JOB_ID_RAW}" || -n "${DELEGATED_JOB_ID_F58}" ]]; then
    TARGET_JOB_INFO="$(find_target_job_row "${DELEGATED_JOB_ID_RAW}" "${DELEGATED_JOB_ID_F58}" || true)"
    if [[ -n "${TARGET_JOB_INFO}" ]]; then
        IFS='|' read -r SELECTED_TARGET_INSTANCE_ID TARGET_LOOKUP_ID TARGET_JOB_ROW <<<"${TARGET_JOB_INFO}"
    else
        TARGET_EVENTLOG_INFO="$(find_target_eventlog_info "${DELEGATED_JOB_ID_RAW}" "${DELEGATED_JOB_ID_F58}" || true)"
        if [[ -n "${TARGET_EVENTLOG_INFO}" ]]; then
            IFS='|' read -r SELECTED_TARGET_INSTANCE_ID TARGET_LOOKUP_ID <<<"${TARGET_EVENTLOG_INFO}"
            TARGET_JOB_ROW="eventlog-only confirmation"
            TARGET_EVENTLOG_FOUND="found"
        else
            TARGET_JOB_INFO="$(wait_for_target_job_row "${DELEGATED_JOB_ID_RAW}" "${DELEGATED_JOB_ID_F58}" || true)"
            if [[ -n "${TARGET_JOB_INFO}" ]]; then
                IFS='|' read -r SELECTED_TARGET_INSTANCE_ID TARGET_LOOKUP_ID TARGET_JOB_ROW <<<"${TARGET_JOB_INFO}"
            fi
        fi
    fi
    if [[ "${TARGET_EVENTLOG_FOUND}" != "found" && "${SELECTED_TARGET_INSTANCE_ID}" != "not found" ]]; then
        for lookup_id in "${DELEGATED_JOB_ID_F58}" "${DELEGATED_JOB_ID_RAW}"; do
            [[ -n "${lookup_id}" ]] || continue
            if [[ -n "$(query_target_eventlog "${SELECTED_TARGET_INSTANCE_ID}" "${lookup_id}")" ]]; then
                TARGET_EVENTLOG_FOUND="found"
                break
            fi
        done
    fi
    if [[ "${TARGET_EVENTLOG_FOUND}" == "found" && "${TARGET_JOB_ROW}" == "not found" ]]; then
        TARGET_JOB_ROW="eventlog-only confirmation"
    fi
    if [[ "${TARGET_LOOKUP_ID}" == "not found" && -n "${DELEGATED_JOB_ID_F58}" ]]; then
        TARGET_LOOKUP_ID="${DELEGATED_JOB_ID_F58}"
    elif [[ "${TARGET_LOOKUP_ID}" == "not found" && -n "${DELEGATED_JOB_ID_RAW}" ]]; then
        TARGET_LOOKUP_ID="${DELEGATED_JOB_ID_RAW}"
    fi
    printf 'Delegated remote job id (raw): %s\n' "${DELEGATED_JOB_ID_RAW:-not found}"
    printf 'Delegated remote job id (f58): %s\n' "${DELEGATED_JOB_ID_F58:-not found}"
else
    printf 'Delegated remote job id (raw): not found\n'
    printf 'Delegated remote job id (f58): not found\n'
fi

printf 'Selected target remote uri: %s\n' "${SELECTED_TARGET_URI:-not found}"
printf 'Selected target instance id: %s\n' "${SELECTED_TARGET_INSTANCE_ID}"
printf 'Target lookup id: %s\n' "${TARGET_LOOKUP_ID}"
printf 'Target job row: %s\n' "${TARGET_JOB_ROW}"
printf 'Target eventlog probe: %s\n' "${TARGET_EVENTLOG_FOUND}"

if printf '%s\n' "${EVENTLOG}" | grep -q 'clean$'; then
    printf 'PASS: job delegated and finished cleanly\n'
else
    fail "Job ${JOB_ID} did not finish cleanly"
fi
