# Jellyfin

Media server, first application in the cluster. Chosen because it has no database and no
secrets: it proves storage, scheduling and Helm end to end with one container.

| Item | Value |
|---|---|
| Chart | `jellyfin/jellyfin` `3.7.0` ([repo](https://jellyfin.github.io/jellyfin-helm)) |
| Namespace | `jellyfin` |
| Service | NodePort `30096` — public HTTP, no TLS (ADR-017) |
| Storage | `/config` 1 Gi PVC · `/media` 2 Gi PVC (read-only) · `/cache` emptyDir |
| StorageClass | `local-path-retain` |
| Backup | EBS snapshot of the data volume (contains the SQLite config and media) |

## Install

```bash
helm repo add jellyfin https://jellyfin.github.io/jellyfin-helm
helm repo update

# render first — read the output before touching the cluster
helm template jellyfin jellyfin/jellyfin -n jellyfin --version 3.7.0 \
  -f k8s/apps/jellyfin/values.yaml > /tmp/jellyfin-rendered.yaml

helm upgrade --install jellyfin jellyfin/jellyfin -n jellyfin --version 3.7.0 \
  -f k8s/apps/jellyfin/values.yaml

kubectl -n jellyfin get pods,pvc,svc -o wide
kubectl -n jellyfin port-forward svc/jellyfin 8096:8096
```

> **Private fallback:** `port-forward` listens on `127.0.0.1` of the machine where
> `kubectl` runs (the node), so for that route keep it running there and from the laptop:
> `ssh -L 8096:127.0.0.1:8096 ubuntu@<node>`, then open `http://localhost:8096`.

## Public access (ADR-017)

The Service is `NodePort 30096` — exposed directly, **plaintext HTTP, no TLS**.

1. Security group: allow inbound **TCP 30096** (`0.0.0.0/0` for the internet, or your own IP
   to keep it narrower).
2. Open `http://<node-public-ip>:30096`.
3. There is **no Elastic IP**: stopping/starting the instance changes the public IP, and so
   the URL.

Harden before inviting anyone:

- Strong, unique admin password — it crosses the network unencrypted.
- Dashboard → Users: turn **off** remote connections for the admin account; create a
  separate limited user for streaming.
- Expect background bot scans in the Jellyfin logs. That is normal for a public port.
- Keep the chart version pinned; upgrade deliberately, after reading the changelog.

## Load test media

`/media` is **read-only for the pod** — Jellyfin can never put files there. Copy them on the
node, into the directory behind the PVC:

```bash
# find the directory local-path created for the media PVC
ls /var/lib/rancher/k3s/storage/          # look for pvc-..._jellyfin_jellyfin-media

# copy a small test file in (download one first, e.g. a ~10 MB clip)
sudo cp /path/to/test-video.mp4 /var/lib/rancher/k3s/storage/<pvc-dir>/
```

The pod's read-only mount does not block the node-side copy: the directory on the host is
ordinary storage. Whatever you copy there appears at `/media` inside the pod.

## First run

1. Open `http://localhost:8096` through the port-forward.
2. Complete the wizard and create the admin user.
3. Add a library pointing at `/media`.
4. Dashboard → Playback: leave hardware acceleration off (no GPU, no transcode budget).

## Verify storage actually works

```bash
kubectl -n jellyfin delete pod -l app.kubernetes.io/name=jellyfin
kubectl -n jellyfin get pods -w
```

If the wizard settings and the library are still there, persistence is correct.

## Restore

1. Stop the release: `helm uninstall jellyfin -n jellyfin` (PVCs are retained).
2. Restore the EBS snapshot, or copy the previous `/config` directory back into the new PV.
3. Re-install with the same values. Jellyfin picks up its existing config.

`local-path-retain` means the PV survives PVC deletion, but the **directory** is what matters:
snapshot the volume before any destructive change.

## Gotchas

- Chart defaults are `config: 5Gi` and `media: 25Gi` — both overridden here to fit a 10 Gi disk.
- The chart mounts `/media` read-only by default; keep it that way.
- `emptyDir` cache and transcodes disappear on pod restart. That is intended.
- The chart also ships a ServiceMonitor block for Prometheus; it is disabled until
  observability exists.
- A PVC can sit `Pending` until a pod schedules (`WaitForFirstConsumer`). Not an error.

## Sizing

Direct play only: 1 CPU / 1 GiB limit. Streaming to a laptop over Tailscale is real AWS egress —
test with small files, not a film library.
