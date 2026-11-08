#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY="${CNH_KEY:-$ROOT/cloud-native-homelab.pem}"
SECRETS="${CNH_SECRETS:-$HOME/cnh-secrets}"
REMOTE_DIR="cloud-native-homelab"

log() { printf '\n== %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -f "$KEY" ]] || die "SSH key not found at $KEY (override with CNH_KEY=...)"
command -v terraform >/dev/null || die "terraform not found"
command -v ssh >/dev/null || die "ssh not found"
command -v scp >/dev/null || die "scp not found"

umask 077
mkdir -p "$SECRETS"
chmod 700 "$SECRETS"

if [[ ! -f "$SECRETS/nextcloud-admin-password.txt" ]]; then
  openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24 > "$SECRETS/nextcloud-admin-password.txt"
  chmod 600 "$SECRETS/nextcloud-admin-password.txt"
  log "generated Nextcloud admin password: $SECRETS/nextcloud-admin-password.txt"
fi

if [[ ! -f "$SECRETS/grafana-admin.txt" ]]; then
  printf 'admin\n%s\n' "$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24)" > "$SECRETS/grafana-admin.txt"
  chmod 600 "$SECRETS/grafana-admin.txt"
  log "generated Grafana admin password: $SECRETS/grafana-admin.txt"
fi

IP="$(terraform -chdir="$ROOT/terraform" output -raw public_ip)"
[[ -n "$IP" && "$IP" != "null" ]] || die "terraform output public_ip is empty"

SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5)
ssh_node() { ssh "${SSH_OPTS[@]}" "ubuntu@$IP" "$@"; }
scp_node() { scp "${SSH_OPTS[@]}" "$@"; }

log "waiting for SSH on $IP"
ok=0
for _ in $(seq 1 60); do
  if ssh_node true >/dev/null 2>&1; then ok=1; break; fi
  sleep 5
done
[[ "$ok" = "1" ]] || die "SSH did not come up on $IP"

log "waiting for cloud-init"
ssh_node 'sudo cloud-init status --wait >/dev/null 2>&1 || true'

log "checking k3s, Helm and helmfile"
if ! ssh_node 'command -v k3s >/dev/null && command -v helm >/dev/null && command -v helmfile >/dev/null'; then
  die "k3s/helm/helmfile missing; cloud-init did not finish (see /var/log/cloud-init-output.log)"
fi

log "waiting for the node to be Ready"
ssh_node 'for i in $(seq 1 60); do sudo k3s kubectl get nodes 2>/dev/null | grep -q " Ready " && exit 0; sleep 5; done; exit 1' \
  || die "k3s node did not become Ready"

log "copying manifests"
ssh_node "mkdir -p ~/$REMOTE_DIR/k8s"
scp_node -r "$ROOT/k8s/." "ubuntu@$IP:~/$REMOTE_DIR/k8s/"
scp_node "$ROOT/helmfile.yaml" "ubuntu@$IP:~/$REMOTE_DIR/helmfile.yaml"

log "writing environment-specific values for $IP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
NC_PW="$(cat "$SECRETS/nextcloud-admin-password.txt")"
cat > "$TMP/nextcloud-values.local.yaml" <<EOF
nextcloud:
  host: "$IP:30080"
  username: admin
  password: "$NC_PW"
  trustedDomains:
    - "$IP:30080"
    - "$IP"
    - localhost
    - 127.0.0.1
EOF
cat > "$TMP/n8n-values.local.yaml" <<EOF
extraEnvVars:
  WEBHOOK_URL: "http://$IP:30079/"
EOF
scp_node "$TMP/nextcloud-values.local.yaml" "ubuntu@$IP:~/$REMOTE_DIR/k8s/apps/nextcloud/values.local.yaml"
scp_node "$TMP/n8n-values.local.yaml" "ubuntu@$IP:~/$REMOTE_DIR/k8s/apps/n8n/values.local.yaml"

log "applying namespaces and storage class"
ssh_node "sudo k3s kubectl apply -f ~/$REMOTE_DIR/k8s/namespaces/ >/dev/null && sudo k3s kubectl apply -f ~/$REMOTE_DIR/k8s/platform/ >/dev/null"

log "creating the grafana-admin secret"
GRAFANA_PW="$(sed -n '2p' "$SECRETS/grafana-admin.txt")"
printf 'admin-user=admin\nadmin-password=%s\n' "$GRAFANA_PW" > "$TMP/grafana-admin.env"
scp_node "$TMP/grafana-admin.env" "ubuntu@$IP:/tmp/cnh-grafana.env"
ssh_node "sudo k3s kubectl -n observability create secret generic grafana-admin --from-env-file=/tmp/cnh-grafana.env --dry-run=client -o yaml | sudo k3s kubectl apply -f - >/dev/null && rm -f /tmp/cnh-grafana.env"

log "helmfile sync (cold install can take 10-15 minutes)"
ssh_node "cd ~/$REMOTE_DIR && sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml helmfile sync --concurrency 1"

log "applying extra objects"
ssh_node "cd ~/$REMOTE_DIR && sudo k3s kubectl apply -f k8s/apps/n8n/nodeport-service.yaml >/dev/null && sudo k3s kubectl apply -f k8s/observability/loki/datasource-configmap.yaml >/dev/null"

log "running pods"
ssh_node "sudo k3s kubectl get pods -A"

printf '\nApps:\n'
printf '  http://%s:30096  Jellyfin\n' "$IP"
printf '  http://%s:30080  Nextcloud\n' "$IP"
printf '  http://%s:30081  Navidrome\n' "$IP"
printf '  http://%s:30079  n8n\n' "$IP"
printf '  http://%s:30078  Open WebUI\n' "$IP"
printf '\nGrafana is internal only. Tunnel with:\n'
printf '  ssh -i %q ubuntu@%s "sudo k3s kubectl -n observability get svc kube-prometheus-stack-grafana -o jsonpath={.spec.clusterIP}"\n' "$KEY" "$IP"
printf '  ssh -i %q -L 3000:<cluster-ip>:80 ubuntu@%s\n' "$KEY" "$IP"
printf '\nPasswords:\n'
printf '  %s/nextcloud-admin-password.txt\n' "$SECRETS"
printf '  %s/grafana-admin.txt\n' "$SECRETS"
