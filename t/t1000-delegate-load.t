#!/bin/sh

test_description='Test delegate plugin can be loaded'

. $(dirname $0)/sharness.sh

test_under_flux 2

# Check if we're in test environment with flux available
if ! command -v flux >/dev/null 2>&1; then
	skip_all='flux command not found, skipping tests'
	test_done
fi

test_expect_success 'delegate.so plugin exists' '
	test -f "${SHARNESS_TEST_SRCDIR}/../src/job-manager/plugins/.libs/delegate.so"
'

test_expect_success 'start subinstance for delegation' '
	subinstance=$(flux batch -n1 -t120s --wrap sleep inf) &&
	flux job wait-event ${subinstance} start
'

test_expect_success 'configure flux with subinstance for delegation' '
	URI=$(flux uri --local ${subinstance}) &&
	cat <<-EOF | flux config load && flux config get | jq -e .
	[[delegate]]
	uri = "${URI}"
	label = "target0"
	EOF
'

test_expect_success 'plugin can be loaded' '
	flux jobtap load "${SHARNESS_TEST_SRCDIR}"/../src/job-manager/plugins/.libs/delegate.so &&
	flux jobtap list | grep delegate.so
'

test_expect_success 'delegation submission works' '
	jobid=$(flux submit -S system.delegate=random hostname) &&
	flux job wait-event -vt 2 ${jobid} delegate::submit &&
	delegated_id=$(flux job eventlog ${jobid} |
		sed -nE "/delegate::submit/ s/.*jobid[\"=:[:space:]]+(\"?)([^\",}[:space:]]+).*/\2/p" |
		head -n 1) &&
	flux proxy ${URI} flux job wait-event -vt 5 -m status=0 "${delegated_id}" finish &&
	flux proxy ${URI} flux job attach "${delegated_id}" | grep $(hostname) &&
	flux job wait-event -t 5 ${jobid} start &&
	flux job wait-event -t 5 -m status=0 ${jobid} finish &&
	flux job wait-event -vt 5 ${jobid} clean &&
	flux job attach $jobid 2>&1 | grep "No job output found"
'

test_expect_success 'delegated dependent job runs after first job completes' '
  job1=$(flux submit sleep inf) &&
	job2=$(flux submit --dependency=afterany:${job1} -S system.delegate=random hostname) &&
	test_must_fail flux job wait-event -vt 2 ${job2} start &&
	flux cancel ${job1} &&
	flux job wait-event -t 1 ${job1} clean &&
	flux job wait-event -vt 5 ${job2} start &&
	flux job wait-event -t 5 -m status=0 ${job2} finish &&
	flux job wait-event -t 5 ${job2} clean &&
	flux job attach ${job2} 2>&1 | grep "No job output found"
'
test_expect_success 'cancel subinstances' '
	flux cancel --all
'
test_done
