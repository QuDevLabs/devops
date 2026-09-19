#!/usr/bin/env bash
# Dev helper: one command for every local ops task.
# Usage: bootstrap/dev.sh <command> [args]
# BSD bash 3.2 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
ENV_FILE="${ROOT_DIR}/.env"
ENV_EXAMPLE="${ROOT_DIR}/.env.example"
PF_PID_FILE="${ROOT_DIR}/.dev-pg-port-forward.pid"
PF_PORT=5432
PG_NAMESPACE="postgresql"
PG_SERVICE="postgresql"

# ---- Find psql ----
find_psql() {
  local candidates=(
    "/opt/homebrew/opt/libpq/bin/psql"
    "/usr/local/opt/libpq/bin/psql"
    "$(which psql 2>/dev/null || true)"
  )
  local p
  for p in "${candidates[@]}"; do
    if [ -n "$p" ] && [ -x "$p" ]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

# ---- port-forward: ensure running ----
ensure_port_forward() {
  if [ -f "$PF_PID_FILE" ]; then
    local pid
    pid=$(cat "$PF_PID_FILE")
    if kill -0 "$pid" 2>/dev/null && nc -z localhost "$PF_PORT" 2>/dev/null; then
      return 0
    fi
    rm -f "$PF_PID_FILE"
  fi
  # Kill anything on our port
  local existing
  existing=$(lsof -ti ":$PF_PORT" 2>/dev/null | head -1 || true)
  [ -n "$existing" ] && kill "$existing" 2>/dev/null || true
  echo "  Starting port-forward :$PF_PORT → ${PG_NAMESPACE}/${PG_SERVICE}:5432"
  kubectl -n "$PG_NAMESPACE" port-forward "svc/${PG_SERVICE}" "$PF_PORT":5432 &>/dev/null &
  echo $! > "$PF_PID_FILE"
  local i=0
  while ! nc -z localhost "$PF_PORT" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -gt 20 ] && { echo "  ERROR: port-forward failed"; rm -f "$PF_PID_FILE"; return 1; }
    sleep 0.5
  done
  echo "  ✓ port-forward ready (PID $(cat "$PF_PID_FILE"))"
}

# ---- .env readiness ----
ensure_env() {
  if [ ! -f "$ENV_FILE" ]; then
    if [ -f "$ENV_EXAMPLE" ]; then
      cp "$ENV_EXAMPLE" "$ENV_FILE"
      echo "✓ Created .env from .env.example"
    else
      echo "ERROR: neither .env nor .env.example found"
      return 1
    fi
  fi
  set -a
  # shellcheck source=../.env
  source "$ENV_FILE"
  set +a
}

# ---- subcommands ----
cmd_pg() {
  local psql_bin
  psql_bin=$(find_psql) || { echo "ERROR: psql not found → brew install libpq"; exit 1; }
  ensure_env
  ensure_port_forward
  echo "Connecting to PostgreSQL on localhost:$PF_PORT..."
  PGPASSWORD="$POSTGRES_PASSWORD" exec "$psql_bin" -h localhost -p "$PF_PORT" -U postgres "${1:+-d $1}"
}

cmd_pf()      { ensure_port_forward; echo "port-forward on localhost:$PF_PORT (PID $(cat "$PF_PID_FILE"))"; }
cmd_pf_stop() {
  [ -f "$PF_PID_FILE" ] && { kill "$(cat "$PF_PID_FILE")" 2>/dev/null; rm -f "$PF_PID_FILE"; echo "✓ stopped"; } \
                       || echo "no port-forward running"
}

cmd_pg_status() {
  kubectl get pods -n "$PG_NAMESPACE" 2>/dev/null | head -3 || echo "namespace $PG_NAMESPACE not found"
  kubectl get pvc -n "$PG_NAMESPACE" 2>/dev/null | head -3 || true
  local psql_bin
  if psql_bin=$(find_psql 2>/dev/null) && ensure_env 2>/dev/null; then
    ensure_port_forward 2>/dev/null || true
    PGPASSWORD="$POSTGRES_PASSWORD" "$psql_bin" -h localhost -p "$PF_PORT" -U postgres -c "SELECT version();" 2>&1 || echo "  (psql check skipped)"
  fi
}

