#!/usr/bin/env bash
set -euo pipefail


# # How many child clusters to create (default 2 if not set)
# NUM_CLUSTERS="${NUM_CLUSTERS:-2}"
# if ! [[ "$NUM_CLUSTERS" =~ ^[0-9]+$ ]] || [ "$NUM_CLUSTERS" -lt 1 ]; then
#   echo "NUM_CLUSTERS must be a positive integer"; exit 1
# fi

echo "[setup] You are inside the TOP instance (proxied shell)."
echo "[setup] Creating $NUM_CLUSTERS child nested instances (N=$CLUSTER_NODES each)…"

# Labels: A..Z, then 27+ get numeric suffixes (job27, job28, …)
letters=( {A..Z} )

JOB_LABELS=()
JOB_IDS=()
URIS=()

for i in $(seq 1 "$NUM_CLUSTERS"); do
  if [ "$i" -le "${#letters[@]}" ]; then
    label="${letters[$((i-1))]}"
  else
    label="$i"
  fi

  echo "[setup] Submitting job${label}…"
  jobid="$(flux submit -N"$CLUSTER_NODES" flux start sleep inf | tail -n1)"
  echo "[setup] job${label}: $jobid"

  echo "[setup] Fetching URI for job${label}…"
  #uri="$(flux proxy "$jobid" flux getattr local-uri | tr -d '[:space:]')"
  uri="$(flux uri "$jobid" | tr -d '[:space:]')"
  echo "[setup] job${label}_uri: $uri"

  JOB_LABELS+=("$label")
  JOB_IDS+=("$jobid")
  URIS+=("$uri")
done

echo "[setup] Writing clusters.json to: ${CLUSTERS_JSON}"
{
  echo '{'
  echo '  "clusters": ['
  for idx in "${!URIS[@]}"; do
    sep=$([ "$idx" -lt $(( ${#URIS[@]} - 1 )) ] && echo "," || echo "")
    printf '    "%s"%s\n' "${URIS[$idx]}" "$sep"
  done
  echo '  ]'
  echo '}'
} > "$CLUSTERS_JSON"

echo "[setup] Loading jobtap plugin:"
echo "        $PLUGIN_PATH"
flux jobtap load "$PLUGIN_PATH" config="$CLUSTERS_JSON"

echo
echo "[setup] Summary:"
for idx in "${!JOB_LABELS[@]}"; do
  printf "  job%-4s id=%-20s uri=%s\n" "${JOB_LABELS[$idx]}" "${JOB_IDS[$idx]}" "${URIS[$idx]}"
done
echo
echo "[setup] Done. clusters.json has ${#URIS[@]} entries."
echo " To exit the TOP instance shell, type:  exit"
