#!/usr/bin/env bash
# Removes the lab completely: all tenant vClusters and the host cluster.
set -uo pipefail

HOST=obs-host
CTX="vcluster-docker_${HOST}"

for t in team-a team-b team-c; do
  vcluster delete "$t" -n "vc-$t" --driver helm --context "$CTX" 2>/dev/null || true
done
vcluster delete "$HOST" --driver docker || true
echo "Lab removed. Switch back to your own kube context with: vcluster disconnect"
