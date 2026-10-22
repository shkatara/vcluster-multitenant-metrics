#!/usr/bin/env bash
# Verifies the lab end to end and prints the evidence.
# Read-only, apart from short-lived curl pods started inside team-a.
set -uo pipefail
cd "$(dirname "$0")"

CTX="${CTX:-vcluster-docker_obs-host}"
PORT=19090
pass=0
fail=0

ok()  { echo "PASS  $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; fail=$((fail + 1)); }
expect() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1  [$3]"; else bad "$1  [expected: $2 | got: $3]"; fi
}

kubectl --context "$CTX" -n monitoring port-forward svc/kube-prom-kube-prometheus-prometheus "$PORT:9090" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
sleep 3

prom() { curl -s -G "localhost:$PORT/api/v1/query" --data-urlencode "query=$1"; }
label_set() { # label name -> sorted unique values, comma separated
  python3 -c 'import sys,json
r=json.load(sys.stdin)["data"]["result"]
print(",".join(sorted({x["metric"].get(sys.argv[1],"") for x in r})))' "$1"
}
first_value() { python3 -c 'import sys,json
r=json.load(sys.stdin)["data"]["result"]
print(r[0]["value"][1] if r else "none")'; }

echo "== 1. Host view: one scrape, tenant labels on usage (cAdvisor) and requests (KSM)"
usage=$(prom 'container_memory_working_set_bytes{namespace="payments",container="app"}')
reqs=$(prom 'kube_pod_container_resource_requests{namespace="payments",resource="memory"}')
expect "cAdvisor series carry vcluster"       "team-a,team-b,team-c"       "$(echo "$usage" | label_set vcluster)"
expect "cAdvisor series keep host_namespace"  "vc-team-a,vc-team-b,vc-team-c" "$(echo "$usage" | label_set host_namespace)"
expect "KSM series carry vcluster"            "team-a,team-b,team-c"       "$(echo "$reqs" | label_set vcluster)"
expect "KSM series keep host_namespace"       "vc-team-a,vc-team-b,vc-team-c" "$(echo "$reqs" | label_set host_namespace)"
echo "$usage" | python3 -c 'import sys,json
for r in json.load(sys.stdin)["data"]["result"]:
    m=r["metric"]; print("      ", {k:m.get(k) for k in ("pod","namespace","vcluster","host_pod","host_namespace")})'

echo
echo "== 2. Requested vs used per tenant"
expect "ratio exists for all three tenants" "3" "$(prom 'count(vcluster:pod_memory_usage_over_request:ratio{namespace="payments"})' | first_value)"
prom 'vcluster:pod_memory_usage_over_request:ratio{namespace="payments"}' | python3 -c 'import sys,json
for r in sorted(json.load(sys.stdin)["data"]["result"], key=lambda r:r["metric"]["vcluster"]):
    print("       %s %-34s usage/request = %.2f" % (r["metric"]["vcluster"], r["metric"]["pod"], float(r["value"][1])))'

echo
echo "== 3. Isolation: attacks from a pod inside team-a"
probe=$(mktemp)
cat > "$probe" <<'EOF'
U=http://tenant-metrics.default.svc:8080
Q='container_memory_working_set_bytes{namespace="payments",container="app"}'
vc() { grep -o '"vcluster":"[^"]*"' | sort -u | tr '\n' ' '; }
echo "normal=$(curl -s -G $U/api/v1/query --data-urlencode "query=$Q" | vc)"
echo "matcher_code=$(curl -s -o /dev/null -w '%{http_code}' -G $U/api/v1/query --data-urlencode 'query=container_memory_working_set_bytes{vcluster="team-b"}')"
echo "param=$(curl -s -G $U/api/v1/query --data-urlencode "query=$Q" --data-urlencode 'vcluster=team-b' | vc)"
echo "header=$(curl -s -H 'X-Vcluster: team-b' -G $U/api/v1/query --data-urlencode "query=$Q" | vc)"
echo "series_b=$(curl -s -G $U/api/v1/series --data-urlencode 'match[]={vcluster="team-b"}')"
echo "labels=$(curl -s $U/api/v1/label/vcluster/values)"
echo "config_code=$(curl -s -o /dev/null -w '%{http_code}' $U/api/v1/status/config)"
echo "admin_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$U/api/v1/admin/tsdb/delete_series?match[]={vcluster=\"team-a\"}")"
echo "federate_b_bytes=$(curl -s -G $U/federate --data-urlencode 'match[]={vcluster="team-b"}' | wc -c | tr -d ' ')"
EOF
out=$(vcluster connect team-a -n vc-team-a --driver helm --context "$CTX" -- \
  kubectl run verify-probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 --command -- sh -c "$(cat "$probe")" 2>&1 \
  | grep -E '^[a-z_]+=' || true)
rm -f "$probe"
get() { echo "$out" | grep "^$1=" | head -1 | cut -d= -f2-; }
expect "plain query returns only team-a"            '"vcluster":"team-a" ' "$(get normal)"
expect "matcher vcluster=\"team-b\" is rejected"      "400"                  "$(get matcher_code)"
expect "?vcluster=team-b parameter is ignored"      '"vcluster":"team-a" ' "$(get param)"
expect "X-Vcluster: team-b header is ignored"       '"vcluster":"team-a" ' "$(get header)"
expect "series API for team-b is empty"             '{"status":"success","data":[]}' "$(get series_b)"
expect "label values only list team-a"              '{"status":"success","data":["team-a"]}' "$(get labels)"
expect "config endpoint is blocked"                 "404"                  "$(get config_code)"
expect "admin API is blocked"                       "404"                  "$(get admin_code)"
expect "federate for team-b returns nothing"        "0"                    "$(get federate_b_bytes)"

