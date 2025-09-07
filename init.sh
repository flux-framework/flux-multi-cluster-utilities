#!/usr/bin/env bash
set -euo pipefail

# How many hosts for each nested Flux instance
TOTAL_NODES=2
TOP_NODES=2
cluster_nodes=1
num_clusters=2

# Paths (absolute is safest if FS differs; these default to current dir)
base_dir=$PWD
plugin_path="$base_dir/install/lib/flux/job-manager/plugins/select_and_delegate.so"
# config_path="${CONFIG_PATH:-$base_dir/config.json}"   # not used directly below but kept for compatibility
clusters_json="$base_dir/clusters.json"

#. ~/.bashrc_tuo_flux

# # Where to persist IDs/URIs
# STATE_DIR="${STATE_DIR:-$BASE_DIR/.state}"
# mkdir -p "$STATE_DIR"
# TOP_JOB_FILE="$STATE_DIR/top.jobid"

jobA="$(flux submit -N"$TOP_NODES" flux start sleep inf | tail -n1)"


# Drop into the proxied shell (interactive).
# When you exit this shell, control returns here.
PLUGIN_PATH=$plugin_path CLUSTERS_JSON=$clusters_json CLUSTER_NODES=${cluster_nodes} NUM_CLUSTERS=${num_clusters} flux proxy "$jobA"

echo
echo "[init] Exited TOP instance shell."
echo "If you want to stop the TOP job later: flux cancel \"$(cat "$TOP_JOB_FILE")\""
