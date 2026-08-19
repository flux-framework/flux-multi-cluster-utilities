#!/bin/sh

test_description='Test backward compatibility with TOML config without labels'

# This test verifies that the delegate plugin still works with the old
# string array format (without labels):
#   delegate = ["uri1", "uri2"]
#
# This ensures backward compatibility for existing configurations.

. $(dirname $0)/sharness.sh

test_under_flux 3

# Helper to extract delegated jobid
extract_delegated_id() {
	flux job eventlog "$1" |
		sed -nE "/delegate::submit/ s/.*jobid[\"=:[:space:]]+(\"?)([^\",}[:space:]]+).*/\2/p" |
		head -n 1
}

test_expect_success 'start two target sub-instances' '
	target_0=$(flux batch -n1 -t120s --wrap sleep inf) &&
	flux job wait-event ${target_0} start &&
	target_1=$(flux batch -n1 -t120s --wrap sleep inf) &&
	flux job wait-event ${target_1} start
'

test_expect_success 'configure with old string array format (no labels)' '
	uri_0=$(flux uri --local ${target_0}) &&
	uri_1=$(flux uri --local ${target_1}) &&
	printf "delegate = [ \"%s\", \"%s\" ]\n" "${uri_0}" "${uri_1}" |
		flux config load &&
	flux config get | jq -e ".delegate | length" | grep -q "2" &&
	flux config get | jq -e ".delegate[0]" | grep -q "${uri_0}" &&
	flux config get | jq -e ".delegate[1]" | grep -q "${uri_1}"
'

test_expect_success 'plugin can be loaded with old format config' '
	flux jobtap load "${SHARNESS_TEST_SRCDIR}"/../src/job-manager/plugins/.libs/delegate.so &&
	flux jobtap list | grep delegate.so
'

test_expect_success 'random policy works with old format' '
	jobid=$(flux submit -S system.delegate=random hostname) &&
	flux job wait-event -t 5 ${jobid} delegate::submit &&
	delegated_id=$(extract_delegated_id ${jobid}) &&
	test -n "${delegated_id}" &&
	(flux proxy ${uri_0} flux jobs --format="{id}" "${delegated_id}" >/dev/null 2>&1 ||
	 flux proxy ${uri_1} flux jobs --format="{id}" "${delegated_id}" >/dev/null 2>&1)
'

test_expect_success 'assign policy works with old format - target 0' '
	jobid=$(flux submit -S system.delegate=assign:0 hostname) &&
	flux job wait-event -t 5 ${jobid} delegate::submit &&
	delegated_id=$(extract_delegated_id ${jobid}) &&
	test -n "${delegated_id}" &&
	flux proxy ${uri_0} flux jobs --format="{id}" "${delegated_id}" >/dev/null 2>&1
'

test_expect_success 'assign policy works with old format - target 1' '
	jobid=$(flux submit -S system.delegate=assign:1 hostname) &&
	flux job wait-event -t 5 ${jobid} delegate::submit &&
	delegated_id=$(extract_delegated_id ${jobid}) &&
	test -n "${delegated_id}" &&
	flux proxy ${uri_1} flux jobs --format="{id}" "${delegated_id}" >/dev/null 2>&1
'

test_expect_success 'assign rejects invalid indices with old format' '
	jobid=$(flux submit -S system.delegate=assign:2 hostname) &&
	flux job wait-event -vt 5 ${jobid} clean &&
	flux job eventlog ${jobid} | grep -q "exception type=\"DelegationFailure\""
'

test_expect_success 'cancel propagation works with old format' '
	jobid=$(flux submit -S system.delegate=random sleep inf) &&
	flux job wait-event -vt 10 ${jobid} delegate::submit &&
	delegated_id=$(extract_delegated_id ${jobid}) &&
	test -n "${delegated_id}" &&
	flux cancel ${jobid} &&
	flux job wait-event -vt 10 ${jobid} clean &&
	(flux proxy ${uri_0} flux job wait-event -t 5 ${delegated_id} clean 2>/dev/null ||
	 flux proxy ${uri_1} flux job wait-event -t 5 ${delegated_id} clean 2>/dev/null)
'

test_expect_success 'unload delegate plugin' '
	flux jobtap remove delegate.so
'

test_expect_success 'cancel subinstances' '
	flux cancel --all
'

test_done
