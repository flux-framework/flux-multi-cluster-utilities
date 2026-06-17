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
	echo "
delegate = [ \"${URI}\" ]
	" | flux config load &&
	flux config get | jq -e .
'

test_expect_success 'plugin can be loaded' '
	flux jobtap load "${SHARNESS_TEST_SRCDIR}"/../src/job-manager/plugins/.libs/delegate.so &&
	flux jobtap list | grep delegate.so
'

test_expect_success 'delegation submission works' '
	jobid=$(flux submit -S system.delegate=random hostname) &&
	flux job attach $jobid &&
	flux job eventlog -H $jobid
'

test_expect_success 'cancel subinstances' '
	flux cancel --all
'

test_done
