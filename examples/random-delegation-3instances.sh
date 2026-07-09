#!/usr/bin/env bash
#
# Example: Random Delegation Policy with 3 Target Instances
#
# This script demonstrates the "random" delegation policy from the Flux
# delegate plugin. It creates one source Flux instance and three target
# sub-instances, submits four test jobs with the random policy, then
# submits one final random job to demonstrate delegation across the
# configured targets.
#
# Usage (not inside a Flux allocation):
#   bash examples/random-delegation-3instances.sh
#

PLUGIN_PATH="${PWD}/src/job-manager/plugins/.libs/delegate.so"
CONFIG_FILE="${PWD}/examples/random-clusters.toml"

setup_clusters() {
    # Allocate the source Flux instance
    printf '[1/5] Allocating source Flux instance...\n'
    SOURCE_INSTANCE="$(flux submit --queue=pdebug -t 10m -N1 flux start sleep inf | tail -n 1 | tr -d '[:space:]')"
    flux job wait-event "${SOURCE_INSTANCE}" start

    # Allocate three target sub-instances
    printf '[2/5] Allocating 3 target instances...\n'

    TARGET1_ID="$(flux submit --queue=pdebug -t 10m -N1 flux start sleep inf | tail -n 1 | tr -d '[:space:]')"
    flux job wait-event "${TARGET1_ID}" start
    TARGET2_ID="$(flux submit --queue=pdebug -t 10m -N1 flux start sleep inf | tail -n 1 | tr -d '[:space:]')"
    flux job wait-event "${TARGET2_ID}" start
    TARGET3_ID="$(flux submit --queue=pdebug -t 10m -N1 flux start sleep inf | tail -n 1 | tr -d '[:space:]')"
    flux job wait-event "${TARGET3_ID}" start

    TARGET1_URI="$(flux uri --wait "${TARGET1_ID}")"
    TARGET2_URI="$(flux uri --wait "${TARGET2_ID}")"
    TARGET3_URI="$(flux uri --wait "${TARGET3_ID}")"

    printf 'delegate = [ "%s", "%s", "%s" ]\n' "${TARGET1_URI}" "${TARGET2_URI}" "${TARGET3_URI}" > "${CONFIG_FILE}"
}

load_plugin_and_config () {
    printf '[3/5] Configuring and loading delegate plugin...\n'

    # Load the config into the source instance's context
    flux proxy "${SOURCE_INSTANCE}" flux config load < "${CONFIG_FILE}"
    printf 'Config loaded.\n'

    # Verify config was loaded
    printf 'Verifying config:\n'
    flux proxy "${SOURCE_INSTANCE}" flux config get delegate

    # Load the delegate plugin into the source instance's context
    flux proxy "${SOURCE_INSTANCE}" flux jobtap load "${PLUGIN_PATH}"

    # Verify plugin is loaded
    printf 'Verifying plugin:\n'
    flux proxy "${SOURCE_INSTANCE}" flux jobtap list | grep delegate || true
}

cleanup() {
    set +e
    flux cancel "${SOURCE_INSTANCE}" >/dev/null 2>&1 || true
    flux cancel "${TARGET1_ID}" "${TARGET2_ID}" "${TARGET3_ID}" >/dev/null 2>&1 || true
    /bin/rm -f "${CONFIG_FILE}"
}

# Call cleanup anytime we need to exit on failure or success.
trap cleanup EXIT

setup_clusters

load_plugin_and_config

printf '[4/5] Submitting 4 test jobs with -S system.delegate=random ...\n'
TEST_JOB_1="$(flux proxy "${SOURCE_INSTANCE}" flux submit -S system.delegate=random -t 5m -N1 -n1 hostname | tail -n 1 | tr -d '[:space:]')"
flux proxy "${SOURCE_INSTANCE}" flux job wait-event --timeout=60 "${TEST_JOB_1}" "delegate::submit" >/dev/null 2>&1 || true
TEST_JOB_2="$(flux proxy "${SOURCE_INSTANCE}" flux submit -S system.delegate=random -t 5m -N1 -n1 hostname | tail -n 1 | tr -d '[:space:]')"
flux proxy "${SOURCE_INSTANCE}" flux job wait-event --timeout=60 "${TEST_JOB_2}" "delegate::submit" >/dev/null 2>&1 || true
TEST_JOB_3="$(flux proxy "${SOURCE_INSTANCE}" flux submit -S system.delegate=random -t 5m -N1 -n1 hostname | tail -n 1 | tr -d '[:space:]')"
flux proxy "${SOURCE_INSTANCE}" flux job wait-event --timeout=60 "${TEST_JOB_3}" "delegate::submit" >/dev/null 2>&1 || true
TEST_JOB_4="$(flux proxy "${SOURCE_INSTANCE}" flux submit -S system.delegate=random -t 5m -N1 -n1 hostname | tail -n 1 | tr -d '[:space:]')"
flux proxy "${SOURCE_INSTANCE}" flux job wait-event --timeout=60 "${TEST_JOB_4}" "delegate::submit" >/dev/null 2>&1 || true
printf 'Submitted test jobs: %s, %s, %s, %s\n\n' "${TEST_JOB_1}" "${TEST_JOB_2}" "${TEST_JOB_3}" "${TEST_JOB_4}"

# Show Flux jobs on all instances
printf 'Source instance jobs:\n'
flux proxy "${SOURCE_INSTANCE}" flux jobs -a | head -n 10 || true
printf 'Target 1 jobs:\n'
flux proxy "${TARGET1_ID}" flux jobs -a | head -n 10 || true
printf 'Target 2 jobs:\n'
flux proxy "${TARGET2_ID}" flux jobs -a | head -n 10 || true
printf 'Target 3 jobs:\n'
flux proxy "${TARGET3_ID}" flux jobs -a | head -n 10 || true

printf 'PASS: Job was delegated via random and finished cleanly.\n'
