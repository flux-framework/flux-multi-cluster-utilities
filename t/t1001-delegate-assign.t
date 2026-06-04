#!/bin/sh

test_description='Test assign delegation policy for deterministic target selection'

. $(dirname $0)/sharness.sh

test_under_flux 3

# Check if we're in test environment with flux available
if ! command -v flux >/dev/null 2>&1; then
	skip_all='flux command not found, skipping tests'
	test_done
fi

test_expect_success 'delegate.so plugin exists' '
	test -f "${SHARNESS_TEST_SRCDIR}/../src/job-manager/plugins/.libs/delegate.so"
'

test_expect_success 'start two target sub-instances' '
	target_0=$(flux batch -n1 -t120s --wrap sleep inf) &&
	flux job wait-event ${target_0} start &&
	target_1=$(flux batch -n1 -t120s --wrap sleep inf) &&
	flux job wait-event ${target_1} start
'

test_expect_success 'configure delegate plugin with two target URIs' '
	uri_0=$(flux uri --local ${target_0}) &&
	uri_1=$(flux uri --local ${target_1}) &&
	printf "delegate = [ \"%s\", \"%s\" ]\n" "${uri_0}" "${uri_1}" |
		flux config load
'

test_expect_success 'plugin can be loaded' '
	flux jobtap load "${SHARNESS_TEST_SRCDIR}"/../src/job-manager/plugins/.libs/delegate.so &&
	flux jobtap list | grep delegate.so
'

test_expect_success 'assign (no ID) delegates to target 0' '
	jobid=$(flux submit --dependency=delegate:assign hostname) &&
	flux job wait-event --timeout=60 ${jobid} clean &&
	flux job eventlog ${jobid} | grep -q "delegate::submit" &&
	delegated_id=$(flux job eventlog ${jobid} |
		sed -nE "/delegate::submit/ s/.*jobid[\"=:[:space:]]+(\"?)([^\",}[:space:]]+).*/\2/p" |
		head -n 1) &&
	flux proxy ${target_0} flux jobs --format="{id}" "${delegated_id}" >/dev/null 2>&1
'

test_expect_success 'assign:0 delegates to target 0 explicitly' '
	jobid=$(flux submit --dependency=delegate:assign:0 hostname) &&
	flux job wait-event --timeout=60 ${jobid} clean &&
	flux job eventlog ${jobid} | grep -q "delegate::submit" &&
	delegated_id=$(flux job eventlog ${jobid} |
		sed -nE "/delegate::submit/ s/.*jobid[\"=:[:space:]]+(\"?)([^\",}[:space:]]+).*/\2/p" |
		head -n 1) &&
	flux proxy ${target_0} flux jobs --format="{id}" "${delegated_id}" >/dev/null 2>&1
'

test_expect_success 'assign:1 delegates to target 1 explicitly' '
	jobid=$(flux submit --dependency=delegate:assign:1 hostname) &&
	flux job wait-event --timeout=60 ${jobid} clean &&
	flux job eventlog ${jobid} | grep -q "delegate::submit" &&
	delegated_id=$(flux job eventlog ${jobid} |
		sed -nE "/delegate::submit/ s/.*jobid[\"=:[:space:]]+(\"?)([^\",}[:space:]]+).*/\2/p" |
		head -n 1) &&
	flux proxy ${target_1} flux jobs --format="{id}" "${delegated_id}" >/dev/null 2>&1
'

test_expect_success 'assign:99 raises exception for out-of-range index' '
	test_must_fail flux submit --dependency=delegate:assign:99 hostname
'

test_expect_success 'assign:abc raises exception for non-integer index' '
	test_must_fail flux submit --dependency=delegate:assign:abc hostname
'

test_expect_success 'assign:-1 raises exception for negative index' '
	test_must_fail flux submit --dependency=delegate:assign:-1 hostname
'

test_expect_success 'assign: raises exception for empty suffix' '
	test_must_fail flux submit --dependency=delegate:assign: hostname
'

test_expect_success 'random policy delegation still works' '
	jobid=$(flux submit --dependency=delegate:random hostname) &&
	flux job attach ${jobid} &&
	flux job eventlog ${jobid} | grep -q "delegate::submit"
'

test_expect_success 'unload delegate plugin' '
	flux jobtap remove delegate.so
'

test_expect_success 'cancel subinstances' '
	flux cancel --all
'

test_done
