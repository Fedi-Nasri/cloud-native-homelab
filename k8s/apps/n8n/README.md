# n8n

Workflow automation, fourth application. This one is about **state** (workflows and
credentials in SQLite on a PVC) and about a **high-risk public service**: n8n stores
credentials and can run code, so public exposure needs a strong owner password.

| Item | Value |
|---|---|
| Chart | `community-charts/n8n` `1.24.43` (appVersion `2.41.6`) — [repo](https://community-charts.github.io/helm-charts) |
| Namespace | `n8n` |
| Service | NodePort `30079` → container 5678 — public HTTP, no TLS (ADR-020) |
| Storage | `/home/node/.n8n` 1 Gi PVC (`local-path-retain`) |
| Database | SQLite (no database pod) |
| Extra manifest | `nodeport-service.yaml` — pins the NodePort the chart cannot set |

## Before you install

```bash
cd ~/cloud-native-homelab
kubectl apply -f k8s/namespaces/
curl -s https://checkip.amazonaws.com          # public IP

cp k8s/apps/n8n/values.local.example.yaml k8s/apps/n8n/values.local.yaml
nano k8s/apps/n8n/values.local.yaml
#   WEBHOOK_URL: "http://<public-ip>:30079/"

helm repo add community-charts https://community-charts.github.io/helm-charts
helm repo update
helm show values community-charts/n8n --version 1.24.43 | less
```

## Install

```bash
helm template n8n community-charts/n8n -n n8n --version 1.24.43 \
  -f k8s/apps/n8n/values.yaml -f k8s/apps/n8n/values.local.yaml > /tmp/n8n-rendered.yaml
# check: Deployment, one PVC with local-path-retain, N8N_SECURE_COOKIE=false, WEBHOOK_URL

helm upgrade --install n8n community-charts/n8n -n n8n --version 1.24.43 \
  -f k8s/apps/n8n/values.yaml -f k8s/apps/n8n/values.local.yaml \
  --wait --timeout 5m

# the public entry point, pinned to 30079
kubectl apply -f k8s/apps/n8n/nodeport-service.yaml
```

## Is it working?

```bash
kubectl -n n8n get pods,pvc,svc
# pod 1/1 Running · pvc Bound
# svc n8n           ClusterIP  ... 5678/TCP
# svc n8n-nodeport  NodePort   ... 5678:30079/TCP

kubectl -n n8n logs deploy/n8n --tail=40
# "Editor is now accessible via: http://<host>:5678"

kubectl -n n8n run curl-test --rm -it --restart=Never \
  --image=curlimages/curl:8.10.1 -- curl -s -o /dev/null -w "%{http_code}\n" http://n8n:5678/healthz
# 200 = healthy
```

Then in AWS: **SG inbound TCP 30079**, and open:

```
http://<public-ip>:30079
```

First visit: create the **owner account** (email + password). Use a long unique password —
this instance is on the open internet.

Private fallback:

```bash
kubectl -n n8n port-forward svc/n8n 5678:5678
# laptop: ssh -L 5678:127.0.0.1:5678 ubuntu@<node>
# browser: http://localhost:5678
```

## Prove persistence

Create one workflow, then:

```bash
kubectl -n n8n delete pod -l app.kubernetes.io/name=n8n
```

After the pod returns, the workflow is still there. That is the PVC.

## Backups (two things, not one)

```bash
# 1. data: SQLite DB + binary files
sudo tar czf /tmp/n8n-data-$(date +%F).tgz -C /var/lib/rancher/k3s/storage <n8n-data-dir>

# 2. the encryption key Secret — without it the saved credentials are useless
kubectl -n n8n get secret n8n-encryption-key -o yaml > /tmp/n8n-encryption-key.yaml
```

Store both outside the node. Restoring only one of them is not a restore.

## Gotchas

- **`N8N_SECURE_COOKIE=false` is mandatory here.** Over plain HTTP on a non-localhost
  host, n8n sets a Secure cookie and the login form fails with no obvious error.
- **`WEBHOOK_URL` must include the public IP and port**, otherwise every webhook points at
  `localhost:5678`. It lives in `values.local.yaml` because the IP is environment-specific.
- The chart's Service template has **no `nodePort` field**. That is why a separate Service
  (`nodeport-service.yaml`) pins 30079 — without it Kubernetes would assign a random port.
- `extraEnvVars` is a **map** (`KEY: value`), not a list — the chart upper-cases the key and
  renders it as `name: <KEY>`. Maps merge across values files, so `values.local.yaml` only
  adds `WEBHOOK_URL`.
- `main.persistence.enabled` defaults to **false** → emptyDir → all workflows lost on restart.
- `encryptionKey` left empty is generated once; back it up with the data.
- **Public n8n is the riskiest app here**: stored credentials, code execution, webhooks.
  Strong owner password, no "sign up" (single-user community edition), review workflows
  before creating them.
- This is the fourth plaintext port; ADR-020 explicitly overrides the ADR-019 cap. The next
  public app must go behind one front door (Traefik/Funnel).

## Capacity

1 Gi PVC · 256Mi requested / 1 Gi limit. At 9.5 Gi allocated, this app pushes the budget to
10.5 Gi — `local-path` will not stop you, so watch `df -h` and keep data small.
