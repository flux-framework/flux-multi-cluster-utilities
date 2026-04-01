## Flux Multi-Cluster Utilities
This repository houses the artifacts developed as part of the 
FRACTALE SI's Center-Level Scheduling Thrust. 
One of the goals of this thrust is to enable scheduling jobs across different 
clusters of a site, with the objective of 
improving job performance, turnaround times, system throughput and utilization. 
A future goal is to enable such scheduling across both HPC clusters and on-premises 
Cloud setups.

To this effect, the first building block is a jobtap plugin 
that allows a job to be delegated (submitted) from the 
current flux instance to a different flux instance (given its URI).

### Build Instructions

We use GNU Autotools to build this plugin as follows.

```
./autogen.sh
./configure --prefix=<install-path>
make && make install
```
The `delegate.so` plugin will be installed in `<install-path>/lib/flux/job-manager/plugins/`.

If an `<install-path>` is specified, it is also installed in `flux-multi-cluster-utilities/src/job-manager/plugins/.libs`.

### Loading a JobTap Plugin
The plugin can be loaded with the command below. 
Note that an absolute path needs to be specified here. 
`flux jobtap load $(realpath path/to/plugin/delegate.so)`

For selection-based delegation, pass a TOML config file with a top-level
`clusters` string array.

```toml
clusters = [
     "ssh://cluster-a/path/to/local-0",
     "ssh://cluster-b/path/to/local-0"
]
```

Load the plugin with that configuration as follows.

```
flux jobtap load $(realpath path/to/plugin/delegate.so) config=$(realpath path/to/clusters.toml)
```

### Interactive Testing on Peer-to-Peer Flux Instances

Here, we show an example of peer-to-peer flux instances, residing on the same cluster
and belonging to the same user. Enabling testing across flux instances on different clusters
is ongoing research. 

This plugin was tested on the Corona cluster across a 4 node allocation.
Similar steps can be performed on any other cluster. 

#### 1. Obtain an interactive allocation on the desired cluster.
```
flux alloc -N4      # Default resource manager is Flux, e.g. Corona
salloc -N4          # Default resource manager is SLURM
```
_Note_: If the default resource manager is SLURM, a `flux start` will be needed to start a top-level Flux instance.
This can be done using `srun -N4 -n4 flux start -N4` or `srun --tasks-per-node=1 flux start` within the SLURM allocation.

#### 2. Create two child flux instances (A and B) and split the resources among them. 

```
$ flux resource list    # Verify that the top-level instance has 4 nodes

    STATE PROPERTIES NNODES   NCORES    NGPUS NODELIST
      free pbatch          4      192       32 corona[189-192]
 allocated                 0        0        0 
      down                 0        0        0 

$ flux submit -N2 flux start sleep inf      # Launch a child instance, Instance A, on 2 nodes 
fNGFMaMu

$ flux submit -N2 flux start sleep inf      # Launch another child instance, Instance B on 2 nodes. 
fPhtF4SB
```

#### 3. Obtain the URI for Instance B, which we want to delegate to.
We utilize `flux proxy` and provide it the Job ID to get the instance's local URI,
and then convert this to a remote URI using `flux uri --remote`. We use the remote URI
in the next steps.

```
$ flux proxy fPhtF4SB flux getattr local-uri                        # Local URI
local:///var/tmp/patki1/flux-sCMd4I/local-0

$ flux uri --remote local:///var/tmp/patki1/flux-sCMd4I/local-0     # Remote URI
ssh://corona189/var/tmp/patki1/flux-sCMd4I/local-0
```

#### 4. Proxy to Instance A, and load the jobtap plugin.
We now have all the information to submit to Instance B,  so we `proxy` to 
Instance A and load the jobtap plugin. 

```
$ flux proxy fNGFMaMu       # Use the Job ID for Instance A

$ flux resource list        # Verify that we have 2 nodes, and note their hostnames.
     STATE PROPERTIES NNODES   NCORES    NGPUS NODELIST
      free pbatch          2       96       16 corona[191-192]
 allocated                 0        0        0 
      down                 0        0        0 

$ $ flux jobtap load <path-to-plugin>/delegate.so 
```
Here, we note that Instance A has resources `corona[191-192]`, and as a result, 
Instance B has resources `corona[189-190]` (can be verified similarly). 

#### 5. Submit a job from Instance A to Instance B.
Finally, we submit a job (`hostname -N2 -n2` in our example) 
to Instance B from Instance A. Our output should be `corona[189-190]` as we are 
executing on Instance B. 

```
$  flux submit --dependency=delegate:ssh://corona189/var/tmp/patki1/flux-sCMd4I/local-0 -N2 -n2 hostname
f7Qv4KHXM
```

#### 6. View the status of the job from Instance A.
Delegation was successful! Note that this is currently reported 
as an _exception_ state, as we do not have a _delegate_ state for jobs
within Flux at the time of writing this plugin. 

```
flux job attach f7Qv4KHXM
0.573s: job.exception type=DelegationSuccess severity=0 
```

#### 7. View the results of the job.

There are two ways to view the results of the job that was delegated to Instance B.

The first approach works while we are on Instance A. 
Here, we obtain the corresponding Job ID on Instance B using `flux job eventlog`, 
and then using `flux job attach` with `flux proxy`, as shown below. 
Note here that we use `flux proxy --parent` as the ID for
Instance B is associated with the top-level original instance and was created in step 2. 
Our output correctly shows `corona[189-190]` for Instance B. 

```
$ flux job eventlog f7Qv4KHXM
1726788422.214450 submit userid=36985 urgency=16 flags=0 version=1
1726788422.510129 dependency-add description="delegated"
1726788422.510808 validate
1726788422.711362 delegated jobid=14112474005504
1726788422.787900 exception type="DelegationSuccess" severity=0 note="" userid=36985
1726788422.787967 clean


$ flux job id --to=f58 14112474005504           # Convert the JobID obtained from eventlog to the f58 format
f7PiE17dH

$ flux --parent proxy fPhtF4SB flux job attach f7PiE17dH
corona189
corona190
```

In the second approach, we can `proxy` to Instance B and examine the results of the job
as shown below.

```
$ flux --parent proxy fPhtF4SB 

$ flux jobs -a
       JOBID USER     NAME       ST NTASKS NNODES     TIME INFO
   f7PiE17dH patki1   hostname   CD      2      2   0.074s corona[189-190]

$ flux job attach f7PiE17dH
corona189
corona190
```

### Testing Using Docker

A Dockerfile with el9 has also been provided for testing in a reproducible containerized environment.
To launch the docker container interactively:
```
src/test/docker/docker-run-checks.sh --image el9 --no-home --no-cache -I --
``` 

The steps shown in the previous section can be adapted easily for testing with the container. 
Instead of creating each child instance spanning 2 nodes, as shown in Step 2, 
the instance can be created across core-granularities, as shown below, on a single node.

```
flux submit -n1 -c2 flux start sleep inf
```

### Upcoming Research

At present, the jobtap plugin does not query the other instance 
about its resource graph and availability of resources. It also 
does not take into account any filterning criteria, such as 
compatibility with hardware, job-level performance, or wait times. 
These will be added as we continue to make progress through this SI. 

## Auspices

This work was supported by the LLNL-LDRD Program under Project No. 24-SI-005.

## License

SPDX-License-Identifier: LGPL-3.0

LLNL-CODE-764420
