#!/usr/bin/env bash
# Shows the same tenant through two lenses: inside the vCluster, and on the host.
# Read-only. Usage: ./showsync.sh [tenant]   (default: team-a)
set -uo pipefail

T="${1:-team-a}"
CTX="${CTX:-vcluster-docker_obs-host}"
NS="vc-$T"
in_tenant() { vcluster connect "$T" -n "$NS" --driver helm --context "$CTX" -- "$@" 2>&1 | grep -v -E 'vCluster|Switched|done|newer version'; }
host() { kubectl --context "$CTX" -n "$NS" "$@"; }

echo "== Inside $T: pods"
in_tenant kubectl get pods -A
echo
echo "== On the host, namespace $NS: pods"
host get pods -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName
echo
echo "== Inside $T: deployments"
in_tenant kubectl get deploy -A
echo
echo "== On the host, namespace $NS: deployments (tenant workloads are not here)"
host get deploy 2>&1
echo
echo "== Labels the syncer stamps on a host pod"
host get pods -l vcluster.loft.sh/managed-by="$T" -o json | python3 -c 'import sys,json
m=json.load(sys.stdin)["items"][0]["metadata"]
print(m["name"]); p=m["labels"]
for k in sorted(p):
    if k.startswith("vcluster.loft.sh/") and "ns-label" not in k: print("  %s=%s" % (k, p[k]))'
echo
echo "== Kubernetes version: inside $T vs host"
echo "inside: $(in_tenant kubectl version | grep -i server)"
echo "host:   $(kubectl --context "$CTX" version | grep -i server)"
