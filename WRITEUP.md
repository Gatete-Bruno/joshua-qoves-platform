# Writeup

## 1. Run it

Everything you need is in the README, so I'll keep this to the shape of the
thing. Two commands stand up infrastructure by hand: `cluster-up.sh` (minikube
with two nodes, Cilium 1.19.6, a local registry, the ingress and
metrics-server addons) and `argocd-install.sh` (Argo CD v3.4.6 plus the root
Application). That second apply is the last time a human touches the cluster.
The root app points at `apps/`, where eleven child Applications describe the
rest of the platform, and Argo CD reconciles them in sync-wave order:
namespaces and quotas first, then the operators (sealed-secrets, CloudNativePG,
Kyverno, the Prometheus stack), then sealed credentials and admission policies,
then MinIO and the network policies, then the database, and finally the API.

Waves matter less than they look like they should. Argo retries forever with
backoff, so the system would converge even with no ordering at all; the waves
mostly stop the first sync from looking like a wall of red while CRDs land.

To change something, you edit a file and push. Replicas, a resource limit, an
alert threshold, all of it goes through a commit. New code is the one flow
with a tool in the middle: `build-sign-push.sh` builds the image, pushes it by
digest, signs the digest with cosign, and rewrites the kustomize image pin, so
the "deploy" is a one-line diff that review can actually see. I find that
property worth more than any dashboard: the answer to "what changed at 15:04"
is always `git log`.

Secrets are the one deliberate chicken-and-egg. Ciphertext in git is sealed
against the key of a specific sealed-secrets controller, so on a fresh cluster
you run `seal-secrets.sh` after wave 1 and commit what it emits. The repo you
clone contains my ciphertext, which your controller cannot open. That is the
feature, not a bug, though it does mean the first bring-up has a manual step
in the middle and I'd rather admit that than hide it in a Makefile.

## 2. Decisions

**Cilium over Calico.** Both enforce NetworkPolicy properly, and for the core
task either would have been fine, so the honest tiebreakers were tooling and
one stretch goal. Hubble lets me show a denied connection as a `DROPPED` flow
rather than asking you to trust a hung `nc`, and the FQDN egress stretch
("allow exactly one external domain") is a `toFQDNs` rule in a
CiliumNetworkPolicy, which vanilla NetworkPolicy simply cannot express. Calico
has an equivalent, but I know the Cilium DNS-proxy behavior better. The cost
is that minikube's `--cni=cilium` ships whatever version minikube bundled, so
I install Cilium with its own CLI, pinned, right after cluster creation.

**Sealed Secrets over SOPS and External Secrets.** SOPS needs a decryption
plugin wired into Argo CD's repo server, which means patching the one
component I promised to install by hand and keep boring. ESO is the right
production answer but only makes sense against a real store; running Vault in
dev mode to feed it felt like theater, and the brief explicitly warns against
ESO's fake provider. Sealed Secrets is fully local, needs nothing beyond its
controller, and its ciphertext is safe in a public repo. The trade I'm
accepting: the sealing key lives only in the cluster, so losing the cluster
loses the ability to decrypt git. Production would either back up that key or,
more likely, switch to ESO with Vault and leave the consumers untouched, since
the API only ever sees a plain Secret either way.

**CloudNativePG over a raw StatefulSet.** I went back and forth here, since a
raw StatefulSet is fewer moving parts and the brief blesses it. The operator
won for two reasons. First, failover: with two instances, killing the primary
is a promotion (the chaos drill measures roughly a 10 to 20 second window of
healthz 503s) instead of an outage that lasts until a human notices. Second,
backups stop being a bash script: `barmanObjectStore` plus a ScheduledBackup
gives WAL archiving and a `bootstrap.recovery` restore path that I can drill
through git. Worth noting that CNPG deprecated in-tree Barman in favor of a
plugin from 1.26 on; I stayed in-tree because it's still the default and the
plugin adds a cert-manager dependency I didn't want in a three-day build, but
a migration is on the roadmap if this were to live longer.

**CPU HPA, knowingly wrong.** The HPA scales on 70% CPU because CPU is the
only signal metrics-server offers without extra machinery. For this API it is
close to the wrong signal: the handler is I/O-bound on Postgres, so the
failure mode under load is latency climbing while CPU idles, and a CPU HPA
sleeps straight through it. The right signal is requests per second or p95
latency per pod, which we already export via `http_requests_total`; wiring
prometheus-adapter or KEDA to feed that into the HPA is the first thing I'd
add with another day. I kept CPU anyway because a mis-tuned custom-metrics
pipeline is worse than an honest simple one.

