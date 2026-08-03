#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=docs/proof
mkdir -p "$OUT"
IP=$(minikube ip)

{
  echo "== chaos: kill the Postgres primary while /healthz is under load =="
  PRIMARY=$(kubectl -n qoves-app get cluster qoves-db -o jsonpath='{.status.currentPrimary}')
  echo "primary before: $PRIMARY"
  (for i in $(seq 1 240); do
     printf '%s %s\n' "$(date +%T.%3N)" \
       "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 -H 'Host: qoves.local' http://$IP/healthz)"
     sleep 0.5
   done) > /tmp/chaos-load.log &
  LOAD=$!
  sleep 10
  kubectl -n qoves-app delete pod "$PRIMARY" --wait=false
  echo "deleted $PRIMARY at $(date +%T.%3N)"
  wait $LOAD
  echo
  echo "== status codes over time (503s mark the failover window) =="
  awk '{print $2}' /tmp/chaos-load.log | uniq -c
  echo
  kubectl -n qoves-app get cluster qoves-db -o jsonpath='{.status.currentPrimary}{"\n"}'
  kubectl -n qoves-app get events --sort-by=.lastTimestamp | grep -iE "qoves-db|failover|promot" | tail -12
} > "$OUT/10-chaos-primary-kill.txt" 2>&1

cat "$OUT/10-chaos-primary-kill.txt"
