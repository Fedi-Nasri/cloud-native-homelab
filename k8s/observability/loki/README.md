# Loki — logs (optional, after metrics)

| Item | Value |
|---|---|
| Chart | `grafana/loki` `7.5.0` (app 3.6.16) |
| Namespace | `observability` |
| Mode | `SingleBinary` + filesystem storage (one pod) |
| Storage | `/var/loki` 1 Gi PVC (`local-path-retain`) |
| Retention | 72 hours |
| Access | internal only (`ClusterIP`) |

## Install (after kube-prometheus-stack)

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm template loki grafana/loki -n observability --version 7.5.0 \
  -f k8s/observability/loki/values.yaml > /tmp/loki-rendered.yaml
# check: deploymentMode SingleBinary, 1Gi PVC local-path-retain, no gateway/memcached/canary

helm upgrade --install loki grafana/loki -n observability --version 7.5.0 \
  -f k8s/observability/loki/values.yaml --wait --timeout 10m

# register it as a Grafana datasource (sidecar picks this up automatically)
kubectl apply -f k8s/observability/loki/datasource-configmap.yaml
```

## Is it working?

```bash
kubectl -n observability get pods,pvc | grep loki
# loki-0  1/1 Running · storage-loki-0  1Gi Bound

kubectl -n observability logs loki-0 --tail=40 | grep -i "starting\|ready"
```

Then in Grafana: **Connections → Data sources → Loki** exists (grey/green "working"), and
**Explore → Loki → `{namespace="observability"}`** returns log lines.

```bash
# quick API check from the node
kubectl -n observability port-forward svc/loki 3100:3100
curl -s http://localhost:3100/ready     # ready
```

## Gotchas

- Chart defaults are **SimpleScalable** and enable gateway + memcached + canary = ~8 pods.
  All disabled here; `SingleBinary` is the only sane mode on one node.
- `auth_enabled: false` — no tenant header needed. Do not rest this on the internet.
- Filesystem storage means logs live on the 1 Gi PVC; 72h retention keeps it bounded.
- Without the datasource ConfigMap, Loki runs but Grafana shows no Loki source.

## Teardown

```bash
helm uninstall loki -n observability
kubectl delete -f k8s/observability/loki/datasource-configmap.yaml
# PVCs are retained: kubectl -n observability delete pvc storage-loki-0
```
