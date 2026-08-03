# QOVES take-home: platform around a trivial API

A Flask API and its Postgres, run properly on self-managed Kubernetes: GitOps
delivery through Argo CD (app-of-apps), default-deny networking under Cilium,
Sealed Secrets, CloudNativePG with backups to MinIO, signed images enforced by
Kyverno, an HPA, and Prometheus with a single deliberate alert.

The reasoning behind every choice lives in [WRITEUP.md](WRITEUP.md). Captured
evidence lives in [docs/proof/](docs/proof/).

## Layout

```
app/                 provided API, unchanged (source + Dockerfile)
bootstrap/           the only things applied by hand: Argo CD itself + root app
apps/                child Applications, one per component, ordered by sync waves
manifests/
  namespaces/        qoves-app (PSA restricted) + ResourceQuota + LimitRange
  api/               Deployment, Service, HPA, PDB, Ingress, ServiceMonitor, alert rule
  database/          CloudNativePG cluster (2 instances), scheduled backup, restore template
  netpol/            default-deny + explicit allows, incl. Cilium FQDN egress policy
  secrets/           SealedSecret ciphertext only
  minio/             backup object store
  policies/          Kyverno image-signature enforcement
  edge/              second-cluster consumer (multi-cluster stretch)
scripts/             bring-up, sealing, signing, proofs, chaos and restore drills
```

## Stand it up

Prereqs: docker, minikube, kubectl, kubeseal, cilium CLI, cosign. Versions are
pinned in the writeup.

```sh
git clone <this-repo> && cd qoves-platform
./scripts/set-repo-url.sh <your-fork-url>   # Applications must point at a repo you can push to
git commit -am "point at my fork" && git push

./scripts/cluster-up.sh                     # minikube (2 nodes) + Cilium + registry + addons
./scripts/build-sign-push.sh               # build, digest-pin, cosign-sign the API image
git commit -am "pin image digest" && git push

./scripts/argocd-install.sh                # the one documented kubectl apply
```

Wait for the sealed-secrets controller (wave 1), then seal credentials against
your cluster and hand them to git:

```sh
./scripts/seal-secrets.sh
git add manifests/secrets && git commit -m "sealed credentials" && git push
```

Argo CD reconciles everything else. `kubectl -n argocd get applications` shows
the tree; every app should reach Synced/Healthy. Then:

```sh
curl -H 'Host: qoves.local' http://$(minikube ip)/healthz   # -> ok
./scripts/prove.sh                                          # captures docs/proof/
```

## Making a change (the GitOps flow)

Nothing is edited on the cluster. Bump `replicas` in
`manifests/api/deployment.yaml`, commit, push; Argo CD notices, syncs, and the
Deployment changes. A new image version goes through
`./scripts/build-sign-push.sh`, which rewrites the digest pin in
`manifests/api/kustomization.yaml` so the deploy is itself a reviewable diff.
Unsigned images are rejected at admission, so a digest that skipped the signing
step cannot run.

## Stretch drills

```sh
./scripts/chaos.sh           # kill the Postgres primary under load, watch failover
./scripts/restore-drill.sh   # recover the DB from MinIO via a git commit
./scripts/edge-up.sh         # second cluster, managed by the same Argo CD
```
