# Open WebUI

Chat UI for LLMs, fifth application. The interesting parts are **egress and secrets** (the
model is remote, the API key never enters git) and **first-user-is-admin** exposure risk.
Public via NodePort 30078 (ADR-021).

| Item | Value |
|---|---|
| Chart | `open-webui/open-webui` `17.4.0` (appVersion `0.12.4`) — [repo](https://helm.openwebui.com) |
| Namespace | `openwebui` |
| Service | NodePort `30078` → container 8080 — public HTTP, no TLS (ADR-021) |
| Storage | `/app/backend/data` 1 Gi PVC (`local-path-retain`) |
| Model backend | None yet (set a provider later in `values.local.yaml`) |

## Before you install

```bash
cd ~/cloud-native-homelab
kubectl apply -f k8s/namespaces/

cp k8s/apps/openwebui/values.local.example.yaml k8s/apps/openwebui/values.local.yaml
nano k8s/apps/openwebui/values.local.yaml     # provider URL + API key

helm repo add open-webui https://helm.openwebui.com
helm repo update
helm show values open-webui/open-webui --version 17.4.0 | less
```

## Install (no API key yet)

`values.local.yaml` is optional until you add a provider. Install from the base values:

```bash
helm template open-webui open-webui/open-webui -n openwebui --version 17.4.0 \
  -f k8s/apps/openwebui/values.yaml > /tmp/openwebui-rendered.yaml
# check: one PVC with local-path-retain, ollama/pipelines absent, nodePort 30078

helm upgrade --install open-webui open-webui/open-webui -n openwebui --version 17.4.0 \
  -f k8s/apps/openwebui/values.yaml --wait --timeout 5m
```

> **Order matters.** Keep the SG rule for 30078 **closed** until you have created your admin
> account over `port-forward` — otherwise a scanner can register first and own the instance.

## Is it working?

```bash
kubectl -n openwebui get pods,pvc,svc
# pod 1/1 Running · pvc Bound · svc open-webui NodePort 80:30078/TCP

kubectl -n openwebui logs deploy/open-webui --tail=40
# expect: Uvicorn running on http://0.0.0.0:8080

kubectl -n openwebui run curl-test --rm -it --restart=Never \
  --image=curlimages/curl:8.10.1 -- curl -s -o /dev/null -w "%{http_code}\n" http://open-webui:80/
# 200 = UI served
```

## Open it

```bash
# 1. create the admin account privately, before opening the SG
kubectl -n openwebui port-forward svc/open-webui 8080:80
# laptop: ssh -L 8080:127.0.0.1:8080 ubuntu@<node>
# browser: http://localhost:8080
```

2. Disable signup, then upgrade (uncomment `extraEnvVars` in `values.yaml`):

```yaml
extraEnvVars:
  - name: ENABLE_SIGNUP
    value: "false"
```

3. AWS SG → inbound **TCP 30078** → `http://<public-ip>:30078`.

With no provider key the model selector is **empty** — expected. Add `openaiBaseApiUrl` +
`openaiApiKey` to `values.local.yaml` later and `helm upgrade`; no reinstall needed.

## Where the model comes from

Open WebUI is **only a frontend**. It speaks two protocols:

1. **OpenAI-compatible HTTP** (`OPENAI_API_BASE_URL` + key) — anything that looks like OpenAI.
2. **Ollama** — a local model server (disabled here, no GPU).

It **cannot call Amazon Bedrock's native API directly**. Bedrock needs an OpenAI-compatible
bridge in front of it.

### Option A — external OpenAI-compatible API (fastest, no extra pod)

Put in `values.local.yaml` and re-run `helm upgrade`:

```yaml
openaiBaseApiUrl: "https://api.openai.com/v1"      # or openrouter.ai/api/v1, groq.com/openai/v1
openaiApiKey: "sk-..."
```

Then: profile icon → **Admin Panel → Settings → Connections** → the connection should verify
and the models appear in the chat selector. Costs per token, no GPU, nothing else to run.

### Option B — Amazon Bedrock (the "from AWS" answer)

Bedrock is serverless: no GPU, IAM-based, pay per token. Because its API is not
OpenAI-compatible, put a bridge in front:

| Bridge | Size | Verdict |
|---|---|---|
| **LiteLLM** (`litellm/litellm-helm`) | ~1 pod + Postgres if you want keys/spend tracking | Full-featured, official chart; the extra DB is the cost |
| **Bedrock Access Gateway** (AWS sample) | 1 small pod, no DB | Lightest; fewer features |

Steps:

1. **Enable model access** in the Bedrock console, per model and per region. Nothing works
   until the model shows "Access granted".
2. **IAM**: the caller needs
   `bedrock:InvokeModel`, `bedrock:InvokeModelWithResponseStream`, `bedrock:ListFoundationModels`.
   Scope `Resource` to the model ARNs you allow.
3. **Run the bridge** and point it at real model IDs. Cheap starting points are the Amazon
   Nova models; Claude models are stronger and dearer.
4. **Point Open WebUI at the bridge**:
   - LiteLLM: `http://litellm:4000/v1` (any non-empty key if the proxy has no auth)
   - BAG: `http://bedrock-access-gateway:8000/api/v1` (its default key is documented in BAG)
5. **Verify** in Admin Panel → Settings → Connections.

Discover the actual model IDs in your region — do not copy them from blogs:

```bash
aws bedrock list-foundation-models --region <your-region> \
  --query 'modelSummaries[].{id:modelId,provider:providerName}' --output table
```

**Credential choice matters.** The node already has an IAM role (used for S3 backups). Pods can
reach the instance profile, but then *every* pod gets Bedrock access. Prefer a scoped IAM user
key stored in a Kubernetes Secret (ADR-015), or IRSA if you later add an OIDC provider to k3s.

Record any IAM/console change the same day — it is Terraform input later (backlog rule).

### Option C — run the model yourself

Ollama or vLLM on a GPU instance (`g5`/`g6`). The `t3.large` has no GPU and 8 GB of shared RAM,
so this is a different project. Not recommended here.

## Prove persistence

Register the admin, start one chat, then:

```bash
kubectl -n openwebui delete pod -l app.kubernetes.io/name=open-webui
```

After restart: same account, same chat history. That is the PVC.

## Backups

```bash
# chat history, users, settings (SQLite + uploads) — but NOT the API key
sudo tar czf /tmp/openwebui-$(date +%F).tgz -C /var/lib/rancher/k3s/storage <openwebui-data-dir>
```

The API key lives in `values.local.yaml` + the rendered Secret, not in the volume.

## Gotchas

- The chart enables **Ollama and pipelines by default** — they are disabled here on purpose.
  Leaving Ollama on would try to run a model on an 8 GB node with no GPU.
- Without a provider key the UI loads but has no models. That is the expected state.
- `openaiApiKey` must stay out of git → `values.local.yaml` (gitignored).
- The **first registered user becomes admin**: create it before opening 30078, then set
  `ENABLE_SIGNUP=false` and upgrade.
- 2 Gi memory limit: the UI itself is light; the model does not run here.
- Public and plaintext: no TLS. Do not use a password you reuse elsewhere.

## Capacity

1 Gi PVC · 512Mi requested / 2 Gi limit. The limit is not reserved — actual usage is a few
hundred MB — but do not run it next to Jellyfin transcoding on this node.
