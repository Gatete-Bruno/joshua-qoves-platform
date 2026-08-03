#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="${1:-v1.0.0}"
PUSH_REF="${PUSH_REF:-localhost:5000/qoves-api}"
CLUSTER_REF="${CLUSTER_REF:-registry:5000/qoves-api}"

docker build -t "$PUSH_REF:$TAG" app/
docker push "$PUSH_REF:$TAG"
DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$PUSH_REF:$TAG" | cut -d@ -f2)
echo "digest: $DIGEST"

COSIGN_PASSWORD="${COSIGN_PASSWORD:-}" cosign sign --yes --key cosign.key \
  --allow-http-registry --new-bundle-format=false --use-signing-config=false --tlog-upload=false "$CLUSTER_REF@$DIGEST"

cd manifests/api
kustomize edit set image "qoves-api=$CLUSTER_REF@$DIGEST" 2>/dev/null || {
  python3 - "$CLUSTER_REF" "$DIGEST" <<'EOF'
import re, sys
ref, digest = sys.argv[1], sys.argv[2]
p = "kustomization.yaml"
s = open(p).read()
s = re.sub(r"(- name: qoves-api\n    newName: )\S+(\n    )(newTag|digest): \S+",
           rf"\g<1>{ref}\g<2>digest: {digest}", s)
open(p, "w").write(s)
EOF
}
git --no-pager diff -- kustomization.yaml
