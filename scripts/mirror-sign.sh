#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -eq 2 ] || { echo "usage: $0 <upstream-ref@digest> <mirror-name:tag>   e.g. $0 ghcr.io/cloudnative-pg/postgresql:18.4@sha256:... postgresql:18.4"; exit 1; }
UPSTREAM="$1"
MIRROR="$2"
PUSH_REG="${PUSH_REG:-localhost:5000}"
CLUSTER_REG="${CLUSTER_REG:-registry:5000}"

docker pull "$UPSTREAM"
docker tag "$UPSTREAM" "$PUSH_REG/$MIRROR"
DIGEST=$(docker push "$PUSH_REG/$MIRROR" | tail -1 | grep -oE 'sha256:[a-f0-9]{64}' | tail -1)
echo "mirrored: $CLUSTER_REG/$MIRROR@$DIGEST"

COSIGN_PASSWORD="${COSIGN_PASSWORD:-}" cosign sign --yes --key cosign.key \
  --allow-http-registry --new-bundle-format=false --use-signing-config=false --tlog-upload=false \
  "$CLUSTER_REG/$MIRROR@$DIGEST"
cosign verify --key cosign.pub --allow-http-registry --insecure-ignore-tlog \
  "$CLUSTER_REG/$MIRROR@$DIGEST" >/dev/null
echo "signed and verified: $CLUSTER_REG/$MIRROR@$DIGEST"
echo "now pin this ref in git (e.g. manifests/database/cluster.yaml) and push."
