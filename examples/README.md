# Example Scripts

This directory contains standalone scripts that demonstrate the delegation
policies supported by the `delegate.so` jobtap plugin. Each script sets up a
self-contained multi-instance Flux environment and exercises a specific
delegation workflow.

## assign-delegation-3instances.sh

Sets up a 4-node allocation in pdebug partition and launches one source 
Flux instance on a single node alongside three target Flux instances 
on the remaining nodes. It then demonstrates the **`assign`** delegation policy 
by submitting a job from the source instance that is deterministically routed 
to a specific target instance by index.

Key steps performed by the script:

1. Allocates 4 nodes and starts a 1-node source Flux instance.
2. Starts 1-node target Flux instances each of the remaining nodes.
3. Loads the delegate configuration with a list of remote target URIs and the
   `delegate.so` plugin into the source Flux instance.
4. Submits a job using `--dependency=delegate:assign:2` to target the third
   entry (index 2) in the delegation list.
5. Verifies that the delegated job landed on the expected target instance.


Run it from the source root as:

```bash
bash examples/assign-delegation-3instances.sh
```
