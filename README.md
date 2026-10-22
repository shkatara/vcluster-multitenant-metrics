# Single-scrape multi-tenant metrics for vCluster

One Prometheus on the host cluster scrapes everything once. Each vCluster tenant gets its own
read-only, locked PromQL endpoint inside the vCluster, sees only its own series, can compare
requested vs used resources, and gets alerts routed to the right team.

This is the companion repo for the blog post in `BLOG.md`.

## What you get

```text
kubelet cAdvisor + kube-state-metrics
        |  scrape once, relabel <pod>-x-<ns>-x-<vcluster> into pod / namespace / vcluster
        v
   Prometheus (host) ---- alert rules ----> Alertmanager ---- route by vcluster ----> webhook per team
        ^
        |  read-only, tenant value fixed with --label-value
   prom-proxy-team-a / -b / -c   ==>  appears inside each vCluster as default/tenant-metrics
```

## Prerequisites

| Tool | Tested with |
|---|---|
| docker | 29.4.0 |
| vcluster CLI | 0.36.1 |
| helm | 4.2.0 |
| kubectl | 1.35.0 |
| python3 | 3.13 (used by `verify.sh` for JSON parsing) |

Pinned in the lab: kube-prometheus-stack chart 92.9.0, prom-label-proxy v0.11.0, nginx 1.29-alpine,
curl 8.11.1, Grafana 12.0.2, Kubernetes v1.35.0 on the host (tenant vClusters run v1.36.0, the vCluster default).

## Quick start

```bash
./setup.sh      # builds the lab, safe to re-run
./verify.sh     # run it about four minutes after setup, so Prometheus has scraped and the alert has fired
./showsync.sh   # prints one tenant inside and on the host (read-only), e.g. ./showsync.sh team-b
./cleanup.sh    # removes everything
```

`setup.sh` creates a host cluster named `obs-host` (vCluster docker driver, 1 control plane and
2 workers), installs the monitoring stack and a platform Grafana on the host, creates three tenant vClusters
(`team-a`, `team-b`, `team-c`) and deploys one workload and a Grafana in each. Every command uses the explicit kube context
`vcluster-docker_obs-host`, so it never touches your other clusters.

## Files

| File | Purpose |
|---|---|
| `vcluster.yaml` | Host cluster config (docker driver, 2 workers, flannel) |
| `prom-values.yaml` | kube-prometheus-stack values: relabel rules for cAdvisor and KSM, Alertmanager routes |
| `proxy/team-*.yaml` | One prom-label-proxy per tenant with a fixed `--label-value` |
| `tenants/vcluster-team-*.yaml` | Tenant config: replicates the host proxy in as `default/tenant-metrics` |
| `workloads.yaml.tpl` | Sample workload, rendered per tenant by `setup.sh` |
| `long-name-pod.yaml` | Pod whose host name is hashed, to show the relabeling limit |
| `grafana.yaml.tpl`, `dashboards/tenant-resources.json` | Grafana deployed inside each tenant, with the tenant endpoint as its only datasource |
| `grafana-host.yaml`, `dashboards/platform-all-tenants.json` | Platform Grafana on the host, its datasource is the host Prometheus so it sees every tenant |
| `showsync.sh` | Read-only: the same tenant seen from inside the vCluster and from the host |
| `rules/tenant-rules.yaml` | Requested-vs-used recording rules and the per-tenant alert |
| `rules/alert-sink.yaml` | Tiny webhook echo server that shows which team got which alert |

## Try it by hand

Prometheus as a platform engineer:

```bash
kubectl --context vcluster-docker_obs-host -n monitoring port-forward svc/kube-prom-kube-prometheus-prometheus 9090:9090
# open http://localhost:9090 and run
#   vcluster:pod_memory_usage_over_request:ratio{namespace="payments"}
```

The same data as a tenant, from inside team-a:

```bash
vcluster connect team-a -n vc-team-a --driver helm --context vcluster-docker_obs-host -- \
  kubectl run curl --rm -i --restart=Never --image=curlimages/curl:8.11.1 --command -- \
  curl -sG http://tenant-metrics.default.svc:8080/api/v1/query \
  --data-urlencode 'query=container_memory_working_set_bytes{namespace="payments"}'
```

The platform view, all tenants in one Grafana on the host (platform engineers only):

```bash
kubectl --context vcluster-docker_obs-host -n monitoring port-forward svc/grafana-host 3000:3000
# open http://localhost:3000, user admin, password admin, dashboard "All Tenants (platform view)"
```

## Known limits

- Pods whose host name is shortened by vCluster (over 63 characters) keep their host `pod` and
  `namespace` labels and get no `host_*` labels. The tenant label comes from the `vc-<name>` host
  namespace convention, so tenants must run in a namespace named `vc-<tenant>`.
- After a Docker restart the worker containers can come back with swapped IPs and
  `kubectl exec` fails on the workers. `setup.sh` detects and repairs this.
- One shared Prometheus is a single point of failure with local retention. See the last section of
  the blog for when to move to an agent plus central storage.
