# Navidrome

Music streaming server, third application. No database server, no secrets, no bootstrap:
one container plus two volumes. Public via NodePort 30081 (ADR-019) — the third and last
plaintext port before the project needs one front door.

| Item | Value |
|---|---|
| Chart | `djjudas21/navidrome` `6.8.7` (appVersion `0.64.2`) — [repo](https://djjudas21.github.io/charts) |
| Namespace | `navidrome` |
| Service | NodePort `30081` → container 4533 — public HTTP, no TLS (ADR-019) |
| Storage | `/data` 512 Mi PVC · `/music` 1 Gi PVC (read-only) |
| Chart base | bjw-s `common` 0.2.2 library (chart only adds its own defaults) |

## Before you install (on the server)

```bash
cd ~/cloud-native-homelab
kubectl apply -f k8s/namespaces/

helm repo add djjudas21 https://djjudas21.github.io/charts
helm repo update
helm show values djjudas21/navidrome --version 6.8.7 | less

df -h /var/lib/rancher/k3s/storage     # 512Mi + 1Gi here; 9.5 of 10 Gi now allocated
```

## Install

```bash
helm template navidrome djjudas21/navidrome -n navidrome --version 6.8.7 \
  -f k8s/apps/navidrome/values.yaml > /tmp/navidrome-rendered.yaml
# check: two PVCs with storageClassName: local-path-retain, one Deployment, service type NodePort 4533:30081

helm upgrade --install navidrome djjudas21/navidrome -n navidrome --version 6.8.7 \
  -f k8s/apps/navidrome/values.yaml --wait --timeout 5m
```

## Is it working? (verify)

```bash
kubectl -n navidrome get pods,pvc,svc
# expect: pod 1/1 Running · pvc navidrome-config + navidrome-music Bound · svc navidrome 4533:30081/TCP

kubectl -n navidrome logs deploy/navidrome --tail=30
# expect: "Navidrome starting" then the server listening on 4533

# HTTP answer from inside the cluster
kubectl -n navidrome run curl-test --rm -it --restart=Never \
  --image=curlimages/curl:8.10.1 -- curl -s -o /dev/null -w "%{http_code}\n" http://navidrome:4533/ping
# 200 = alive
```

## Open the UI

Public (ADR-019):

```
http://<public-ip>:30081
```

The security group must allow TCP 30081. There is no Elastic IP, so the public IP — and this
URL — changes if the instance is stopped/started.

Private fallback:

```bash
# server
kubectl -n navidrome port-forward svc/navidrome 4533:4533
# laptop
ssh -L 4533:127.0.0.1:4533 ubuntu@<node>
# browser
http://localhost:4533
```

First visit asks you to **create the admin account** (username + password) — there is no
config-file bootstrap. That account lives in the SQLite DB on the `/data` PVC.

## Load test music

`/music` is read-only for the pod, so copy files on the node into the music PV directory:

```bash
ls /var/lib/rancher/k3s/storage/          # look for the *-navidrome-music directory
sudo cp -r /path/to/some-album/ /var/lib/rancher/k3s/storage/<music-dir>/
```

Then in the UI trigger a scan (or wait for `ND_SCANNER_SCHEDULE: 1h`). Watch it:

```bash
kubectl -n navidrome logs deploy/navidrome -f | grep -i scan
```

## Prove persistence

```bash
kubectl -n navidrome delete pod -l app.kubernetes.io/name=navidrome
kubectl -n navidrome get pods -w
```

After restart: the admin login still works and the library is still scanned. That is the PVC
doing its job.

## Backups

No database server to dump. Two things matter:

```bash
# SQLite + play history + users
sudo tar czf /tmp/navidrome-data-$(date +%F).tgz -C /var/lib/rancher/k3s/storage <data-dir>
# music is replaceable test data; snapshot the whole EBS volume if you care
```

## Public access (ADR-019)

Exposed like the other two apps:

1. `service.main.type: NodePort` + `service.main.ports.http.nodePort: 30081` (in `values.yaml`)
2. SG inbound TCP 30081
3. URL: `http://<public-ip>:30081`

Three plaintext ports (30096, 30080, 30081) is where this should stop. The next architectural
step is one front door — Traefik Ingress with TLS, or Tailscale Funnel — not a fourth port.

## Gotchas

- **Public and plaintext**: the admin password crosses the network unencrypted. Use a unique one.
- `persistence.*.enabled` defaults to **false** in this chart → emptyDir → everything lost.
- Persistence `type` is `pvc`, not `persistentVolumeClaim` (bjw-s common schema).
- The chart inherits the `common` library: keys live at the top level (`env`, `resources`,
  `persistence`, `service.main`), not under `controller.containers`.
- `/music` is read-only; files are copied node-side, never through the UI.
- Nothing in Navidrome speaks S3. The catalog's old "native S3 backend" note was wrong —
  object storage would need `rclone`/`s3fs` mounted as a local path.

## Sizing

50m/128Mi requested, 500m/512Mi limit. Music streaming is mostly I/O; transcoding is off by
default and would need CPU headroom you do not have on this node.
