# AGENTS.md — GitOps infra repo (single source of truth)

ArgoCD self-manages everything via App-of-Apps bootstrap. Local = OrbStack.
⚠️ This file is the single source of truth for project rules.

## 1. Invariants

- No plaintext credentials in Helm values or anywhere in git
- Every Application declares an explicit AppProject (`argocd` / `infra` / `workloads`); `default` is locked empty. AppProjects live in `bootstrap/apps/00-projects.yaml` (sync-wave -1, no finalizers — deleting them must not cascade-delete apps)
- `infra`/`workloads` use **strict namespace whitelists**: adding a component = adding its namespace to the AppProject in the same commit
- ArgoCD Application CRD must: use `valueFiles` (not `valuesObject`), set `resources-finalizer`, `ServerSideApply=true`, and `ignoreDifferences` on Secret `/data` for runtime credentials
- Helm: `<chart>/charts/` tgz gitignored (`**/charts/`); `Chart.lock` committed for **every** chart
- Runtime secrets flow one way: `.env` → `bootstrap/init-secrets.sh` → cluster (atomic `create --dry-run=client | apply`). Never hand-edit cluster Secrets as a source of truth
- CODE-WIKI.md: grep keywords only, never read full

## 2. OrbStack dev exceptions (production = strict, see §7)

- Middleware + CI-CD co-location OK (production: separate clusters)
- `targetRevision: main` OK for umbrella charts + Chart.lock (production: SHA pinned via CI promotion, §7)

## 3. Environment facts (verified 2026-09-19)

- **macOS host → GitHub**: core works (git smart-HTTPS, pages, API). **Release-asset CDN is broken** (tgz downloads die with EOF) and **Docker Hub OCI is broken** (timeout). So `helm dependency build` on host fails for both chart sources → **Docker fallback via OrbStack VM always works**:
  `docker run --rm -v $PWD:/work -w /work/<chart-dir> alpine/helm:latest dependency build`
- **helm 4 breaking change**: HTTP(S) chart repos must be registered (`helm repo add argo https://argoproj.github.io/argo-helm`) before `dependency build`; helm 3 auto-resolves by URL. OCI needs no registration. CI does the repo add explicitly.
- **git remote = HTTPS** (`https://github.com/QuDevLabs/devops.git`). Auth: global git credential helper echoes `$GITHUB_TOKEN` from the shell env → **push from a shell that sourced `.env`**. One fine-grained/classic PAT covers git push + ArgoCD repo read. SSH key (`~/.ssh/id_ed25519`) remains as fallback: `git push git@github.com:QuDevLabs/devops.git main`.
- **Repo is going private**: ArgoCD reads it via `argocd-repo-creds-devops` (secret-type `repository-creds`, url-prefix `https://github.com/QuDevLabs`, injected by init-secrets.sh from `GITHUB_TOKEN`, never in git, no helm tracking labels → selfHeal never touches it). Flip visibility in GitHub UI only after `dev.sh setup` verified on a clean machine.
- **Bitnami chart ≥ 17.x is OCI-only** (`oci://registry-1.docker.io/bitnamicharts`). HTTPS repo returns 403.
- **OrbStack LoadBalancer**: `192.168.139.2` unreachable from mac. Ports map to `localhost:<port>`. ArgoCD = `https://argocd.localhost`. **No sslip.io.**
- **ArgoCD CLI**: `argocd login argocd.localhost --insecure --grpc-web`. grpc-web required, self-signed cert.

## 4. Bootstrap (one-shot)

```bash
cp .env.example .env    # fill GITHUB_TOKEN (PAT: repo push + ArgoCD read)
./bootstrap/dev.sh setup
```

`setup` chains everything in the required order: .env → ArgoCD helm install → admin password → `.env` (initial-admin-secret deleted after) → **secrets injection (repo creds first)** → **AppProjects** → root app → pg verify. Order matters: once the repo is private, ArgoCD cannot fetch `bootstrap/apps/` without the repo-creds secret in place.

## 5. Adding infra component

Do not `helm install` / `kubectl apply` manually. Follow:

1. **Create chart**: `infra/<name>/Chart.yaml` + `values.yaml` (mirror `argocd/chart/` structure)
2. **Helm dependency build** (Docker if host fails, see §3), then commit `Chart.lock`:
   ```bash
   docker run --rm -v $PWD:/work -w /work/infra/<name> alpine/helm:latest dependency build
   helm lint infra/<name> && helm template <name> infra/<name> -n <ns>
   ```
3. **Whitelist the namespace**: add `<ns>` to AppProject `infra` destinations in `bootstrap/apps/00-projects.yaml` (same commit)
4. **Create Application CRD**: `bootstrap/apps/<name>.yaml` — copy `bootstrap/apps/postgresql.yaml`, change only name/path/release/namespace; set `project: infra`; add `ignoreDifferences` for any runtime Secret
5. **Push**: `git add/commit/push` (shell with `.env` sourced) — CI pre-validates lint+template, ArgoCD auto-syncs
6. **Inject secrets** (push does NOT do this): extend `bootstrap/init-secrets.sh` and run it, or one-off:
   ```bash
   kubectl -n <ns> create secret generic <cred-name> --from-literal=<key>="$(openssl rand -base64 32)"
   ```
   ArgoCD reconciles within ~10s; `ignoreDifferences /data` protects from overwrite
7. **Validate**: `kubectl get pods,svc,pvc -n <ns>` → all Running/Bound; `argocd app get <name>` → Synced/Healthy

⚠️ **Data-loss risk**: `prune: true` + delete Application CRD → everything pruned, PVCs included. OrbStack local-path `ReclaimPolicy=Delete`. Gone = gone forever (accepted for dev, §7). Never delete namespaces/PVCs manually.

⚠️ **selfHeal race**: out-of-band `kubectl apply` on app-managed resources gets reverted at the next root-app reconciliation (~120s). When changing tracked manifests, push to git immediately after (or instead of) local applies.

## 6. Version coupling

| Tool | Version | Note |
|------|---------|------|
| ArgoCD CLI | v3.5.0 | ↕️ bump together with helm chart `argo-cd` 10.3.0 |
| helm (host + CI) | v4.2.2 | CI pins the same version (`azure/setup-helm`); helm 3 fallback = `alpine/helm:latest` in Docker |
| PostgreSQL | bitnami chart 18.8.17 | dev only, see §7 |

## 7. Production seams (decided direction, deliberately NOT implemented)

When a production cluster appears, these decisions are already made — do not re-litigate, just build:

- **Multi-env layout**: split into `bootstrap/apps/<env>/` + one root-app per env/cluster + `infra/<name>/values-<env>.yaml` (valueFiles already mandatory). Do not build empty env dirs before the second environment exists
- **Secrets**: SOPS+age, encrypted values committed to git. Dev `.env` flow stays as-is; the two mechanisms never mix
- **Promotion**: GH Actions bumps prod `targetRevision` to a SHA via PR on release — no manual edits, no Image Updater
- **AppProject/RBAC**: tighten `infra`/`workloads` whitelists per prod policy; add ArgoCD RBAC/SSO; AppProject separation already in place
- **Monitoring**: kube-prometheus-stack + argocd-notifications as infra components. Deliberately absent on the laptop (RAM)
- **PostgreSQL engine**: prod = CloudNativePG or managed RDS — never Bitnami standalone (catalog deprecation risk + single node). Dev stays Bitnami
- **Data risk**: no backup for dev PG (accepted: `local-path` `Delete` + prune = permanent loss). Prod requires backup/restore before any real data
