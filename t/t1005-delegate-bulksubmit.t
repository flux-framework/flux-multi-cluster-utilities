#!/bin/sh

test_description='Test flux bulksubmit works with the delegate assign policy'

# flux bulksubmit submits many similar jobs at once using template
# substitution -- like xargs for Flux jobs. Patterns used below:
#   {seq}     - sequence number (0, 1, 2, ...)
#   {0}, {1}  - value from the first/second input list (Cartesian product)
#   --define=NAME=EXPR, referenced as {.NAME} - a computed value (e.g. modulo)
#
# This test exercises the delegate plugin's assign policy through
# bulksubmit rather than individual flux submit calls:
#  - round-robin distribution via assign:{seq}
#  - modulo-wrapped distribution via --define, for a batch larger than
#    the number of configured targets
#  - {0}/{1} indexed inputs (Cartesian product)
#  - error handling for an out-of-range target index

. $(dirname $0)/sharness.sh

test_under_flux 4

# Extract the jobid a source job was delegated to, from its own eventlog.
extract_delegated_id() {
	flux job eventlog "$1" |
		sed -nE '/delegate::submit/ s/.*jobid["=:[:space:]]+("?)([^",}[:space:]]+).*/\2/p' |
		head -n 1
}

test_expect_success 'start three target sub-instances' '
	target_0=$(flux batch -n1 -t120s --wrap sleep inf) &&
	flux job wait-event ${target_0} start &&
	target_1=$(flux batch -n1 -t120s --wrap sleep inf) &&
	flux job wait-event ${target_1} start &&
	target_2=$(flux batch -n1 -t120s --wrap sleep inf) &&
	flux job wait-event ${target_2} start
'

test_expect_success 'configure delegate plugin with three target URIs' '
	uri_0=$(flux uri --local ${target_0}) &&
	uri_1=$(flux uri --local ${target_1}) &&
	uri_2=$(flux uri --local ${target_2}) &&
	cat <<-EOF | flux config load && flux config get | jq -e .
	[[delegate]]
	uri = "${uri_0}"
	label = "target0"

	[[delegate]]
	uri = "${uri_1}"
	label = "target1"

	[[delegate]]
	uri = "${uri_2}"
	label = "target2"
	EOF
'

test_expect_success 'plugin can be loaded' '
	flux jobtap load "${SHARNESS_TEST_SRCDIR}"/../src/job-manager/plugins/.libs/delegate.so &&
	flux jobtap list | grep delegate.so
'

# assign:{seq} maps job N directly to target N (0->target0, 1->target1,
# 2->target2); verifies both placement and the delegated job's output.
test_expect_success 'bulksubmit assign:{seq} round-robins jobs to targets with correct output' '
	seq 0 2 | flux bulksubmit -S system.delegate=assign:{seq} echo job-{seq} >simple.out &&
	test $(wc -l <simple.out) -eq 3 &&
	i=0 &&
	for id in $(cat simple.out); do
		flux job wait-event -vt 5 ${id} delegate::submit &&
		delegated_id=$(extract_delegated_id ${id}) &&
		test -n "${delegated_id}" &&
		eval "uri=\${uri_${i}}" &&
		flux proxy ${uri} flux job wait-event -t 5 -m status=0 ${delegated_id} finish &&
		flux proxy ${uri} flux job wait-event -vt 10 ${delegated_id} clean &&
		flux proxy ${uri} flux job attach ${delegated_id} | grep "job-${i}" &&
		flux job wait-event -t 5 -m status=0 ${id} finish &&
		flux job wait-event -vt 10 ${id} clean &&
		flux job attach ${id} 2>&1 | grep "No job output found" &&
		i=$((i + 1))
	done
'

# 6 jobs, only 3 targets: --define wraps the target index via seq % 3,
# so assign round-robins twice over (jobs 0,3->target0, 1,4->target1,
# 2,5->target2) instead of raising DelegationFailure on jobs 3-5.
test_expect_success 'bulksubmit modulo-wrapped assign distributes 6 jobs across 3 targets' '
	seq 0 5 | flux bulksubmit --define=tgt="int(x)%3" -S system.delegate=assign:{.tgt} hostname \
		>modulo.out &&
	test $(wc -l <modulo.out) -eq 6 &&
	i=0 &&
	for id in $(cat modulo.out); do
		flux job wait-event -vt 5 ${id} delegate::submit &&
		delegated_id=$(extract_delegated_id ${id}) &&
		test -n "${delegated_id}" &&
		eval "uri=\${uri_$((i % 3))}" &&
		flux proxy ${uri} flux jobs --format="{id}" "${delegated_id}" >/dev/null 2>&1 &&
		flux proxy ${uri} flux job wait-event -t 5 -m status=0 ${delegated_id} finish &&
		flux proxy ${uri} flux job wait-event -vt 10 ${delegated_id} clean &&
		flux job wait-event -t 5 -m status=0 ${id} finish &&
		flux job wait-event -vt 10 ${id} clean &&
		i=$((i + 1))
	done
'

# ::: 0 1 2 ::: x y forms a 3x2 Cartesian product: (0,x) (0,y) (1,x)
# (1,y) (2,x) (2,y); assign:{0} routes each pair by its first-list
# value, so target = job_index / 2.
test_expect_success 'bulksubmit assign:{0} indexed inputs distribute a 3x2 Cartesian product correctly' '
	flux bulksubmit -S system.delegate=assign:{0} hostname ::: 0 1 2 ::: x y >mixed.out &&
	test $(wc -l <mixed.out) -eq 6 &&
	i=0 &&
	for id in $(cat mixed.out); do
		flux job wait-event -vt 5 ${id} delegate::submit &&
		delegated_id=$(extract_delegated_id ${id}) &&
		test -n "${delegated_id}" &&
		eval "uri=\${uri_$((i / 2))}" &&
		flux proxy ${uri} flux jobs --format="{id}" "${delegated_id}" >/dev/null 2>&1 &&
		flux proxy ${uri} flux job wait-event -t 5 -m status=0 ${delegated_id} finish &&
		flux proxy ${uri} flux job wait-event -vt 10 ${delegated_id} clean &&
		flux job wait-event -t 5 -m status=0 ${id} finish &&
		flux job wait-event -vt 10 ${id} clean &&
		i=$((i + 1))
	done
'

# NOTE: an out-of-range assign target raises a DelegationFailure exception
# immediately after `depend`, before the job is ever scheduled -- these
# jobs never emit a `finish` event, so only `clean` is checked here.
test_expect_success 'bulksubmit assign to an out-of-range target raises DelegationFailure' '
	flux bulksubmit -S system.delegate=assign:99 hostname ::: 1 2 3 >invalid.out &&
	test $(wc -l <invalid.out) -eq 3 &&
	for id in $(cat invalid.out); do
		flux job wait-event -vt 10 ${id} clean &&
		flux job eventlog ${id} | grep -q "DelegationFailure"
	done
'

test_expect_success 'unload delegate plugin' '
	flux jobtap remove delegate.so
'

test_expect_success 'cancel subinstances' '
	flux cancel --all &&
	rm -f simple.out modulo.out mixed.out invalid.out
'

test_done
