#!/usr/bin/env bash
set -euo pipefail

minikube start --nodes=2 --driver=docker --cpus=4 --memory=3072 \
  --cni=false --insecure-registry="registry:5000"

docker inspect registry >/dev/null 2>&1 || \
  docker run -d --name registry --network minikube -p 127.0.0.1:5000:5000 --restart=always registry:3

cilium install --version v1.19.6 \
  --set hubble.enabled=true --set hubble.relay.enabled=true
cilium status --wait --wait-duration 15m

minikube addons enable ingress
minikube addons enable metrics-server

kubectl get nodes -o wide
