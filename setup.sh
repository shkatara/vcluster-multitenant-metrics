#!/usr/bin/env bash
# Builds the single-scrape multi-tenant metrics lab. Safe to re-run.
#
# Prerequisites: docker, vcluster CLI >= 0.36, helm, kubectl, python3
# Pinned: kube-prometheus-stack 92.9.0, prom-label-proxy v0.11.0, Grafana 12.0.2, vCluster k8s v1.35.0
set -euo pipefail
cd "$(dirname "$0")"

HOST=obs-host
CTX="vcluster-docker_${HOST}"
KPS_VERSION=92.9.0
TENANTS=(team-a team-b team-c)

# tenant -> workload name and memory request (team-a is deliberately under-requested
# so the "usage above request" alert fires for it and only for it)
# (plain case statement instead of associative arrays, macOS ships bash 3.2)
app_for() { case "$1" in team-a) echo checkout-api;; team-b) echo fraud-engine;; team-c) echo ledger-api;; esac; }
mem_for() { case "$1" in team-a) echo 3Mi;; team-b) echo 64Mi;; team-c) echo 32Mi;; esac; }

log() { printf '\n==> %s\n' "$*"; }
k() { kubectl --context "$CTX" "$@"; }
in_tenant() { local t=$1; shift; vcluster connect "$t" -n "vc-$t" --driver helm --context "$CTX" -- "$@"; }

node_ip() { k get node "$1" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'; }
container_ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "vcluster.node.${HOST}.$1"; }

# After a Docker restart the worker containers can come back with swapped IPs, which makes
# kubectl exec and port-forward fail on the workers. Restarting them in order restores the IPs.
fix_worker_ips() {
  local mismatch=0
  for n in worker-1 worker-2; do
    [ "$(node_ip "$n")" = "$(container_ip "$n")" ] || mismatch=1
  done
  if [ "$mismatch" = 1 ]; then
    log "Worker IPs changed after restart, restarting workers in order"
    docker stop "vcluster.node.${HOST}.worker-2" "vcluster.node.${HOST}.worker-1" >/dev/null
    docker start "vcluster.node.${HOST}.worker-1" >/dev/null
    sleep 3
    docker start "vcluster.node.${HOST}.worker-2" >/dev/null
    k wait --for=condition=Ready node --all --timeout=180s
  fi
}

ensure_host() {
  log "Host cluster ${HOST}"
  if vcluster list --driver docker 2>/dev/null | grep -q "${HOST}"; then
    if vcluster list --driver docker 2>/dev/null | grep "${HOST}" | grep -q exited; then
      vcluster resume "${HOST}" --driver docker
    fi
  else
    vcluster create "${HOST}" --driver docker -f vcluster.yaml
  fi
  until k get nodes >/dev/null 2>&1; do sleep 3; done
  k wait --for=condition=Ready node --all --timeout=180s
  fix_worker_ips
}

install_monitoring() {
  log "kube-prometheus-stack ${KPS_VERSION}"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update prometheus-community >/dev/null
  k create namespace monitoring --dry-run=client -o yaml | k apply -f - >/dev/null
  # The alert sink must exist before Alertmanager is configured to call it
  k apply -f rules/alert-sink.yaml
  helm upgrade --install kube-prom prometheus-community/kube-prometheus-stack \
    --version "${KPS_VERSION}" --kube-context "${CTX}" -n monitoring \
    -f prom-values.yaml --wait --timeout 8m
  k apply -f rules/tenant-rules.yaml
}

# Platform Grafana on the host. Its datasource is the host Prometheus, so it sees every tenant.
install_host_grafana() {
  log "Platform Grafana on the host"
  k -n monitoring create configmap grafana-host-dashboards \
    --from-file=dashboards/platform-all-tenants.json --dry-run=client -o yaml | k apply -f -
  k apply -f grafana-host.yaml
  k -n monitoring rollout status deploy/grafana-host --timeout=180s
}

# Grafana inside the tenant vCluster. Its only datasource is the tenant's locked endpoint.
install_grafana() {
  local t=$1 tmp
  in_tenant "$t" kubectl apply -f "$PWD/grafana.yaml.tpl"
  tmp=$(mktemp)
  k -n grafana create configmap grafana-dashboards \
    --from-file=dashboards/tenant-resources.json --dry-run=client -o yaml > "${tmp}"
  in_tenant "$t" kubectl apply -f "${tmp}"
  rm -f "${tmp}"
  # Wait for the image pull, so verify.sh does not race a cold start
  in_tenant "$t" kubectl -n grafana rollout status deploy/grafana --timeout=300s
}

create_tenants() {
  log "Per-tenant label proxies"
  k apply -f proxy/

  for t in "${TENANTS[@]}"; do
    log "vCluster ${t}"
    vcluster create "${t}" -n "vc-${t}" --driver helm --context "${CTX}" \
      -f "tenants/vcluster-${t}.yaml" --upgrade --connect=false
    k -n "vc-${t}" wait --for=condition=Ready "pod/${t}-0" --timeout=300s

    tmp=$(mktemp)
    sed "s/__NAME__/$(app_for "$t")/g;s/__MEM__/$(mem_for "$t")/g" workloads.yaml.tpl > "${tmp}"
    in_tenant "${t}" kubectl apply -f "${tmp}"
    rm -f "${tmp}"
    in_tenant "${t}" kubectl -n payments rollout status "deploy/$(app_for "$t")" --timeout=300s

    install_grafana "${t}"
  done

  log "Long-name pod in team-a (host name gets hashed)"
  in_tenant team-a kubectl apply -f "$PWD/long-name-pod.yaml"
}

ensure_host
install_monitoring
install_host_grafana
create_tenants

log "Done. Give Prometheus about four minutes to scrape and fire the alert, then run ./verify.sh"
