#!/usr/bin/env bash
# This script allocates 4 nodes in the pdebug partition, 
# starts a source Flux instance on 1 node and 3 target Flux instances 
# on the other 3 nodes, then demonstrates the "assign" delegation policy
# from the Flux delegate plugin by submitting a job to the source instance 
# that gets delegated to a specific target instance based on its index 
# in the delegate configuration.
#
# Run it as:
#   bash examples/assign-delegation-3instances.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLUGIN_PATH="${REPO_ROOT}/src/job-manager/plugins/.libs/delegate.so"
CONFIG_FILE="${SCRIPT_DIR}/assign-delegate-config.toml"
SOURCE_INSTANCE=""
TARGET0_ID=""
TARGET1_ID=""
TARGET2_ID=""

cleanup() {
    set +e
    [[ -n "${SOURCE_INSTANCE}" ]] && flux cancel "${SOURCE_INSTANCE}" >/dev/null 2>&1 || true
    flux cancel "${TARGET0_ID}" "${TARGET1_ID}" "${TARGET2_ID}" >/dev/null 2>&1 || true
    rm -f "${CONFIG_FILE}"
}
trap cleanup EXIT

if [[ ! -f "${PLUGIN_PATH}" ]]; then
    echo "delegate plugin not found at ${PLUGIN_PATH}" >&2
    exit 1
fi

printf '[1/5] Starting 1-node source instance on a 4-node allocation...\n'
SOURCE_INSTANCE="$(flux batch --queue=pdebug -N1 -n1 -t120s --wrap sleep inf | tail -n 1 | tr -d '[:space:]')"
flux job wait-event "${SOURCE_INSTANCE}" start

printf '[2/5] Starting three 1-node target instances...\n'
TARGET0_ID="$(flux batch --queue=pdebug -N1 -n1 -t120s --wrap sleep inf | tail -n 1 | tr -d '[:space:]')"
flux job wait-event "${TARGET0_ID}" start
TARGET1_ID="$(flux batch --queue=pdebug -N1 -n1 -t120s --wrap sleep inf | tail -n 1 | tr -d '[:space:]')"
flux job wait-event "${TARGET1_ID}" start
TARGET2_ID="$(flux batch --queue=pdebug -N1 -n1 -t120s --wrap sleep inf | tail -n 1 | tr -d '[:space:]')"
flux job wait-event "${TARGET2_ID}" start

TARGET0_URI="$(flux uri --remote "${TARGET0_ID}")"
TARGET1_URI="$(flux uri --remote "${TARGET1_ID}")"
TARGET2_URI="$(flux uri --remote "${TARGET2_ID}")"

printf '[3/5] Loading delegate configuration into the source instance...\n'
printf 'delegate = [ "%s", "%s", "%s" ]\n' "${TARGET0_URI}" "${TARGET1_URI}" "${TARGET2_URI}" > "${CONFIG_FILE}"
cat "${CONFIG_FILE}" | flux proxy "${SOURCE_INSTANCE}" flux config load
flux proxy "${SOURCE_INSTANCE}" flux jobtap load "${PLUGIN_PATH}"

printf '[4/5] Submitting with assign policy to target index 2...\n'
JOB_ID="$(flux proxy "${SOURCE_INSTANCE}" flux submit --dependency=delegate:assign:2 -t60s hostname | tail -n 1 | tr -d '[:space:]')"
flux proxy "${SOURCE_INSTANCE}" flux job wait-event --timeout=60s "${JOB_ID}" clean

DELEGATED_ID="$(flux proxy "${SOURCE_INSTANCE}" flux job eventlog "${JOB_ID}" |
	sed -nE '/delegate::submit/ s/.*jobid["=:[:space:]]+("?)([^",}[:space:]]+).*/\2/p' |
	head -n 1)"

printf '[5/5] Verifying delegated job landed on target index 2...\n'
flux proxy "${SOURCE_INSTANCE}" flux job eventlog "${JOB_ID}" | grep 'delegate::' || true
flux proxy "${TARGET2_ID}" flux jobs -a | grep -q "${DELEGATED_ID}"
printf 'PASS: assign policy delegated job %s to target[2] (%s).\n' "${JOB_ID}" "${TARGET2_ID}"
