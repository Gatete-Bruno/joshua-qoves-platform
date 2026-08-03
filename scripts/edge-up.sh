#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

minikube start -p qoves-edge --nodes=1 --driver=docker --cpus=2 --memory=2048 \
  --network=minikube --cni=false
cilium install --version v1.19.6 --context qoves-edge
cilium status --wait --wait-duration 15m --context qoves-edge

kubectl config use-context minikube
argocd cluster add qoves-edge --name qoves-edge --core --yes

kubectl --context minikube apply -f bootstrap/edge-app.yaml
