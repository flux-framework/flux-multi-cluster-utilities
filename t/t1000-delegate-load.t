#!/bin/sh

test_description='Test delegate plugin can be loaded'

. $(dirname $0)/sharness.sh

# Check if we're in test environment with flux available
if ! command -v flux >/dev/null 2>&1; then
	skip_all='flux command not found, skipping tests'
	test_done
fi

test_expect_success 'delegate.so plugin exists' '
	test -f "${SHARNESS_TEST_SRCDIR}/../src/job-manager/plugins/.libs/delegate.so"
'

test_expect_success 'flux instance can be started' '
	flux start true
'

# Note: Actual loading tests would require a running flux instance
# and proper URI configuration. These can be added once the test
# infrastructure is more mature.

test_done
