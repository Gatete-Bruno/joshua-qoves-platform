#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=docs/proof
mkdir -p "$OUT"

cp manifests/database/restore/cluster-restored.yaml manifests/database/cluster-restored.yaml
git add manifests/database/cluster-restored.yaml
git commit -m "restore drill: recover qoves-db from object storage as qoves-db-restored"
git push

echo "waiting for Argo CD to sync and the restored cluster to come up..."
kubectl -n qoves-app wait cluster/qoves-db-restored \
  --for=condition=Ready --timeout=15m

{
  echo "== restored cluster from s3://qoves-backups/qoves-db =="
  kubectl -n qoves-app get cluster qoves-db-restored
  kubectl -n qoves-app exec qoves-db-restored-1 -- psql -U postgres -d qoves -c 'TABLE survival;'
} > "$OUT/11-restore-drill.txt" 2>&1
cat "$OUT/11-restore-drill.txt"

git rm -q manifests/database/cluster-restored.yaml
git commit -m "restore drill: verified, remove restored cluster"
git push
