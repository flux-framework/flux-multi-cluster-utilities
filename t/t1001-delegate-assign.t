#!/bin/sh

test_description='Test assign delegation policy for deterministic target selection'

. $(dirname $0)/sharness.sh

test_under_flux 3

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
		flux config load && flux config get | jq -e .
'

test_expect_success 'plugin can be loaded' '
	flux jobtap load "${SHARNESS_TEST_SRCDIR}"/../src/job-manager/plugins/.libs/delegate.so &&
	flux jobtap list | grep delegate.so
'

test_expect_success 'assign chooses the requested target' '
	jobid=$(flux submit --dependency=delegate:assign:1 hostname) &&
	flux job wait-event --timeout=60 ${jobid} clean &&
	flux job eventlog ${jobid} | grep -q "delegate::submit" &&
	delegated_id=$(flux job eventlog ${jobid} |
		sed -nE "/delegate::submit/ s/.*jobid[\"=:[:space:]]+(\"?)([^\",}[:space:]]+).*/\2/p" |
		head -n 1) &&
	flux proxy ${uri_1} flux jobs --format="{id}" "${delegated_id}" >/dev/null 2>&1
'

test_expect_success 'assign rejects invalid target indices' '
	test_must_fail flux submit --dependency=delegate:assign:2 hostname
'

test_expect_success 'unload delegate plugin' '
	flux jobtap remove delegate.so
'

test_expect_success 'cancel subinstances' '
	flux cancel --all
'

test_done
