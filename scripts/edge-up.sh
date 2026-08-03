#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

minikube start -p qoves-edge --nodes=1 --driver=docker --cpus=2 --memory=2048 \
  --network=minikube --cni=false
cilium install --version v1.19.6 --context qoves-edge
cilium status --wait --wait-duration 10m --context qoves-edge

ARGOCD_PASS=$(kubectl --context minikube -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
argocd login --core=false --insecure --username admin --password "$ARGOCD_PASS" \
  --port-forward --port-forward-namespace argocd --plaintext 2>/dev/null || true
KUBECONFIG=~/.kube/config argocd cluster add qoves-edge --name qoves-edge --yes \
  --port-forward --port-forward-namespace argocd

kubectl --context minikube apply -f bootstrap/edge-app.yaml
