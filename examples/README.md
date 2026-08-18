# Examples

The `examples/` directory contains scripts demonstrating various delegation policies and multi-system Flux configurations.

## Prerequisites

All examples require:

- A built and installed version of this repository (`make && make install`)
- An active Flux allocation (e.g., `flux alloc -N4` or `salloc -N4` followed by `flux start`)
- The `delegate.so` plugin at `<install-path>/lib/flux/job-manager/plugins/delegate.so`

---

## Single-System Delegation

These scripts demonstrate delegation policies within a single Flux allocation using one source instance and three target sub-instances.

| Script | Description |
|--------|-------------|
| [`assign-delegation-3instances.sh`](assign-delegation-3instances.sh) | Demonstrates the **assign** delegation policy. Creates one source Flux instance and three 1-node target sub-instances, then submits a job that gets assigned to a specific target by index. |
| [`random-delegation-3instances.sh`](random-delegation-3instances.sh) | Demonstrates the **random** delegation policy. Creates one source Flux instance and three 1-node target sub-instances, then submits test jobs that get randomly delegated across the three targets. |
| [`shortest-match-delegation-3instances.sh`](shortest-match-delegation-3instances.sh) | demonstrates the **shortest_match** delegation policy. creates contention by loading two jobs onto target-0, then submits a job that selects the least-loaded target based on match times. Here, match times represent the time taken to schedule the job itself; this includes searching the resource graph and identifying matching resources. On very large systems, match time could be in minutes. |
| [`least-pending-delegation-3instances.sh`](least-pending-delegation-3instances.sh) | Demonstrates the **least_pending** delegation policy. Creates two pending jobs on target-0, then submits a job that selects an idle target instead. |

**Usage:**

```bash
bash examples/random-delegation-3instances.sh
# or
bash examples/shortest-match-delegation-3instances.sh
# or
bash examples/least-pending-delegation-3instances.sh
# or
bash examples/assign-delegation-3instances.sh
```

Each script creates its own temporary `*-clusters.toml` config file and cleans up on exit.

---

## Multi-System Delegation

| Script | Description |
|--------|-------------|
| [`job-delegation.sh`](job-delegation.sh) | Demonstrates real multi-system Flux job delegation across Tuolumne, Corona, and Tioga. Submits a trace of 5 jobs with mixed policies (`random`, `least_pending`, `shortest_match`), allocates target sub-instances on each system via a layout config, and produces a per-job and per-target summary report. |

**Usage:**

```bash
bash examples/job-delegation.sh          # Uses default multisystem-layout.conf
```
