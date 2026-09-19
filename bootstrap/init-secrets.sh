#!/usr/bin/env bash
# Inject runtime secrets from .env into K8s clusters:
#   - argocd/argocd-repo-creds-devops   (GITHUB_TOKEN → repo read, prefix-matched)
#   - postgresql/postgresql-credentials (auto-generates missing passwords → .env)
# Idempotent + atomic: kubectl create --dry-run=client | apply (no delete window).
# Usage: bootstrap/init-secrets.sh [--force] [--recover]   (sources ../.env itself)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
FORCE=false
RECOVER=false

for arg in "$@"; do
  case "$arg" in
    --force)  FORCE=true ;;
    --recover) RECOVER=true ;;
    *) echo "Unknown option: $arg (valid: --force, --recover)" && exit 1 ;;
  esac
done

# ---- Recover: read K8s Secret → write .env (defined early so --recover path works) ----
recover_secrets() {
  echo "=== Recover secrets from K8s → .env ==="
  echo "Cluster: $(kubectl config current-context 2>/dev/null || echo 'unknown')"
  echo ""

  local ns="postgresql" secret="postgresql-credentials"
  local -A mapping=(
    ["postgres-password"]="POSTGRES_PASSWORD"
    ["password"]="POSTGRES_USER_PASSWORD"
    ["replication-password"]="POSTGRES_REPLICATION_PASSWORD"
  )

  if ! kubectl get secret "$secret" -n "$ns" --no-headers 2>/dev/null; then
    echo "ERROR: Secret $ns/$secret not found in K8s"
    echo "K8s Secret is gone — no source of truth to recover from."
    echo "Run init-secrets.sh (without --recover) to generate new passwords."
    exit 1
  fi

  local key envvar val updated_count=0
  for key in "${!mapping[@]}"; do
    envvar="${mapping[$key]}"
    val=$(kubectl get secret "$secret" -n "$ns" -o jsonpath="{.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true)
    if [ -z "$val" ]; then
      echo "  SKIP $envvar (Secret key '$key' not found)"
      continue
    fi
    # Update in .env (portable sed)
    if sed --version 2>/dev/null | grep -q GNU; then
      sed -i "s|^${envvar}=.*|${envvar}=\"${val}\"|" "$ENV_FILE"
    else
      sed -i '' "s|^${envvar}=.*|${envvar}=\"${val}\"|" "$ENV_FILE"
    fi
    echo "  ✓ Recovered $envvar (${#val} chars)"
    updated_count=$((updated_count + 1))
  done

  echo ""
  echo "=== Recovered $updated_count entries → $ENV_FILE ==="
  echo "  GITHUB_TOKEN / ARGOCD_ADMIN_PASS: recover manually from GitHub/ArgoCD UI"
}

# ---- Early: recover mode needs NO .env integrity ----
if [ "$RECOVER" = true ]; then
  : "${KUBECONFIG:?KUBECONFIG must be set}"
  if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env not found at $ENV_FILE (need it to write recovered values)"
    echo "Run: cp .env.example .env"
    exit 1
  fi
  recover_secrets
  exit 0
fi

# ---- Normal mode: .env must be complete enough to source ----
if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env not found at $ENV_FILE"
  echo "Run: cp .env.example .env"
  exit 1
fi
set -a
# shellcheck source=../.env
source "$ENV_FILE"
set +a

: "${KUBECONFIG:?KUBECONFIG must be set}"

echo "=== init-secrets (force=$FORCE) ==="
echo "Cluster: $(kubectl config current-context 2>/dev/null || echo 'unknown')"
echo ""

# ---- generate_password: 44 chars base64, writable back ----
ensure_password() {
  local envvar="$1" comment="$2"
  # shellcheck disable=SC2086
  local current="${!envvar:-}"
  if [ -n "$current" ]; then
    return 0  # already set
  fi
  local new
  new=$(openssl rand -base64 32)
  echo "  Generated $envvar (44 chars) → writing back to .env"
  # Use portable sed: BSD sed accepts '' after -i, GNU sed without ''
  if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "s|^${envvar}=.*|${envvar}=\"${new}\"|" "$ENV_FILE"
  else
    sed -i '' "s|^${envvar}=.*|${envvar}=\"${new}\"|" "$ENV_FILE"
  fi
  # Re-source for this session
  eval "${envvar}=\"${new}\""
}

inject() {
  local ns="$1" secret="$2"
  shift 2
  echo "--- $ns / $secret ---"

  # Namespace
  if ! kubectl get namespace "$ns" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep -q "$ns"; then
    echo "  namespace '$ns' not found, creating..."
    kubectl create namespace "$ns"
  fi

  # Ensure each env var has a value (auto-generate if empty)
  local -a args=()
  local pair key envvar
  for pair in "$@"; do
    key="${pair%%=*}"
    envvar="${pair##*=}"
    ensure_password "$envvar" "PostgreSQL ${key}"
    # shellcheck disable=SC2086
    if [ -z "${!envvar}" ]; then
      echo "  FATAL: $envvar still empty after ensure"
      return 1
    fi
    args+=(--from-literal="${key}=${!envvar}")
  done

  # Atomic + idempotent: no delete window, rotation = in-place update.
  # (apply is a no-op when data is unchanged, so --force needs no special path)
  kubectl create secret generic "$secret" -n "$ns" "${args[@]}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "  ✓ OK"
}

# ---- ArgoCD repo credentials (GITHUB_TOKEN → repository-creds template) ----
# ArgoCD matches this secret's `url` as a PREFIX against repo URLs, so one
# token covers every repo under the org. Out-of-band by design: the token
# never enters git, and the secret carries no helm tracking labels so the
# argocd app's selfHeal never touches it.
inject_repo_creds() {
  echo "--- argocd / argocd-repo-creds-devops ---"
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "  WARN: GITHUB_TOKEN empty — skipping repo credentials."
    echo "        Harmless while the repo is public; REQUIRED once it goes private."
    return 0
  fi
  if ! kubectl get namespace argocd >/dev/null 2>&1; then
    echo "  namespace 'argocd' not found — ArgoCD not installed yet? Skipping."
    echo "  (install-argocd.sh re-runs this script after installing ArgoCD)"
    return 0
  fi
  local prefix="${GITHUB_REPO_URL:-https://github.com/QuDevLabs/devops.git}"
  prefix="${prefix%/*}"   # https://github.com/QuDevLabs
  kubectl create secret generic argocd-repo-creds-devops -n argocd \
    --from-literal=type=git \
    --from-literal=url="$prefix" \
    --from-literal=username=git \
    --from-literal=password="${GITHUB_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl label secret argocd-repo-creds-devops -n argocd \
    argocd.argoproj.io/secret-type=repository-creds --overwrite >/dev/null
  echo "  ✓ OK (repository-creds template, url prefix ${prefix})"
}

# ---- Define components ----
inject_repo_creds

inject postgresql postgresql-credentials \
  postgres-password=POSTGRES_PASSWORD \
  password=POSTGRES_USER_PASSWORD \
  replication-password=POSTGRES_REPLICATION_PASSWORD

echo ""
echo "=== Done ==="
echo "ArgoCD ignoreDifferences on Secret /data protects these from overwrite."
echo "Rotation: change .env → re-run (apply updates in place; --force accepted, no-op)."
