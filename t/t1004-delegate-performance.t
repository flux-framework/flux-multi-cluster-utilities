#!/bin/sh

test_description='Test performance delegation policy for table-backed target selection'

. $(dirname $0)/sharness.sh

test_under_flux 3

if ! command -v flux >/dev/null 2>&1; then
	skip_all='flux command not found, skipping tests'
	test_done
fi

test_expect_success 'delegate.so plugin exists' '
	test -f "${SHARNESS_TEST_SRCDIR}/../src/job-manager/plugins/.libs/delegate.so"
'

test_expect_success 'start two target sub-instances' '
	target_0=$(flux batch -n1 -t120s --wrap sleep inf) &&
	flux job wait-event --timeout=60 ${target_0} start &&
	target_1=$(flux batch -n2 -t120s --wrap sleep inf) &&
	flux job wait-event --timeout=60 ${target_1} start
'

test_expect_success 'performance provider missing file fails plugin load' '
	uri_1=$(flux uri --local ${target_1}) &&
	cat >delegate-missing-performance-file.toml <<-EOF &&
	[[delegate_targets]]
	system = "system_b"
	uri = "${uri_1}"
	nodes = 2

	[performance]
	provider = "toml"
	path = "$(pwd)/missing-performance-table.toml"
	allow_resource_rewrite = false
	EOF
	flux config load <delegate-missing-performance-file.toml &&
	test_must_fail flux jobtap load "${SHARNESS_TEST_SRCDIR}"/../src/job-manager/plugins/.libs/delegate.so
'

test_expect_success 'unsupported candidate.match syntax fails plugin load' '
	cat >unsupported-match-table.toml <<-EOF &&
	version = 1

	[[candidate]]
	id = "future-match-syntax"
	system = "system_b"
	nodes = 1
	execution_time = 1.0

	[candidate.match]
	param_a = 42
	EOF
	cat >delegate-unsupported-match.toml <<-EOF &&
	[[delegate_targets]]
	system = "system_b"
	uri = "${uri_1}"
	nodes = 2

	[performance]
	provider = "toml"
	path = "$(pwd)/unsupported-match-table.toml"
	allow_resource_rewrite = false
	EOF
	flux config load <delegate-unsupported-match.toml &&
	test_must_fail flux jobtap load "${SHARNESS_TEST_SRCDIR}"/../src/job-manager/plugins/.libs/delegate.so
'

