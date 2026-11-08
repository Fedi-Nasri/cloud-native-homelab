# Promtail — log shipper

| Item | Value |
|---|---|
| Chart | `grafana/promtail` `6.17.1` (app 3.5.1) |
| Namespace | `observability` |
| Mode | DaemonSet (one pod on the single node) |
| Target | `http://loki.observability.svc.cluster.local:3100/loki/api/v1/push` |
| Storage | none (reads `/var/log` from the host) |

## Install (after Loki)

```bash
helm template promtail grafana/promtail -n observability --version 6.17.1 \
  -f k8s/observability/promtail/values.yaml > /tmp/promtail-rendered.yaml

helm upgrade --install promtail grafana/promtail -n observability --version 6.17.1 \
  -f k8s/observability/promtail/values.yaml --wait --timeout 5m
```

## Is it working?

```bash
kubectl -n observability get pods -l app.kubernetes.io/name=promtail
# 1/1 Running

kubectl -n observability logs -l app.kubernetes.io/name=promtail --tail=20
# no "connection refused"; it should mention the Loki client
```

Then in Grafana → **Explore → Loki**:

```logql
{namespace="observability"}          # promtail's own logs
{app="kube-prometheus-stack"}        # scrape noise from the monitoring namespace
```

If Explore is empty, check the client URL first (`loki` service, port 3100), then Loki's
`/ready` endpoint.

## Gotchas

- Promtail needs RBAC to read pods/logs; the chart creates it by default.
- The Loki gateway is disabled, so the URL must hit `loki:3100` directly — the chart's default
  points at `loki-gateway`, which does not exist here.
- On one node this is a DaemonSet with exactly one pod; no scheduling changes needed.
