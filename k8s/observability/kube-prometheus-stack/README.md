# kube-prometheus-stack — metrics + dashboards + alerts (T11)

| Item | Value |
|---|---|
| Chart | `prometheus-community/kube-prometheus-stack` `92.17.0` (app v0.94.2) |
| Namespace | `observability` |
| Components | Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics, operator |
| Storage | Prometheus 2 Gi · Alertmanager 256 Mi · Grafana 512 Mi (`local-path-retain`) |
| Retention | 3 days / 1 GB cap |
| Access | internal — `port-forward` to Grafana (no public port, ADR-022) |

## Prereqs

```bash
cd ~/cloud-native-homelab
kubectl apply -f k8s/namespaces/

# Grafana admin password — never in git (ADR-015)
kubectl create secret generic grafana-admin -n observability \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='<strong-password>'

df -h /var/lib/rancher/k3s/storage     # this stack adds ~3 Gi of PVCs (allocation)
free -h                                # ~1-2 Gi RAM in use once settled
```

## Install

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n observability --version 92.17.0 \
  -f k8s/observability/kube-prometheus-stack/values.yaml \
  > /tmp/kps-rendered.yaml
# check: 3 PVCs with local-path-retain, retention 3d, no etcd/controller-manager scrape

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n observability --version 92.17.0 \
  -f k8s/observability/kube-prometheus-stack/values.yaml \
  --wait --timeout 15m
```

CRDs are installed by the chart; the first install takes a few minutes.

## Is it working?

```bash
kubectl -n observability get pods
# prometheus-kube-prometheus-stack-prometheus-0   2/2 Running
# alertmanager-kube-prometheus-stack-alertmanager-0 2/2 Running
# kube-prometheus-stack-grafana-xxxx              3/3 Running
# kube-prometheus-stack-operator-xxxx             1/1 Running
# ...-node-exporter-xxxx (DaemonSet), ...-kube-state-metrics

kubectl -n observability get pvc
# prometheus-...-db   2Gi  Bound
# alertmanager-...-db 256Mi Bound
# kube-prometheus-stack-grafana 512Mi Bound
```

Grafana:

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80
# laptop: ssh -L 3000:127.0.0.1:3000 ubuntu@<node>
# browser: http://localhost:3000  (admin + the password from the Secret)
```

Prometheus targets (should be mostly UP):

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# browser: http://localhost:9090/targets
```

## The alert that fires on purpose (T11 done-when)

The values add `HomelabAlertPipelineTest` (`expr: vector(1)`, for 1m). After ~2 minutes:

- Prometheus → **Alerts** → `HomelabAlertPipelineTest` is `firing`
- Alertmanager UI → `kubectl -n observability port-forward svc/kube-prometheus-stack-alertmanager 9093:9093` → the alert is listed
- Grafana → **Alerting** shows it too

Capture that screenshot, then remove the `additionalPrometheusRulesMap` block and `helm upgrade`
so the demo alert doesn't stay in the repo forever.

## Gotchas

- The chart default retention is **10 days with no size cap** — on a 10 Gi volume that fills
  the disk. This file pins 3d/1GB.
- `kubeEtcd`/`kubeControllerManager`/`kubeScheduler`/`kubeProxy` are disabled: k3s does not
  expose them like kubeadm, and their "down" alerts would fire forever.
- Grafana's password comes from the `grafana-admin` Secret; without it the pod will not start.
- No NodePort: observability stays internal (port-forward only).
- Removing the release leaves the PVCs (retain); delete them manually if you want the bytes.
