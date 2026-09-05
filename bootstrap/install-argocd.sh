#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source .env

echo "=== [1/6] helm dependency build ==="
if [ ! -f argocd/chart/charts/argo-cd-10.3.0.tgz ]; then
  helm dependency build argocd/chart
else
  echo "cached chart present, skipping download"
fi

echo "=== [2/6] helm install/upgrade argocd (manual bootstrap) ==="
helm upgrade --install argocd argocd/chart \
  --namespace argocd --create-namespace \
  --wait --timeout 5m

echo "=== [3/6] wait for argocd-server rollout ==="
kubectl -n argocd rollout status deploy/argocd-server --timeout=180s

echo "=== [4/6] read auto-generated admin password into .env ==="
PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
if grep -q '^# *ARGOCD_ADMIN_PASS=' .env; then
  sed -i '' "s|^# *ARGOCD_ADMIN_PASS=.*|ARGOCD_ADMIN_PASS=${PASS}|" .env
elif grep -q '^ARGOCD_ADMIN_PASS=' .env; then
  sed -i '' "s|^ARGOCD_ADMIN_PASS=.*|ARGOCD_ADMIN_PASS=${PASS}|" .env
else
  echo "ARGOCD_ADMIN_PASS=${PASS}" >> .env
fi

echo "=== [5/6] apply root Application (App-of-Apps self-bootstrap) ==="
kubectl apply -f bootstrap/root-app.yaml

echo "=== [6/6] root app sync status ==="
sleep 6
kubectl -n argocd get application root 2>/dev/null || true

echo ""
echo "=== Bootstrap complete ==="
echo "UI:   https://argocd.localhost"
echo "User: admin"
echo "Pass: ${PASS}  (also stored in .env)"
