# AGENTS.md — GitOps infra repo (single source of truth)

ArgoCD self-manages everything via App-of-Apps bootstrap. Local = OrbStack.
⚠️ This file is the single source of truth for project rules.

## 1. Invariants

- No plaintext credentials in Helm values
- ArgoCD Application CRD must: use `valueFiles` (not `valuesObject`), set `resources-finalizer`, `ServerSideApply=true`, and `ignoreDifferences` on Secret `/data` for runtime credentials
- Helm: `<chart>/charts/` tgz gitignored (`**/charts/`); `Chart.lock` committed
- CODE-WIKI.md: grep keywords only, never read full

## 2. OrbStack dev exceptions (production = strict)

- Middleware + CI-CD co-location OK (production: separate clusters)
- `targetRevision: main` OK for umbrella charts + Chart.lock (production: lock SHA)

## 3. Environment gaps

- **macOS → Docker Hub OCI broken** (IPv6 timeout, IPv4 refused). OrbStack VM (ArgoCD pod, Docker) CAN reach it. For `helm dependency build` on host: use Docker-in-Docker (see §5 step 2).
- **macOS → GitHub HTTPS broken**. Push via SSH (`git@github.com:QuDevLabs/devops.git`, key `~/.ssh/id_ed25519`). GitHub release assets via gh-proxy.
- **Bitnami chart ≥ 17.x is OCI-only** (`oci://registry-1.docker.io/bitnamicharts`). HTTPS repo returns 403.
- **OrbStack LoadBalancer**: `192.168.139.2` unreachable from mac. Ports map to `localhost:<port>`. ArgoCD = `https://argocd.localhost`. **No sslip.io.**
- **ArgoCD CLI**: `argocd login argocd.localhost --insecure --grpc-web`. grpc-web required, self-signed cert.

## 4. Bootstrap (one-shot)

```bash
source .env && bootstrap/install-argocd.sh
```

## 5. Adding infra component

Do not `helm install` / `kubectl apply` manually. Follow:

1. **Create chart**: `infra/<name>/Chart.yaml` + `values.yaml` (mirror `argocd/chart/` structure)
2. **Helm dependency build** (run via Docker if direct fails — host → Docker Hub is broken, see §3):
   ```bash
   docker run --rm -v $PWD:/work -w /work/<name> alpine/helm:latest dependency build
   helm lint infra/<name> && helm template <name> infra/<name> -n <ns>
   ```
3. **Create Application CRD**: `bootstrap/apps/<name>.yaml` — copy `bootstrap/apps/argocd.yaml`, change only name/path/release/namespace; add `ignoreDifferences` for any runtime Secret
4. **Push**: `source .env && git add/commit/push` — ArgoCD auto-syncs
5. **Inject secrets** (push does NOT do this):
   ```bash
   kubectl -n <ns> create secret generic <cred-name> \
     --from-literal=<key>="$(openssl rand -base64 32)"
   ```
   ArgoCD reconciles within ~10s; `ignoreDifferences /data` protects from overwrite
6. **Validate**: `kubectl get pods,svc,pvc -n <ns>` → all Running/Bound; `argocd app get <name>` → Synced/Healthy

⚠️ **Data-loss risk**: `prune: true` + delete Application CRD → everything pruned, PVCs included. OrbStack local-path `ReclaimPolicy=Delete`. Gone = gone forever. Never delete namespaces/PVCs manually.

## 6. Version coupling

ArgoCD CLI v3.5.0 ↔ helm chart `argo-cd` 10.3.0 — bump together
