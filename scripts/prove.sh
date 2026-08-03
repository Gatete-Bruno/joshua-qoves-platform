#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=docs/proof
mkdir -p "$OUT"
IP=$(minikube ip)

{
  kubectl get pods,svc,ingress,netpol -A
  echo
  kubectl get ciliumnetworkpolicies -A
} > "$OUT/01-cluster-state.txt" 2>&1

kubectl -n argocd get applications -o wide > "$OUT/02-argocd-apps.txt" 2>&1

{
  echo "\$ curl -H 'Host: qoves.local' http://$IP/healthz"
  curl -sS -H 'Host: qoves.local' "http://$IP/healthz"
  echo "\$ curl -H 'Host: qoves.local' http://$IP/"
  curl -sS -H 'Host: qoves.local' "http://$IP/"
} > "$OUT/03-healthz-via-ingress.txt" 2>&1

{
  echo '# unrelated pod -> postgres:5432 (expect DENIED by default-deny)'
  kubectl -n qoves-app run netpol-test --rm -i --restart=Never \
    --image=busybox:1.37.0 --pod-running-timeout=2m \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"netpol-test","image":"busybox:1.37.0","command":["sh","-c","nc -z -w 3 qoves-db-rw 5432 && echo REACHABLE || echo BLOCKED"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
  echo
  echo '# api pod -> https://api.github.com (expect allowed via FQDN policy)'
  kubectl -n qoves-app exec deploy/qoves-api -- python3 -c \
    'import urllib.request; print(urllib.request.urlopen("https://api.github.com", timeout=10).status)'
  echo '# api pod -> https://example.com (expect blocked)'
  kubectl -n qoves-app exec deploy/qoves-api -- python3 -c \
    'import urllib.request, socket
try:
    print(urllib.request.urlopen("https://example.com", timeout=5).status)
except Exception as e:
    print("BLOCKED:", type(e).__name__, e)'
} > "$OUT/04-netpol-blocks.txt" 2>&1

{
  PRIMARY=$(kubectl -n qoves-app get cluster qoves-db -o jsonpath='{.status.currentPrimary}')
  kubectl -n qoves-app exec "$PRIMARY" -- psql -U postgres -d qoves -c \
    'CREATE TABLE IF NOT EXISTS survival (id serial PRIMARY KEY, note text, at timestamptz DEFAULT now()); INSERT INTO survival (note) VALUES ($$before pod delete$$);'
  kubectl -n qoves-app delete pod "$PRIMARY" --wait=false
  sleep 45
  NEW_PRIMARY=$(kubectl -n qoves-app get cluster qoves-db -o jsonpath='{.status.currentPrimary}')
  echo "primary was: $PRIMARY  now: $NEW_PRIMARY"
  kubectl -n qoves-app exec "$NEW_PRIMARY" -- psql -U postgres -d qoves -c 'TABLE survival;'
  kubectl -n qoves-app get pvc
} > "$OUT/05-data-survival.txt" 2>&1

{
  echo '# unsigned image (expect admission denial by Kyverno)'
  kubectl -n qoves-app run unsigned-test --restart=Never --image=registry:5000/qoves-api:unsigned 2>&1
} > "$OUT/06-unsigned-image-denied.txt" 2>&1

{
  kubectl -n qoves-app get backups.postgresql.cnpg.io -o wide
  kubectl -n qoves-minio exec deploy/minio -- sh -c 'ls -R /data/qoves-backups | head -40'
} > "$OUT/07-backups-in-minio.txt" 2>&1

{
  echo '# PromQL: up{namespace="qoves-app"}  and the alert rule state'
  kubectl -n monitoring exec sts/prometheus-monitoring-kube-prometheus-prometheus -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/query?query=up{namespace="qoves-app"}'
  echo
  kubectl -n monitoring exec sts/prometheus-monitoring-kube-prometheus-prometheus -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/rules' | head -c 4000
} > "$OUT/08-prometheus.txt" 2>&1

kubectl -n qoves-app get hpa,quota,pdb > "$OUT/09-hpa-quota.txt" 2>&1

ls -l "$OUT"
