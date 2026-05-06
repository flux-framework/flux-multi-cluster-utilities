#!/bin/sh

test_description='Test least pending jobs delegation policy for load-aware target selection'

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

test_expect_success 'ensure delegate.so plugin is removed and start target sub-instances' '
	# Remove any previously loaded delegate.so plugin from earlier test runs
	flux jobtap list | grep -q delegate.so && flux jobtap remove delegate.so || true &&

	# Start first target sub-instance on a node
	target_0=$(flux batch -n1 -t120s --wrap sleep inf) &&
	flux job wait-event --timeout=60 ${target_0} start &&

	# Start second target sub-instance on another node
	target_1=$(flux batch -n1 -t120s --wrap sleep inf) &&
	flux job wait-event --timeout=60 ${target_1} start
'

test_expect_success 'configure delegate plugin with two target URIs and load it' '
	uri_0=$(flux uri --local ${target_0}) &&
	uri_1=$(flux uri --local ${target_1}) &&
	DELEGATE_CONFIG="${SHARNESS_TEST_SRCDIR}/clusters.toml" &&
	printf "clusters = [\"%s\", \"%s\"]\n" "${uri_0}" "${uri_1}" >"${DELEGATE_CONFIG}" &&

	flux jobtap load "${SHARNESS_TEST_SRCDIR}"/../src/job-manager/plugins/.libs/delegate.so \
		config="${DELEGATE_CONFIG}" &&
	flux jobtap list | grep delegate.so
'

test_expect_success 'submit 2 jobs with assign policy to target_0 without waiting (to create pending load)' '
	# Submit first job explicitly to target_0 using assign:0 WITHOUT waiting for completion.
	# This ensures the job will be in "pending" state on target_0 when we query for least_pending.
	jobid_0a=$(flux submit --dependency=delegate:assign:0 hostname) &&

	# Small delay to let the first job enter pending state on target_0
	sleep 2 &&

	# Submit second job also to target_0 using assign:0 WITHOUT waiting for completion.
	# Now target_0 should have 2 pending jobs while target_1 has 0.
	jobid_0b=$(flux submit --dependency=delegate:assign:0 hostname)
'

test_expect_success 'least_pending policy delegates to target_1 (lower pending count)' '
	# Small delay to ensure the assign:0 jobs are properly queued on target_0
	# before we query for least_pending. This ensures accurate pending counts.
	sleep 2 &&

	# Submit a job with least_pending policy.
	# Target 0 has 2 pending jobs, target 1 has 0 pending jobs.
	# The least_pending policy should select target_1 since it has fewer pending jobs.
	jobid=$(flux submit --dependency=delegate:least_pending hostname) &&

	# Wait for the delegate::submit event to get the delegated job ID
	flux job wait-event --timeout=60 ${jobid} "delegate::submit" &&

	# Extract the delegated job ID from the eventlog
	delegated_id=$(flux job eventlog ${jobid} |
		sed -nE "/delegate::submit/ s/.*jobid[\"=:[:space:]]+(\"?)([^\",}[:space:]]+).*/\2/p" |
		head -n 1) &&

	# Verify the delegated job is on target_1 (not target_0)
	# This confirms least_pending selected target_1 which has fewer pending jobs
	flux proxy ${target_1} flux jobs --format="{id}" "${delegated_id}" >/dev/null 2>&1
'

test_expect_success 'least_pending: verify delegated job completes successfully on target_1' '
	# Submit another job with least_pending policy for a second verification
	jobid2=$(flux submit --dependency=delegate:least_pending hostname) &&

	# Wait for delegate::submit event to get the delegated ID
	flux job wait-event --timeout=60 ${jobid2} "delegate::submit" &&

	# Extract the delegated job ID from the eventlog
	delegated_id2=$(flux job eventlog ${jobid2} |
		sed -nE "/delegate::submit/ s/.*jobid[\"=:[:space:]]+(\"?)([^\",}[:space:]]+).*/\2/p" |
		head -n 1) &&

	# Verify the delegated job is on target_1 (which should still have fewer pending jobs)
	flux proxy ${target_1} flux jobs --format="{id}" "${delegated_id2}" >/dev/null 2>&1 &&

	# Wait for the job to complete successfully
	flux job wait-event --timeout=60 ${jobid2} clean
'

test_expect_success 'wait for previously submitted assign:0 jobs to complete' '
	# Wait for the jobs we submitted earlier without waiting
	flux job wait-event --timeout=120 ${jobid_0a} clean &&
	flux job wait-event --timeout=120 ${jobid_0b} clean
'

test_expect_success 'assign:0 still works after least_pending tests (deterministic selection)' '
	# Verify assign policy is not affected by least_pending tests.
	# assign:0 should always select target_0 regardless of pending counts.
	jobid=$(flux submit --dependency=delegate:assign:0 hostname) &&
	flux job wait-event --timeout=60 ${jobid} clean &&
	flux job eventlog ${jobid} | grep -q "delegate::submit" &&
	delegated_id=$(flux job eventlog ${jobid} |
		sed -nE "/delegate::submit/ s/.*jobid[\"=:[:space:]]+(\"?)([^\",}[:space:]]+).*/\2/p" |
		head -n 1) &&
	flux proxy ${target_0} flux jobs --format="{id}" "${delegated_id}" >/dev/null 2>&1
'

test_expect_success 'assign:1 still works after least_pending tests (deterministic selection)' '
	# Verify assign policy for target_1 is not affected.
	# assign:1 should always select target_1 regardless of pending counts.
	jobid=$(flux submit --dependency=delegate:assign:1 hostname) &&
	flux job wait-event --timeout=60 ${jobid} clean &&
	flux job eventlog ${jobid} | grep -q "delegate::submit" &&
	delegated_id=$(flux job eventlog ${jobid} |
		sed -nE "/delegate::submit/ s/.*jobid[\"=:[:space:]]+(\"?)([^\",}[:space:]]+).*/\2/p" |
		head -n 1) &&
	flux proxy ${target_1} flux jobs --format="{id}" "${delegated_id}" >/dev/null 2>&1
'

test_expect_success 'random policy delegation still works after least_pending tests' '
	# Verify random policy is not affected by least_pending tests.
	jobid=$(flux submit --dependency=delegate:random hostname) &&
	flux job attach ${jobid} &&
	flux job eventlog ${jobid} | grep -q "delegate::submit"
'

test_expect_success 'shortest_match policy delegation still works after least_pending tests' '
	# Verify shortest_match policy is not affected by least_pending tests.
	jobid=$(flux submit --dependency=delegate:shortest_match hostname) &&
	flux job attach ${jobid} &&
	flux job eventlog ${jobid} | grep -q "delegate::submit"
'

test_expect_success 'cancel all jobs and subinstances' '
	flux cancel --all
'

test_done
