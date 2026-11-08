# cloud-native-homelab

A small, self-hosted cloud platform on AWS — built and operated by hand, then codified.

One EC2 node, k3s, Helm, Tailscale-only access, a retained EBS data volume, and S3 for
backups. The point of the project is not the apps: it is the design decisions, the failure
modes, and the documentation.

## Status

| Layer | State |
|---|---|
| AWS design | Signed off |
| AWS build | In progress |
| Cluster (k3s) | Not installed |
| Apps | First app: Jellyfin (Helm) |

**This repository is honest about its state:** no Infrastructure-as-Code yet, no GitOps yet.
Terraform and ArgoCD are planned, not claimed.

## Architecture

```
                    Internet
                       │  outbound only
                       ▼
┌──────────────── VPC 10.10.0.0/16 ─────────────────┐
│  Public subnet 10.10.0.0/24 · one AZ              │
│    Internet Gateway                               │
│                                                   │
│    EC2 t3.large · Ubuntu 24.04                    │
│      SG ingress: NONE                             │
│      k3s · Traefik                                │
│      25 GB root EBS (disposable)                  │
│      10 GB data EBS (retained)                    │
└───────────────────────────────────────────────────┘
        │                          │
   S3 backups bucket          Tailscale tailnet
   (pg_dump, exports)         (admin + app access)
```

Traffic paths:

- **Admin:** laptop → tailnet → node SSH (22) and kube API (6443). Never public.
- **Apps:** laptop → tailnet → `kubectl port-forward`. No public hostnames, no domain.
- **Recovery:** SSM Session Manager, no key pair, no open port.

## Stack

| Layer | Choice | Why |
|---|---|---|
| Cloud | AWS, one region | Target platform |
| Compute | 1 × `t3.large` (8 GB) | Fits k3s, Traefik, an app and a database |
| Orchestration | k3s | Full Kubernetes, no control-plane fee |
| Ingress | Traefik (bundled) | One HTTP entry point, nothing extra to install |
| Access | Tailscale | No public ports, no bastion, no domain |
| Storage | `local-path-retain` on EBS | POSIX for databases and app data |
| Backups | EBS snapshots + S3 | Survives instance loss |
| Packaging | Upstream Helm charts + values | Don't hand-write 40 objects per app |
| IaC | Terraform | **Planned** — infra is manual today |
| GitOps | ArgoCD | **Planned** — delivery is manual today |

## Repository layout

```
k8s/                 everything that runs inside the cluster
  namespaces/        one namespace per app, plus platform and observability
  platform/          cluster-level plumbing: StorageClass, later Traefik config
  apps/<app>/        one folder per app: values.yaml + README
```

Rules and conventions: [`k8s/README.md`](k8s/README.md).

## Prerequisites

- `kubectl` and `helm` on your machine (clients only)
- Tailscale on your machine and on the node
- An SSH path to the node over the tailnet

## Quick start

```bash
# 1. cluster-scoped objects, in order
kubectl apply -f k8s/namespaces/
kubectl apply -f k8s/platform/

# 2. read the chart's defaults once
helm repo add jellyfin https://jellyfin.github.io/jellyfin-helm
helm repo update
helm show values jellyfin/jellyfin --version 3.7.0 | less

# 3. render, inspect, then install
helm template jellyfin jellyfin/jellyfin -n jellyfin --version 3.7.0 \
  -f k8s/apps/jellyfin/values.yaml > /tmp/jellyfin-rendered.yaml

helm upgrade --install jellyfin jellyfin/jellyfin -n jellyfin --version 3.7.0 \
  -f k8s/apps/jellyfin/values.yaml

# 4. verify and open
kubectl -n jellyfin get pods,pvc,svc -o wide
kubectl -n jellyfin port-forward svc/jellyfin 8096:8096
```

## Roadmap

1. Provision AWS (VPC, node, disks, bucket)
2. k3s + Tailscale + storage
3. Jellyfin via Helm
4. Observability, backups, restore drill
5. Terraform codification, then ArgoCD

## License

Personal project. No license granted.
