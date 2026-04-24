#!/bin/sh

test_description='Test sharness test framework'

. $(dirname $0)/sharness.sh

test_expect_success 'sharness is working' '
	test 1 = 1
'

test_expect_success 'test prereq is set' '
	test -n "$SHARNESS_TEST_SRCDIR"
'

test_expect_success 'PATH is set' '
	test -n "$PATH"
'

test_expect_success 'basic commands work' '
	true
'

test_expect_success 'test comparison works' '
	echo "hello" >output &&
	echo "hello" >expected &&
	test_cmp expected output
'

test_done
