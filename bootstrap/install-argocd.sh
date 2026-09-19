#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source .env

echo "=== [1/8] helm dependency build ==="
if ls argocd/chart/charts/argo-cd-*.tgz >/dev/null 2>&1; then
  echo "cached chart present, skipping download"
elif helm dependency build argocd/chart; then
  echo "built on host"
else
  # GitHub release CDN unreachable from mac host (AGENTS.md §3) — go via OrbStack VM
  echo "host build failed — Docker fallback"
  docker run --rm -v "$PWD:/work" -w /work/argocd/chart alpine/helm:latest dependency build
fi

echo "=== [2/8] helm install/upgrade argocd (manual bootstrap) ==="
helm upgrade --install argocd argocd/chart \
  --namespace argocd --create-namespace \
  --wait --timeout 5m

echo "=== [3/8] wait for argocd-server rollout ==="
kubectl -n argocd rollout status deploy/argocd-server --timeout=180s

echo "=== [4/8] admin password → .env, then drop initial-admin-secret ==="
if kubectl -n argocd get secret argocd-initial-admin-secret >/dev/null 2>&1; then
  PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
  if grep -q '^# *ARGOCD_ADMIN_PASS=' .env; then
    sed -i '' "s|^# *ARGOCD_ADMIN_PASS=.*|ARGOCD_ADMIN_PASS=${PASS}|" .env
  elif grep -q '^ARGOCD_ADMIN_PASS=' .env; then
    sed -i '' "s|^ARGOCD_ADMIN_PASS=.*|ARGOCD_ADMIN_PASS=${PASS}|" .env
  else
    echo "ARGOCD_ADMIN_PASS=${PASS}" >> .env
  fi
  # Password now lives in .env + argocd-secret; the well-known initial secret goes
  kubectl -n argocd delete secret argocd-initial-admin-secret --ignore-not-found=true
else
  echo "argocd-initial-admin-secret absent (re-run) — keeping .env value"
  # shellcheck disable=SC2086
  PASS="${ARGOCD_ADMIN_PASS:-<see .env or argocd-secret>}"
fi

echo "=== [5/8] inject runtime secrets (repo creds + PostgreSQL) ==="
# MUST run before root-app: once the repo is private, ArgoCD cannot fetch
# bootstrap/apps without argocd-repo-creds-devops in place.
bootstrap/init-secrets.sh

echo "=== [6/8] apply AppProjects (root app references project 'argocd') ==="
kubectl apply -f bootstrap/apps/00-projects.yaml

echo "=== [7/8] apply root Application (App-of-Apps self-bootstrap) ==="
kubectl apply -f bootstrap/root-app.yaml

echo "=== [8/8] root app sync status ==="
sleep 6
kubectl -n argocd get application root 2>/dev/null || true

echo ""
echo "=== Bootstrap complete ==="
echo "UI:   https://argocd.localhost"
echo "User: admin"
echo "Pass: ${PASS}  (also stored in .env)"
