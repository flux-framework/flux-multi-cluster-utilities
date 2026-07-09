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

Supported delegation policies are `random`, `least_pending`, `shortest_match`,
and `assign`.

### Loading a JobTap Plugin
The plugin can be loaded with the command below. But, before that 
Note that an absolute path needs to be specified here. 
`flux jobtap load $(realpath path/to/plugin/delegate.so)`

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
$ flux alloc -N 4 -q pdebug
     STATE NNODES NCORES NGPUS NODELIST # Verify that top level instance has 4 nodes.
      free      4    384    16 tuolumne[1036-1038,1042]
 allocated      0      0     0
      down      0      0     0

$ flux submit -N2 flux start sleep inf      # Launch a child instance, Instance A, on 2 nodes 
fmerUPiw

$ flux submit -N2 flux start sleep inf      # Launch another child instance, Instance B on 2 nodes. 
fkw8xbpB
```

#### 3. Obtain the URI for Instance B, which we want to delegate to.
We utilize `flux proxy` and provide it the Job ID to get the instance's local URI,
and then convert this to a remote URI using `flux uri --remote`. We use the remote URI
in the next steps.

```
$ flux uri fkw8xbpB                        # Local URI
ssh://tuolumne1031/var/tmp/namankul/flux-sOzON0/local-0
```

#### 4. Build the config file.
The jobtap plugin requires a config file to be loaded, containing the URI for all the sub-instances. In our example the config script will contains the URI of B sub-instance.

```
echo 'delegate=["ssh://tuolumne1031/var/tmp/namankul/flux-sOzON0/local-0"]' > config.toml
```

#### 4. Proxy to Instance A, and load the config and jobtap plugin.
We now have all the information to submit to Instance B,  so we `proxy` to 
Instance A and load the jobtap plugin. 

```
$ flux proxy fmerUPiw 
$ flux resource list
     STATE NNODES NCORES NGPUS NODELIST
      free      2      2     0 tuolumne[1029-1030]
 allocated      0      0     0
      down      0      0     0

$ flux config load config.toml

$ flux config get delegate ## check the config file has been loaded
["ssh://tuolumne1031/var/tmp/namankul/flux-sOzON0/local-0"]

$ flux jobtap load <path-to-plugin>/delegate.so 
```
Here, we note that Instance A has resources `tuolumne[1029,1030]`, and as a result, 
Instance B has resources `tuolumne[1021,1032]` (can be verified similarly). 

#### 5. Submit a job from Instance A to Instance B.
Finally, we submit a job (`-N 2 -n 2 hostname` in our example) 
to Instance B from Instance A. Our output should be `tuolumne[1031,1032]` as we are 
executing on Instance B. We are using random policy for this, but users can select from multiple policies.

```
$  flux submit -N 2 -n 2 -S system.delegate=random hostname
f5WMtyYTH
```

#### 6. View the results of the job.

There are two ways to view the results of the job that was delegated to Instance B.

The first approach works while we are on Instance A. 
Here, we obtain the corresponding Job ID on Instance B using `flux job eventlog`, 
and then using `flux job attach` with `flux proxy`, as shown below. 
Note here that we use `flux proxy --parent` as the ID for
Instance B is associated with the top-level original instance and was created in step 2. 
Our output correctly shows `tuolumne[1031-32]` for Instance B. 

```
$ flux job eventlog f7Qv4KHXM
1782951380.102527 submit userid=63561 urgency=16 flags=0 version=1
1782951382.566925 dependency-add description="delegated"
1782951382.566981 set-flags flags=["alloc-bypass"]
1782951382.567994 validate
1782951382.777669 delegate::submit jobid=10007240245248
1782951382.821055 delegate::start timestamp=1782951382.7901998
1782951382.887310 dependency-remove description="delegated"
1782951382.887330 depend
1782951382.887369 priority priority=16
1782951382.888354 alloc bypass=true
1782951382.893923 start
1782951382.984527 finish status=0
1782951382.986243 release ranks="all" final=true
1782951382.986264 free
1782951382.986273 clean


$ flux job id --to=f58 10007240245248           # Convert the JobID obtained from eventlog to the f58 format
f5XseZ2u5

$ flux --parent proxy fkw8xbpB flux job attach f5XseZ2u5
tuolumne1031
tuolumne1032
```

In the second approach, we can `proxy` to Instance B and examine the results of the job
as shown below.

```
$ flux --parent proxy fkw8xbpB 

$ flux jobs -a
       JOBID USER     NAME       ST NTASKS NNODES     TIME INFO
  f5XseZ2u5 namankul hostname   CD      2      2   0.105s tuolumne[1031-1032]


$ flux job attach f5XseZ2u5
tuolumne1031
tuolumne1032
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

### Example Scripts

The [examples/](examples) directory contains standalone scripts illustrating
delegation policies. See [examples/README.md](examples/README.md) for a full
description of each script.

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
