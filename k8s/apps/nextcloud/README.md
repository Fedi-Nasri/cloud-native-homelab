# Nextcloud

File sync and share, second application in the cluster. Adds a database-backed app, a
background CronJob, and a second public port.

| Item | Value |
|---|---|
| Chart | `nextcloud/nextcloud` `9.4.1` (appVersion `35.0.2`) — [repo](https://nextcloud.github.io/helm) |
| Namespace | `nextcloud` |
| Service | NodePort `30080` → container port 80 — public HTTP, no TLS (ADR-018) |
| Storage | `/var/www/html` 5 Gi PVC (`local-path-retain`) |
| Database | SQLite inside the same PVC (ADR-018 deviation from the Postgres plan) |
| Cron | Kubernetes CronJob, every 5 minutes |
| Backup | volume tar + EBS snapshot (no `pg_dump` with SQLite) |

## Before you install (on the server)

```bash
cd ~/cloud-native-homelab

# 1. namespace
kubectl apply -f k8s/namespaces/

# 2. local secrets file (gitignored) — the ONLY file you edit per environment
cp k8s/apps/nextcloud/values.local.example.yaml k8s/apps/nextcloud/values.local.yaml
nano k8s/apps/nextcloud/values.local.yaml
#    - nextcloud.host        -> "<public-ip>:30080"
#    - nextcloud.trustedDomains -> must contain the IP (with and without :30080)
#    - nextcloud.password    -> a long unique password

# 3. chart repo
helm repo add nextcloud https://nextcloud.github.io/helm/
helm repo update
helm show values nextcloud/nextcloud --version 9.4.1 | less     # optional, read once

# 4. check the disk first: 5 Gi max, and the volume is only 10 Gi total
df -h /var/lib/rancher/k3s/storage
```

Get the public IP (no Elastic IP, so it changes on stop/start):

```bash
curl -s https://checkip.amazonaws.com
```

## Install

```bash
# render first — read it before touching the cluster
helm template nextcloud nextcloud/nextcloud -n nextcloud --version 9.4.1 \
  -f k8s/apps/nextcloud/values.yaml \
  -f k8s/apps/nextcloud/values.local.yaml > /tmp/nextcloud-rendered.yaml

# the render contains the base64 admin password: read it, never commit it
grep -n "kind: PersistentVolumeClaim\|storageClassName\|nodePort\|NEXTCLOUD_TRUSTED_DOMAINS" \
  /tmp/nextcloud-rendered.yaml

helm upgrade --install nextcloud nextcloud/nextcloud -n nextcloud --version 9.4.1 \
  -f k8s/apps/nextcloud/values.yaml \
  -f k8s/apps/nextcloud/values.local.yaml \
  --wait --timeout 10m
```

First boot runs database migrations; 1–3 minutes is normal.

## Is it working? (verify)

```bash
# 1. objects exist and the pod is Ready
kubectl -n nextcloud get pods,pvc,svc,cronjob

# expected:
#   pod        nextcloud-xxxxxxxx   1/1   Running
#   pvc        nextcloud-nextcloud  Bound
#   svc        nextcloud            NodePort   10.43.x.x   8080:30080/TCP
#   cronjob    nextcloud            */5 * * * *   ...

# 2. the app answers inside the cluster
kubectl -n nextcloud run curl-test --rm -it --restart=Never \
  --image=curlimages/curl:8.10.1 -- \
  curl -s -o /dev/null -w "%{http_code}\n" -H "Host: <public-ip>:30080" http://nextcloud:8080/status.php
# 200 = the web server and PHP are healthy

# 3. logs show the install finished
kubectl -n nextcloud logs deploy/nextcloud --tail=50

# 4. the CronJob is actually running
kubectl -n nextcloud get jobs
```

Then in AWS: **SG inbound TCP 30080** (0.0.0.0/0 or your IP), and open:

```
http://<public-ip>:30080
```

There is **no setup wizard** (unlike Jellyfin): the admin user is created from
`values.local.yaml` on first boot. Log in with those credentials.

## Private fallback (no SG rule)

```bash
# server
kubectl -n nextcloud port-forward svc/nextcloud 8080:8080
# laptop
ssh -L 8080:127.0.0.1:8080 ubuntu@<node>
# browser
http://localhost:8080
```

## Prove persistence

```bash
kubectl -n nextcloud delete pod -l app.kubernetes.io/name=nextcloud
kubectl -n nextcloud get pods -w
```

After the pod comes back: log in and open the file you uploaded before the delete. If both
survive, the PVC is doing its job.

## Backup and restore (SQLite)

SQLite means the database is a file inside the same 5 Gi volume — no `pg_dump`.

```bash
# consistent copy: stop writes first
kubectl -n nextcloud exec deploy/nextcloud -- occ maintenance:mode --on
# then snapshot the EBS data volume (AWS console) or tar the PV directory on the node:
sudo tar czf /tmp/nextcloud-$(date +%F).tgz -C /var/lib/rancher/k3s/storage <pvc-dir>
kubectl -n nextcloud exec deploy/nextcloud -- occ maintenance:mode --off
```

Restore: stop the release, restore the snapshot/archive into a new PV, re-install with the
same values. `local-path-retain` keeps the directory when the PVC is deleted; the chart's PVC
also carries `helm.sh/resource-policy: keep`.

## Gotchas

- `persistence.enabled` defaults to **false** → `emptyDir` → every file lost on restart.
- `internalDatabase` wins over the Postgres subchart in the templates: SQLite is intentional.
- Browser Host must be in trusted domains, **including the port** (`ip:30080`). Wrong entry →
  "Access through untrusted domain". Fix `values.local.yaml`, then `helm upgrade` again.
- The public IP changes without an Elastic IP → update `values.local.yaml` + `helm upgrade`.
- NodePort must be unique: 30096 is Jellyfin, 30080 is yours.
- Plaintext HTTP: passwords and file contents travel unencrypted. Test data only.
- Disable user registration/guests in Settings if the instance is public.

## Sizing

1 CPU / 1 GiB limit. SQLite + PHP is fine for a demo; a real deployment needs Postgres,
Redis, and TLS in front (Traefik Ingress or Tailscale Funnel).
