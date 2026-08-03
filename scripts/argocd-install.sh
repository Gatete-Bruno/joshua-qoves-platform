#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

kubectl apply -k bootstrap/argocd
kubectl -n argocd rollout status deploy/argocd-repo-server deploy/argocd-server --timeout=10m
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=5m

kubectl apply -f bootstrap/root-app.yaml
