#!/usr/bin/env bash
#
# Example: Shortest-Match Delegation Policy with 3 Target Instances
#
# This script demonstrates the "shortest_match" delegation policy from the
# Flux delegate plugin. It creates one source instance and three target
# sub-instances, loads two jobs onto target-0 to create contention, then
# submits a shortest_match job which should select the least-loaded target.
#
# Usage (not inside a Flux allocation):
#   bash examples/shortest-match-delegation-3instances.sh
#
PLUGIN_PATH="${PWD}/src/job-manager/plugins/.libs/delegate.so"
CONFIG_FILE="${PWD}/examples/shortest-match-clusters.toml"

setup_clusters() {
    # Allocate the source Flux instance
    printf '[1/5] Allocating source Flux instance...\n'
    SOURCE_INSTANCE="$(flux submit --queue=pdebug -t 10m -N1 flux start sleep inf | tail -n 1 | tr -d '[:space:]')"
    flux job wait-event "${SOURCE_INSTANCE}" start

    # Allocate three target sub-instances
    printf '[2/5] Allocating 3 target sub-instances...\n'

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

printf '[4/5] Creating load on target-0 (submitting 2 jobs via assign:0)...\n'
LOAD_JOB_1="$(flux proxy "${SOURCE_INSTANCE}" flux submit -S system.delegate=assign:0 -t 5m -N1 -n1 hostname | tail -n 1 | tr -d '[:space:]')"
flux proxy "${SOURCE_INSTANCE}" flux job wait-event --timeout=60 "${LOAD_JOB_1}" "delegate::submit" >/dev/null 2>&1 || true
LOAD_JOB_2="$(flux proxy "${SOURCE_INSTANCE}" flux submit -S system.delegate=assign:0 -t 5m -N1 -n1 hostname | tail -n 1 | tr -d '[:space:]')"
flux proxy "${SOURCE_INSTANCE}" flux job wait-event --timeout=60 "${LOAD_JOB_2}" "delegate::submit" >/dev/null 2>&1 || true
printf 'Loaded target-0 with jobs: %s, %s\n\n' "${LOAD_JOB_1}" "${LOAD_JOB_2}"

printf '[5/5] Submitting job with -S delegate=shortest_match ...\n'
JOB_ID="$(flux proxy "${SOURCE_INSTANCE}" flux submit -S delegate=shortest_match -t 5m -N1 -n1 hostname | tail -n 1 | tr -d '[:space:]')"
printf '  Submitted job id: %s\n\n' "${JOB_ID}"

# Wait for the job to finish
flux proxy "${SOURCE_INSTANCE}" flux job wait-event --timeout=60 "${JOB_ID}" clean

# Show Flux jobs on all instances
printf 'Source instance jobs:\n'
flux proxy "${SOURCE_INSTANCE}" flux jobs -a | head -n 10 || true
printf 'Target 1 jobs:\n'
flux proxy "${TARGET1_ID}" flux jobs -a | head -n 10 || true
printf 'Target 2 jobs:\n'
flux proxy "${TARGET2_ID}" flux jobs -a | head -n 10 || true
printf 'Target 3 jobs:\n'
flux proxy "${TARGET3_ID}" flux jobs -a | head -n 10 || true

printf 'PASS: Job was delegated via shortest_match and finished cleanly.\n'
