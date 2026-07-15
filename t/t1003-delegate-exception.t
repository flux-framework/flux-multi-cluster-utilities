#!/bin/sh
test_description='Test exception-driven delegation chain across multiple clusters'
. $(dirname $0)/sharness.sh
# Source cluster + B, C, D
test_under_flux 4
get_last_delegate_id () {
	flux job eventlog "$1" |
		sed -nE '/delegate::submit/ s/.*jobid["=:[:space:]]+("?)([^",}[:space:]]+).*/\2/p' |
		tail -n 1
}
wait_for_event_count () {
	jid=$1
	pat=$2
	want=$3
	i=0
	while [ $i -lt 60 ]; do
		n=$(flux job eventlog "$jid" | grep -c "$pat" || true)
		test "$n" -ge "$want" && return 0
		sleep 1
		i=$((i + 1))
	done
	return 1
}
check_job_visible () {
	uri=$1
	jid=$2
	flux proxy "$uri" flux jobs --format='{id}' "$jid" >/dev/null 2>&1
  
}
raise_alloc () {
	uri=$1
	jid=$2
	flux proxy "$uri" flux job raise -t alloc "$jid"
}
test_expect_success 'start three target sub-instances' '
	target_b=$(flux batch -n1 -t120s --wrap sleep inf) &&
	flux job wait-event ${target_b} start &&
	target_c=$(flux batch -n1 -t120s --wrap sleep inf) &&
	flux job wait-event ${target_c} start &&
	target_d=$(flux batch -n1 -t120s --wrap sleep inf) &&
	flux job wait-event ${target_d} start
'
test_expect_success 'configure delegate plugin with three target URIs' '
	uri_b=$(flux uri --local ${target_b}) &&
	uri_c=$(flux uri --local ${target_c}) &&
	uri_d=$(flux uri --local ${target_d}) &&
	printf "delegate = [ \"%s\", \"%s\", \"%s\" ]\n" \
		"${uri_b}" "${uri_c}" "${uri_d}" |
		flux config load &&
	flux config get | jq -e .
'
test_expect_success 'plugin can be loaded' '
	flux jobtap load "${SHARNESS_TEST_SRCDIR}"/../src/job-manager/plugins/.libs/delegate.so &&
	flux jobtap list | grep delegate.so
'
test_expect_success 'alloc exception on B re-delegates to C' '
	jobid=$(flux submit -S system.delegate=assign:0 sleep inf) &&
	wait_for_event_count "${jobid}" "delegate::submit" 1 &&
	delegated_b=$(get_last_delegate_id "${jobid}") &&
	check_job_visible "${uri_b}" "${delegated_b}" &&
	raise_alloc "${uri_b}" "${delegated_b}" &&
	wait_for_event_count "${jobid}" "delegate::submit" 2 &&
	delegated_c=$(get_last_delegate_id "${jobid}") &&
	check_job_visible "${uri_c}" "${delegated_c}" &&
	flux cancel "${jobid}" &&
	flux job wait-event --timeout=10 "${jobid}" clean
'
test_expect_success 'alloc exceptions on B then C re-delegate to D' '
	jobid=$(flux submit -S system.delegate=assign:0 sleep inf) &&
	wait_for_event_count "${jobid}" "delegate::submit" 1 &&
	delegated_b=$(get_last_delegate_id "${jobid}") &&
	check_job_visible "${uri_b}" "${delegated_b}" &&
	raise_alloc "${uri_b}" "${delegated_b}" &&
	wait_for_event_count "${jobid}" "delegate::submit" 2 &&
	delegated_c=$(get_last_delegate_id "${jobid}") &&
	check_job_visible "${uri_c}" "${delegated_c}" &&
	raise_alloc "${uri_c}" "${delegated_c}" &&
	wait_for_event_count "${jobid}" "delegate::submit" 3 &&
	delegated_d=$(get_last_delegate_id "${jobid}") &&
	check_job_visible "${uri_d}" "${delegated_d}" &&
	flux cancel "${jobid}" &&
	flux job wait-event --timeout=10 "${jobid}" clean
'
test_expect_success 'alloc exceptions on B C and D fail back in source cluster' '
	jobid=$(flux submit -S system.delegate=assign:0 sleep inf) &&
	wait_for_event_count "${jobid}" "delegate::submit" 1 &&
	delegated_b=$(get_last_delegate_id "${jobid}") &&
	raise_alloc "${uri_b}" "${delegated_b}" &&
	wait_for_event_count "${jobid}" "delegate::submit" 2 &&
	delegated_c=$(get_last_delegate_id "${jobid}") &&
	raise_alloc "${uri_c}" "${delegated_c}" &&
	wait_for_event_count "${jobid}" "delegate::submit" 3 &&
	delegated_d=$(get_last_delegate_id "${jobid}") &&
	raise_alloc "${uri_d}" "${delegated_d}" &&
	flux job wait-event --timeout=10 "${jobid}" clean &&
	flux job eventlog "${jobid}" | grep -Eq "DelegationFailure"
'
test_expect_success 'unload delegate plugin' '
	flux jobtap remove delegate.so
'
test_expect_success 'cancel subinstances' '
	flux cancel --all
'
test_done
