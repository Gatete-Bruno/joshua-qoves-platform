#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
KS="kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets-controller --format yaml"

DB_PASSWORD=$(openssl rand -hex 20)
MINIO_USER=qoves-backup
MINIO_PASSWORD=$(openssl rand -hex 20)

kubectl create secret generic db-app-auth -n qoves-app \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=qoves \
  --from-literal=password="$DB_PASSWORD" \
  --dry-run=client -o yaml | $KS > manifests/secrets/db-app-auth.yaml

kubectl create secret generic api-database-url -n qoves-app \
  --from-literal=DATABASE_URL="postgresql://qoves:${DB_PASSWORD}@qoves-db-rw.qoves-app.svc.cluster.local:5432/qoves" \
  --dry-run=client -o yaml | $KS > manifests/secrets/api-database-url.yaml

kubectl create secret generic db-backup-s3 -n qoves-app \
  --from-literal=ACCESS_KEY_ID="$MINIO_USER" \
  --from-literal=SECRET_ACCESS_KEY="$MINIO_PASSWORD" \
  --dry-run=client -o yaml | $KS > manifests/secrets/db-backup-s3.yaml

kubectl create secret generic minio-root -n qoves-minio \
  --from-literal=MINIO_ROOT_USER="$MINIO_USER" \
  --from-literal=MINIO_ROOT_PASSWORD="$MINIO_PASSWORD" \
  --dry-run=client -o yaml | $KS > manifests/secrets/minio-root.yaml

ls -l manifests/secrets/
