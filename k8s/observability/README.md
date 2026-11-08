# Observability (T11)

Metrics, dashboards, alerts and logs for the cluster. **Internal only** — no NodePort, no SG
rule; reach Grafana over `port-forward` + SSH tunnel.

| Component | Chart | Version | Footprint |
|---|---|---|---|
| Prometheus + Alertmanager + Grafana + exporters | `kube-prometheus-stack` | `92.17.0` | ~2 Gi RAM, 2.75 Gi PVC |
| Loki (logs) | `grafana/loki` | `7.5.0` | 768 Mi limit, 1 Gi PVC |
| Promtail (log shipper) | `grafana/promtail` | `6.17.1` | ~128 Mi limit, no PVC |

## Install order

1. `kube-prometheus-stack/README.md` — create the `grafana-admin` Secret first, then install
2. `loki/README.md` — install, then apply the datasource ConfigMap
3. `promtail/README.md` — install last

## Why the sizing is not the chart default

The chart defaults (10-day retention, no size cap, 8 Gi Prometheus PVC) do not fit the 10 Gi
data volume shared with five apps. This stack pins:

- Prometheus retention **3d / 1GB**, PVC **2 Gi**
- Alertmanager PVC **256 Mi**
- Grafana PVC **512 Mi**
- Loki **SingleBinary**, 72h retention, PVC **1 Gi**
- Disabled scrapes for etcd/controller-manager/scheduler/kube-proxy (k3s does not expose them)

Total added PVC allocation: **~3.75 Gi**. Actual bytes are bounded by retention; `df -h` is
the truth.

## Done-when (T11)

- Grafana reachable over port-forward, dashboards show live data
- Prometheus `/targets` is mostly UP
- `HomelabAlertPipelineTest` is **firing** in Prometheus + Alertmanager, screenshot captured
- Loki logs visible in Grafana Explore

After the screenshot, remove the demo alert from
`kube-prometheus-stack/values.yaml` and `helm upgrade` so it stops firing.