cmd_setup() {
  local force=${1:-}
  echo "=========================================="
  echo "  dev setup — one-time onboarding"
  echo "=========================================="
  echo ""

  # Step 1: .env
  echo "--- 1. .env ---"
  ensure_env
  echo ""

  # Step 2: psql client
  echo "--- 2. psql client ---"
  if find_psql >/dev/null 2>&1; then
    echo "✓ psql ready ($(find_psql))"
  else
    if command -v brew >/dev/null 2>&1; then
      echo "Installing libpq (psql)..."
      brew install libpq 2>&1 | tail -3
      echo ""
      echo "⚠️  Add to ~/.zshrc: export PATH=\"/opt/homebrew/opt/libpq/bin:\$PATH\""
    else
      echo "✗ brew not found. Install libpq manually."
    fi
  fi
  echo ""

  # Step 3: ArgoCD
  echo "--- 3. ArgoCD ---"
  if kubectl get ns argocd --no-headers 2>/dev/null; then
    echo "✓ ArgoCD namespace exists"
  else
    echo "Installing ArgoCD (bootstrap/install-argocd.sh)..."
    "${SCRIPT_DIR}/install-argocd.sh"
  fi
  echo ""

  # Step 4: Helm dep build for all charts
  echo "--- 4. Helm dependencies ---"
  if ! command -v docker >/dev/null 2>&1; then
    echo "✗ docker not found"
  else
    for chart in "${ROOT_DIR}"/infra/*/; do
      [ -f "${chart}Chart.yaml" ] || continue
      echo "  Building: $(basename "$chart")"
      docker run --rm -v "${ROOT_DIR}:/work" -w "/work/infra/$(basename "$chart")" alpine/helm:latest dependency build 2>/dev/null \
        && echo "    ✓" || echo "    (helm dep build skipped)"
    done
  fi
  echo ""

  # Step 5: push (manual reminder — git is tricky to automate safely)
  echo "--- 5. Push to GitHub ---"
  echo "  source .env   # git push auth reads \$GITHUB_TOKEN from the shell env"
  echo "  git add -A && git commit -m 'chore: setup' && git push"
  echo ""

  # Step 6: init-secrets
  echo "--- 6. Inject secrets ---"
  if [ "$force" = "--force" ]; then
    "${SCRIPT_DIR}/init-secrets.sh" --force
  else
    "${SCRIPT_DIR}/init-secrets.sh"
  fi
  echo ""

  # Step 7: wait for pod, verify
  echo "--- 7. PostgreSQL health check ---"
  kubectl get pods -n "$PG_NAMESPACE" 2>/dev/null | head -3 || echo "(waiting for ArgoCD sync... run 'pg-status' in a minute)"
  if [ "$(kubectl get pod -n "$PG_NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)" = "Running" ]; then
    ensure_port_forward
    local psql_bin
    if psql_bin=$(find_psql 2>/dev/null); then
      ensure_env
      PGPASSWORD="$POSTGRES_PASSWORD" "$psql_bin" -h localhost -p "$PF_PORT" -U postgres -c "SELECT version();" 2>&1 | head -3
    fi
  fi

  echo ""
  echo "=========================================="
  echo "  All done."
  echo "  Usage:"
  echo "    ./bootstrap/dev.sh pg           # connect psql"
  echo "    ./bootstrap/dev.sh pg-status    # health check"
  echo "=========================================="
}

cmd_recover() {
  if [ ! -f "$ENV_FILE" ]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE" 2>/dev/null || touch "$ENV_FILE"
    echo "✓ Created empty .env"
  fi
  "${SCRIPT_DIR}/init-secrets.sh" --recover
  echo ""
  echo "=== Manual steps for non-PostgreSQL creds ==="
  echo "  GITHUB_TOKEN:   GitHub → Settings → Developer settings → Personal access tokens"
  echo "  ARGOCD_ADMIN_PASS: kubectl -n argocd get secret argocd-secret -o jsonpath='{.data.admin\.password}' | base64 -d"
}

cmd_help() {
  cat <<EOF
Usage: bootstrap/dev.sh <command>

  setup [--force]    One-time onboarding (.env → ArgoCD → secrets → verify)
  recover            Rebuild .env from K8s Secret (if .env lost)
  pg [dbname]        Connect PostgreSQL via psql (auto port-forward)
  pg-status          Health check (pod + pvc + psql)
  pf                 Start port-forward (idempotent)
  pf-stop            Stop port-forward
  help               This help

First run: bootstrap/dev.sh setup
EOF
}

case "${1:-help}" in
  setup)  shift; cmd_setup "$@" ;;
  recover) cmd_recover ;;
  pg)     shift; cmd_pg "$@" ;;
  pg-status) cmd_pg_status ;;
  pf)     cmd_pf ;;
  pf-stop) cmd_pf_stop ;;
  help|--help|-h) cmd_help ;;
  *) echo "Unknown: $1"; cmd_help; exit 1 ;;
esac