test_expect_success 'malformed performance TOML fails plugin load' '
	cat >malformed-performance-table.toml <<-EOF &&
	version = 1
	[[candidate]
	system = "system_b"
	EOF
	cat >delegate-malformed-performance.toml <<-EOF &&
	[[delegate_targets]]
	system = "system_b"
	uri = "${uri_1}"
	nodes = 2

	[performance]
	provider = "toml"
	path = "$(pwd)/malformed-performance-table.toml"
	allow_resource_rewrite = false
	EOF
	flux config load <delegate-malformed-performance.toml &&
	test_must_fail flux jobtap load "${SHARNESS_TEST_SRCDIR}"/../src/job-manager/plugins/.libs/delegate.so
'

test_expect_success 'performance provider missing does not fall back to random' '
	cat >delegate-no-provider.toml <<-EOF &&
	[[delegate_targets]]
	system = "system_b"
	uri = "${uri_1}"
	nodes = 2
	EOF
	flux config load <delegate-no-provider.toml &&
	flux jobtap load "${SHARNESS_TEST_SRCDIR}"/../src/job-manager/plugins/.libs/delegate.so &&
	test_must_fail flux submit -N1 -n1 --dependency=delegate:performance \
		-S user.performance.param_a=42 \
		-S user.performance.param_b=fft \
		hostname &&
	flux jobtap remove delegate.so
'

test_expect_success 'configure delegate_targets and performance table' '
	uri_0=$(flux uri --local ${target_0}) &&
	uri_1=$(flux uri --local ${target_1}) &&
	cat >performance-table.toml <<-EOF &&
	version = 1

	[[candidate]]
	id = "slow-system-a"
	system = "system_a"
	nodes = 1
	execution_time = 100.0

	[candidate.params]
	param_a = 42
	param_b = "fft"

	[[candidate]]
	id = "fast-system-b"
	system = "system_b"
	nodes = 1
	execution_time = 10.0

	[candidate.params]
	param_a = 42
	param_b = "fft"

	[[candidate]]
	id = "faster-but-nonmatching"
	system = "system_b"
	nodes = 1
	execution_time = 0.1

	[candidate.params]
	param_a = 99
	param_b = "fft"

	[[candidate]]
	id = "unknown-system-fast"
	system = "missing_system"
	nodes = 1
	execution_time = 0.5

	[candidate.params]
	param_a = 42
	param_b = "fft"
	EOF
	cat >delegate-performance.toml <<-EOF &&
	[[delegate_targets]]
	system = "system_a"
	uri = "${uri_0}"
	nodes = 1

	[[delegate_targets]]
	system = "system_b"
	uri = "${uri_1}"
	nodes = 2

	[performance]
	provider = "toml"
	path = "$(pwd)/performance-table.toml"
	allow_resource_rewrite = false
	EOF
	flux config load <delegate-performance.toml
'

test_expect_success 'plugin can be loaded' '
	flux jobtap load "${SHARNESS_TEST_SRCDIR}"/../src/job-manager/plugins/.libs/delegate.so &&
	flux jobtap list | grep delegate.so
'

test_expect_success 'performance delegates to fastest matching target' '
	jobid=$(flux submit -N1 -n1 --dependency=delegate:performance \
		-S user.performance.param_a=42 \
		-S user.performance.param_b=fft \
		hostname) &&
	flux job wait-event --timeout=60 ${jobid} clean &&
	flux job eventlog ${jobid} | grep -q "delegate::submit" &&
	delegated_id=$(flux job eventlog ${jobid} |
		sed -nE "/delegate::submit/ s/.*jobid[\"=:[:space:]]+(\"?)([^\",}[:space:]]+).*/\2/p" |
		head -n 1) &&
	flux proxy ${target_1} flux jobs --format="{id}" "${delegated_id}" >/dev/null 2>&1
'

test_expect_success 'performance fails closed on missing typed params' '
	test_must_fail flux submit --dependency=delegate:performance hostname
'

test_expect_success 'performance fails closed when no candidate matches typed params' '
	test_must_fail flux submit -N1 -n1 --dependency=delegate:performance \
		-S user.performance.param_a=43 \
		-S user.performance.param_b=fft \
		hostname
'

test_expect_success 'performance fails closed when selected nodes require rewrite without opt-in' '
	cat >rewrite-table.toml <<-EOF &&
	version = 1

	[[candidate]]
	id = "two-node-system-b"
	system = "system_b"
	nodes = 2
	execution_time = 1.0

	[candidate.params]
	param_a = 7
	param_b = "stencil"
	EOF
	cat >delegate-rewrite-disabled.toml <<-EOF &&
	[[delegate_targets]]
	system = "system_b"
	uri = "${uri_1}"
	nodes = 2

	[performance]
	provider = "toml"
	path = "$(pwd)/rewrite-table.toml"
	allow_resource_rewrite = false
	EOF
	flux jobtap remove delegate.so &&
	flux config load <delegate-rewrite-disabled.toml &&
	flux jobtap load "${SHARNESS_TEST_SRCDIR}"/../src/job-manager/plugins/.libs/delegate.so &&
	test_must_fail flux submit -N1 -n1 --dependency=delegate:performance \
		-S user.performance.param_a=7 \
		-S user.performance.param_b=stencil \
		hostname
'

test_expect_success 'performance rewrite opt-in rewrites only delegated jobspec copy' '
	cat >rewrite-enabled-table.toml <<-EOF &&
	version = 1

	[[candidate]]
	id = "two-node-system-b-enabled"
	system = "system_b"
	nodes = 2
	execution_time = 1.0

	[candidate.params]
	param_a = 8
	param_b = "stencil"
	EOF
	cat >delegate-rewrite-enabled.toml <<-EOF &&
	[[delegate_targets]]
	system = "system_b"
	uri = "${uri_1}"
	nodes = 2

	[performance]
	provider = "toml"
	path = "$(pwd)/rewrite-enabled-table.toml"
	allow_resource_rewrite = true
	EOF
	flux jobtap remove delegate.so &&
	flux config load <delegate-rewrite-enabled.toml &&
	flux jobtap load "${SHARNESS_TEST_SRCDIR}"/../src/job-manager/plugins/.libs/delegate.so &&
	jobid=$(flux submit -N1 -n1 --dependency=delegate:performance \
		-S user.performance.param_a=8 \
		-S user.performance.param_b=stencil \
		-S user.performance.allow_resource_rewrite=true \
		hostname) &&
	flux job wait-event --timeout=60 ${jobid} clean &&
	delegated_id=$(flux job eventlog ${jobid} |
		sed -nE "/delegate::submit/ s/.*jobid[\"=:[:space:]]+(\"?)([^\",}[:space:]]+).*/\2/p" |
		head -n 1) &&
	flux job info ${jobid} jobspec | jq -e ".resources[0].count == 1" &&
	flux proxy ${target_1} flux job info ${delegated_id} jobspec |
		jq -e ".resources[0].count == 2"
'

test_expect_success 'performance rewrite fails before remote submit on unsupported jobspec shape' '
	test_must_fail flux submit --dependency=delegate:performance \
		-S user.performance.param_a=8 \
		-S user.performance.param_b=stencil \
		-S user.performance.allow_resource_rewrite=true \
		hostname
'

test_expect_success 'unload delegate plugin' '
	flux jobtap remove delegate.so
'

test_expect_success 'cancel subinstances' '
	flux cancel --all
'

test_done
