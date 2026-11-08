# Kubernetes

Everything that runs inside the cluster. One folder per deployable unit.

## Layout

```
k8s/
├── README.md                  conventions, chart versions, apply order
├── namespaces/
│   └── namespaces.yaml        one namespace per app + observability + platform
├── platform/
│   └── storageclass.yaml      local-path-retain (ADR: retain on delete)
├── apps/
│   ├── jellyfin/              Helm: PVCs, probes, public NodePort 30096
│   ├── nextcloud/             Helm: SQLite + cron, public NodePort 30080
│   ├── navidrome/             Helm: bjw-s common library, two PVCs, public 30081
│   ├── n8n/                   Helm: SQLite state + pinned extra Service, public 30079
│   └── openwebui/             Helm: chat UI, public NodePort 30078 (no model key yet)
└── observability/             T11, internal only (port-forward)
    ├── kube-prometheus-stack/ Prometheus + Alertmanager + Grafana, downsized
    ├── loki/                  Loki SingleBinary + Grafana datasource ConfigMap
    └── promtail/              log shipper to Loki
```

`apps/<app>/` holds **only what you own**: `values.yaml` plus a README. Charts are pulled from
upstream repositories at install time; nothing is vendored here.

> **Capacity is the real constraint.** Five running apps allocate ~11.5 Gi of PVCs on a
> 10 Gi volume; `local-path` does not preallocate, so real bytes decide. Each README states
> its footprint.

## Apply order

```bash
kubectl apply -f k8s/namespaces/
kubectl apply -f k8s/platform/

helm template jellyfin jellyfin/jellyfin -n jellyfin --version 3.7.0 \
  -f k8s/apps/jellyfin/values.yaml > /tmp/jellyfin-rendered.yaml

helm upgrade --install jellyfin jellyfin/jellyfin -n jellyfin --version 3.7.0 \
  -f k8s/apps/jellyfin/values.yaml

kubectl -n jellyfin get pods,pvc,svc -o wide
kubectl -n jellyfin port-forward svc/jellyfin 8096:8096
```

1. **namespaces** — must exist before any namespaced object.
2. **platform** — StorageClass and other cluster-level plumbing.
3. **apps** — one Helm release (or one raw-manifest directory) per folder.
4. **observability** — last, because it costs RAM.

## Run every app (order + commands)

One at a time. Verify before starting the next. The prepared set does **not** fit at once —
see the capacity note above. Install order, cheapest-to-verify first:

### Once

```bash
kubectl apply -f k8s/namespaces/
helm repo add jellyfin https://jellyfin.github.io/jellyfin-helm
helm repo add nextcloud https://nextcloud.github.io/helm/
helm repo add djjudas21 https://djjudas21.github.io/charts
helm repo add community-charts https://community-charts.github.io/helm-charts
helm repo add open-webui https://helm.openwebui.com
helm repo update
```

### 1. Nextcloud — 5 Gi

```bash
cp k8s/apps/nextcloud/values.local.example.yaml k8s/apps/nextcloud/values.local.yaml
# fill public IP + password, then:
helm upgrade --install nextcloud nextcloud/nextcloud -n nextcloud --version 9.4.1 \
  -f k8s/apps/nextcloud/values.yaml -f k8s/apps/nextcloud/values.local.yaml \
  --wait --timeout 10m
kubectl -n nextcloud get pods,pvc,svc,cronjob
```

### 2. Navidrome — 1.5 Gi

```bash
helm upgrade --install navidrome djjudas21/navidrome -n navidrome --version 6.8.7 \
  -f k8s/apps/navidrome/values.yaml --wait --timeout 5m
kubectl -n navidrome get pods,pvc,svc
```

### 3. n8n — 1 Gi (public 30079)

```bash
cp k8s/apps/n8n/values.local.example.yaml k8s/apps/n8n/values.local.yaml
# fill WEBHOOK_URL: "http://<public-ip>:30079/"
helm upgrade --install n8n community-charts/n8n -n n8n --version 1.24.43 \
  -f k8s/apps/n8n/values.yaml -f k8s/apps/n8n/values.local.yaml \
  --wait --timeout 5m
kubectl apply -f k8s/apps/n8n/nodeport-service.yaml   # pins 30079 (chart cannot)
kubectl -n n8n get pods,pvc,svc
```

### 4. Open WebUI — 1 Gi (public 30078, no model key yet)