**Readiness on /healthz, liveness on /.** This one is arguable and I want to
argue it. Gating readiness on the DB means a database outage pulls every API
pod out of the ingress, which amplifies a partial failure into a full 503 at
the edge. I chose it anyway, for two reasons. Every meaningful endpoint of
this API needs Postgres, so serving traffic without it is serving errors with
extra steps; failing readiness sheds load at the LB, where it belongs. And
the kubelet probing /healthz every 10 seconds gives Prometheus a steady
per-pod stream of DB reachability, which is exactly what the alert keys on.
Liveness stays on `/` so a DB outage never restarts healthy pods, which would
add churn and hide the real signal. If the app had DB-free endpoints worth
serving during an outage, I'd flip this decision.

**One alert.** `ApiDatabaseUnreachable` fires after five sustained minutes of
503s from /healthz. It's actionable (check the DB pods, the PVC, the netpols),
it's user-facing (readiness is already shedding traffic when it fires), and it
can't flap on a single blip because of the `for: 5m`. I disabled the chart's
hundred-odd default rules on purpose; a pager that only speaks when users are
hurting is the entire point of Part H, and I'd rather defend one good alert
than mute ninety bad ones in the first on-call week.

## 3. What minikube did for me

On real metal, `minikube start` unfolds into about a week of work. It ran
kubeadm-equivalent bootstrap: PKI, etcd, the control plane static pods, node
join tokens. I'd own all of that, plus keeping etcd healthy, which deserves
its own sentence: minikube runs a single etcd with no snapshot schedule, and
on metal I'd run a three-member cluster with `etcdctl snapshot save` on a
cron and a tested restore, because losing etcd without a snapshot is losing
the cluster.

The ingress addon quietly stands in for a real edge. There is no cloud
LoadBalancer here; minikube exposes ingress-nginx on the node and calls it a
day. Self-managed, I'd run MetalLB (or BGP from the ToR switches) to hand out
VIPs, with HAProxy or keepalived in front if the edge needed to survive a node
loss. Storage is the same story: the hostPath provisioner hands out
"PersistentVolumes" that are directories on one node, which is why my Postgres
data would not survive that node's disk. Metal means a CSI driver with actual
replication, Longhorn if I want easy, Ceph if I want serious. And the CNI
came from one flag instead of a design meeting about pod CIDRs, encapsulation
versus native routing, and whether kube-proxy stays.

## 4. Production gaps

What stands between this and real traffic, roughly in the order I'd fix it.
The Postgres pair has no tested HA story beyond one promotion drill, and its
backups live in a MinIO that shares the cluster's fate; offsite (real S3,
different failure domain) is non-negotiable. The sealed-secrets key exists in
exactly one place, so today a cluster loss also bricks every secret in git,
which is the strongest argument for graduating to ESO plus Vault. Nothing
here upgrades: no Kubernetes version strategy, no node OS patching, no
rehearsed CNPG or Argo CD upgrades. The supply chain checks signatures but
only in `qoves-app`, with a key that lives on my laptop rather than in KMS
with rotation, and no SBOM or provenance attestations. Argo CD itself is a
single replica managing its own cluster, and everything is one cluster in one
failure domain besides. The edge stretch gestures at multi-cluster, but a
real second region needs replicated data, global load balancing, and a
failover runbook that has been executed, not written. I'd also want the
default-deny posture extended beyond the app namespace; monitoring and
kyverno currently trust their neighbors more than they should.

## 5. Runbook: the database primary dies

Symptoms: `ApiDatabaseUnreachable` pages, or /healthz starts returning 503
through the ingress while `/` still answers.

1. Look before touching: `kubectl -n qoves-app get cluster qoves-db` and
   `kubectl -n qoves-app get pods -l cnpg.io/cluster=qoves-db`. CNPG has
   probably already promoted the replica; `status.currentPrimary` tells you.
   In the drill, promotion completed and 503s stopped in well under a minute
   with zero manual action.
2. If a pod is stuck Pending or CrashLooping, `kubectl describe` it. The
   usual suspects, in order: PVC unbound (storage), the ResourceQuota
   rejecting the pod (check `kubectl -n qoves-app get quota`), or a netpol
   change that cut the instance off from the operator or its peer.
3. If the volume itself is gone (on this rig, that means the node's hostPath
   data), do not try to resurrect the pod. Recover from object storage
   through git: `./scripts/restore-drill.sh`, which commits a
   `bootstrap.recovery` Cluster reading the barman archive from MinIO, waits
   for it to come up, and verifies the data. Point the app at the restored
   cluster by changing the host in the sealed `DATABASE_URL` secret and the
   rw Service name, commit, let Argo sync.
4. Confirm recovery like a user would: `curl -H 'Host: qoves.local'
   http://<minikube-ip>/healthz` returns 200, the alert resolves, and
   `kubectl -n qoves-app get backups` shows the schedule still running
   against the new cluster.
5. Afterwards, write down what died and whether step 1's promotion was clean.
   Every change made during the incident should already be a commit, which
   makes the postmortem timeline `git log --since`.

The pattern underneath the specific steps: reads are free, the operator is
usually ahead of you, and any mutation goes through git even at 3am, because
the alternative is a cluster whose true state lives in someone's shell
history.