echo
echo "== 4. Alerts reach only the owning team"
expect "alert firing for team-a only" "team-a" \
  "$(prom 'ALERTS{alertname="TenantPodMemoryAboveRequest",alertstate="firing"}' | label_set vcluster)"
expect "alert sink received team-a only" '"path": "/team-a"' \
  "$(kubectl --context "$CTX" -n monitoring logs deploy/alert-sink --tail=5000 2>/dev/null | grep -o '"path": "/team-[a-c]"' | sort -u | tr '\n' ' ' | sed 's/ $//')"

echo
echo "== 5. Hashed pod name (host name over 63 characters)"
expect "hashed pod is visible to team-a" "1" \
  "$(prom 'count(container_memory_working_set_bytes{vcluster="team-a",pod=~"reconciliation.*",container="app"})' | first_value)"
prom 'container_memory_working_set_bytes{pod=~"reconciliation.*",container="app",vcluster="team-a"}' | python3 -c 'import sys,json
for r in json.load(sys.stdin)["data"]["result"]:
    m=r["metric"]; print("      ", {k:m.get(k) for k in ("pod","namespace","vcluster","host_pod")}, "(pod and namespace stay host names, no host_pod)")'

echo
echo "== 6. Grafana inside each tenant only sees that tenant"
gprobe='G=http://admin:admin@grafana.grafana.svc:3000
P=$G/api/datasources/proxy/uid/tenant-prom/api/v1
echo "health=$(curl -s $G/api/datasources/uid/tenant-prom/health | grep -o "\"status\":\"[A-Z]*\"")"
echo "tenants=$(curl -s $P/label/vcluster/values)"
echo "dashboard=$(curl -s -o /dev/null -w "%{http_code}" $G/api/dashboards/uid/tenant-resources)"'
for t in team-a team-b team-c; do
  gout=$(vcluster connect "$t" -n "vc-$t" --driver helm --context "$CTX" -- \
    kubectl run "verify-grafana" --rm -i --restart=Never --image=curlimages/curl:8.11.1 --command -- sh -c "$gprobe" 2>&1 \
    | grep -E '^[a-z_]+=' || true)
  gget() { echo "$gout" | grep "^$1=" | head -1 | cut -d= -f2-; }
  expect "$t Grafana datasource is healthy"       '"status":"OK"'                           "$(gget health)"
  expect "$t Grafana lists only its own tenant"   "{\"status\":\"success\",\"data\":[\"$t\"]}" "$(gget tenants)"
  expect "$t dashboard is provisioned"            "200"                                      "$(gget dashboard)"
done

echo
echo "== 7. Sync: the tenant's objects as the host sees them"
sync_out=$(vcluster connect team-a -n vc-team-a --driver helm --context "$CTX" -- sh -c '
  echo "tpod=$(kubectl get pods -n payments -l app=checkout-api -o name | sed s,pod/,,)"
  echo "tdeploy=$(kubectl get deploy -n payments checkout-api -o name)"
  echo "tsvcip=$(kubectl get svc -n grafana grafana -o jsonpath={.spec.clusterIP})"
  echo "tver=$(kubectl version -o json | python3 -c "import sys,json;print(json.load(sys.stdin)[\"serverVersion\"][\"gitVersion\"])" 2>/dev/null)"' 2>&1 | grep -E '^t[a-z]+=' || true)
sget() { echo "$sync_out" | grep "^$1=" | head -1 | cut -d= -f2-; }
tpod=$(sget tpod)
hpod=$(kubectl --context "$CTX" -n vc-team-a get pods -o name | sed 's,pod/,,' | grep -- '-x-payments-x-team-a$' | grep '^checkout-api' | head -1)
expect "tenant sees the Deployment"                    "deployment.apps/checkout-api" "$(sget tdeploy)"
expect "host has no Deployment for tenant workloads"   "0"  "$(kubectl --context "$CTX" -n vc-team-a get deploy -o name 2>/dev/null | wc -l | tr -d ' ')"
expect "host pod name is <pod>-x-payments-x-team-a"    "${tpod}-x-payments-x-team-a" "$hpod"
expect "tenant Service ClusterIP equals the host copy" "$(sget tsvcip)" \
  "$(kubectl --context "$CTX" -n vc-team-a get svc grafana-x-grafana-x-team-a -o jsonpath='{.spec.clusterIP}')"
hver=$(kubectl --context "$CTX" version -o json | python3 -c 'import sys,json;print(json.load(sys.stdin)["serverVersion"]["gitVersion"])')
# The versions differ today (the tenant runs the vCluster default). The check only requires that both
# are reported, so it keeps passing if the defaults ever line up.
if [ -n "$(sget tver)" ] && [ -n "$hver" ]; then ok "tenant and host Kubernetes versions are reported  [tenant $(sget tver) | host $hver]"; else bad "version check  [tenant: $(sget tver) | host: $hver]"; fi

echo
echo "Result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