```bash
helm upgrade --install open-webui open-webui/open-webui -n openwebui --version 17.4.0 \
  -f k8s/apps/openwebui/values.yaml --wait --timeout 5m
kubectl -n openwebui get pods,pvc,svc
# create the admin over port-forward BEFORE opening the SG rule
```

Each app's README has the full verify / persistence / backup steps.

### 5. Observability — T11, internal

```bash
kubectl create secret generic grafana-admin -n observability \
  --from-literal=admin-user=admin --from-literal=admin-password='<strong-password>'

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# 1) metrics + dashboards + alerts
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n observability --version 92.17.0 \
  -f k8s/observability/kube-prometheus-stack/values.yaml --wait --timeout 15m

# 2) logs
helm upgrade --install loki grafana/loki -n observability --version 7.5.0 \
  -f k8s/observability/loki/values.yaml --wait --timeout 10m
kubectl apply -f k8s/observability/loki/datasource-configmap.yaml

# 3) log shipper
helm upgrade --install promtail grafana/promtail -n observability --version 6.17.1 \
  -f k8s/observability/promtail/values.yaml --wait --timeout 5m

kubectl -n observability get pods,pvc
```

Details and the alert test: `k8s/observability/README.md`.

## Helm releases

| App | Chart | Version | Namespace | Values |
|---|---|---|---|---|
| Jellyfin | `jellyfin/jellyfin` | `3.7.0` | `jellyfin` | `apps/jellyfin/values.yaml` |
| Nextcloud | `nextcloud/nextcloud` | `9.4.1` | `nextcloud` | `apps/nextcloud/values.yaml` + `values.local.yaml` (gitignored) |
| Navidrome | `djjudas21/navidrome` | `6.8.7` | `navidrome` | `apps/navidrome/values.yaml` |
| n8n | `community-charts/n8n` | `1.24.43` | `n8n` | `apps/n8n/values.yaml` |
| Open WebUI | `open-webui/open-webui` | `17.4.0` | `openwebui` | `apps/openwebui/values.yaml` |
| kube-prometheus-stack | `prometheus-community/kube-prometheus-stack` | `92.17.0` | `observability` | `observability/kube-prometheus-stack/values.yaml` |
| Loki | `grafana/loki` | `7.5.0` | `observability` | `observability/loki/values.yaml` |
| Promtail | `grafana/promtail` | `6.17.1` | `observability` | `observability/promtail/values.yaml` |

Repos: `https://jellyfin.github.io/jellyfin-helm` · `https://nextcloud.github.io/helm` ·
`https://djjudas21.github.io/charts` · `https://community-charts.github.io/helm-charts` ·
`https://helm.openwebui.com` · `https://prometheus-community.github.io/helm-charts` ·
`https://grafana.github.io/helm-charts`

## NodePort registry

Every public app needs a unique NodePort in 30000–32767 and its own SG rule.

| NodePort | App | Exposure | ADR |
|---|---|---|---|
| 30096 | Jellyfin | public HTTP | ADR-017 |
| 30080 | Nextcloud | public HTTP | ADR-018 |
| 30081 | Navidrome | public HTTP | ADR-019 |
| 30079 | n8n | public HTTP | ADR-020 |
| 30078 | Open WebUI | public HTTP | ADR-021 |

**Five plaintext ports.** Hard stop: no sixth port. The next public app must go behind one
front door (Traefik Ingress + TLS, or Tailscale Funnel), and these ports should be collapsed
behind it.

Bump the version here **and** in the values-file header together. Read the chart changelog
first: renamed values are silently ignored and the release "succeeds" with old behaviour.

## Rules

1. **Upstream charts first.** No authored or vendored charts. Raw manifests (`manifests.yaml`)
   are allowed only when no maintained chart exists — see the table above.
2. **Values live beside the app.** There is no `helm/` and no `charts/` directory.
3. **Pin versions.** No floating chart versions, no `:latest` images.
4. **No secrets in git.** `*.secret.yaml` is ignored; real values are created with `kubectl`.
5. **Storage is explicit:** `storageClass: local-path-retain` and an explicit size.
6. **No public exposure by default.** `service.type: ClusterIP`; reach apps with
   `port-forward`. Documented exceptions live in the NodePort registry above (ADR-017..021).
   A new public port needs its own ADR — and the next one must use a front door.
7. **Every app folder has a README:** storage, exposure, install, verify, restore.
8. **Nothing is edited on the node.** Changes come from this repository or they do not count.
