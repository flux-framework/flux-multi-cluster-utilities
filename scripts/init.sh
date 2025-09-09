#!/usr/bin/env bash
set -euo pipefail

# How many hosts for each nested Flux instance
TOTAL_NODES=3
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

echo "[setup] Initializing clusters."
echo "[setup] Submitting jobA…"

jobA="$(flux submit -N"$cluster_nodes" flux start sleep inf | tail -n1)"
echo "[setup] jobA: $jobA"

letters=( {B..Z} )
JOB_LABELS=()
JOB_IDS=()
URIS=()

for i in $(seq 1 "$num_clusters"); do
  if [ "$i" -le "${#letters[@]}" ]; then
    label="${letters[$((i-1))]}"
  else
    label="$i"
  fi

  echo "[setup] Submitting job${label}…"
  jobid="$(flux submit -N"$cluster_nodes" flux start sleep inf | tail -n1)"
  echo "[setup] job${label}: $jobid"

  echo "[setup] Fetching URI for job${label}…"
  #uri="$(flux proxy "$jobid" flux getattr local-uri | tr -d '[:space:]')"
  uri="$(flux uri "$jobid" | tr -d '[:space:]')"
  echo "[setup] job${label}_uri: $uri"

  JOB_LABELS+=("$label")
  JOB_IDS+=("$jobid")
  URIS+=("$uri")
done

echo "[setup] Writing clusters.json to: ${clusters_json}"
{
  echo '{'
  echo '  "clusters": ['
  for idx in "${!URIS[@]}"; do
    sep=$([ "$idx" -lt $(( ${#URIS[@]} - 1 )) ] && echo "," || echo "")
    printf '    "%s"%s\n' "${URIS[$idx]}" "$sep"
  done
  echo '  ]'
  echo '}'
} > "$clusters_json"

echo
echo "[setup] Summary:"
for idx in "${!JOB_LABELS[@]}"; do
  printf "  job%-4s id=%-20s uri=%s\n" "${JOB_LABELS[$idx]}" "${JOB_IDS[$idx]}" "${URIS[$idx]}"
done
echo
echo "[setup] Done. clusters.json has ${#URIS[@]} entries."
echo " To exit the TOP instance shell, type:  exit"


# Drop into the proxied shell (interactive).
# When you exit this shell, control returns here.
PLUGIN_PATH=$plugin_path CLUSTERS_JSON=$clusters_json CLUSTER_NODES=${cluster_nodes} NUM_CLUSTERS=${num_clusters} flux proxy "$jobA" "bash reload_jobtap.sh"

echo "[setup] Now proxying into jobA: $jobA."

PLUGIN_PATH=$plugin_path CLUSTERS_JSON=$clusters_json CLUSTER_NODES=${cluster_nodes} NUM_CLUSTERS=${num_clusters} flux proxy "$jobA" 
