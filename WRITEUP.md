# Writeup

## 1. Run it

Everything you need is in the README, so I'll keep this to the shape of the
thing. Two scripts stand up infrastructure by hand: `cluster-up.sh` (minikube
with two nodes, Cilium 1.19.6 pinned via its CLI, a local registry, and the
ingress, metrics-server and CSI hostpath addons) and `argocd-install.sh`
(Argo CD v3.4.6 plus the root Application). That second apply is the last
time a human touches the cluster. The root app points at `apps/`, where
eleven child Applications describe the rest of the platform, and Argo CD
reconciles them in sync-wave order: namespaces and quotas first, then the
operators (sealed-secrets, CloudNativePG, Kyverno, the Prometheus stack),
then sealed credentials and admission policies, then MinIO and the network
policies, then the database, and finally the API.

Waves matter less than they look like they should. Argo retries forever with
backoff, so the system would converge even with no ordering at all; the
waves mostly stop the first sync from looking like a wall of red while CRDs
land.

To change something, you edit a file and push. A resource limit, an alert
threshold, a Postgres image, all of it goes through a commit; the proofs in
`docs/proof/10-gitops-change.txt` show a pod-template change rolling out
seconds after the push. New code is the one flow with a tool in the middle:
`build-sign-push.sh` builds the image, pushes it by digest, signs the digest
with cosign, and rewrites the kustomize image pin, so the "deploy" is a
one-line diff that review can actually see. Third-party images get the same
treatment through `mirror-sign.sh`: pull upstream, push into our registry,
sign at ingestion. Producing artifacts is CI's job and stays outside git,
but the reference the cluster runs is always a pinned digest in a commit.

One lesson cost me twenty minutes and is worth passing on: my first change
demo bumped `spec.replicas` in git, and the HPA reverted it within seconds.
Both wanted to own the same field. The fix was removing `replicas` from the
manifest entirely, so the HPA is the single owner of scale and git owns
everything else. Fights like that one are quiet in a demo and very loud at
2am.

Secrets are the one deliberate chicken-and-egg. Ciphertext in git is sealed
against the key of a specific sealed-secrets controller, so on a fresh
cluster you run `seal-secrets.sh` after wave 1 and commit what it emits. The
repo you clone contains my ciphertext, which your controller cannot open.
That is the feature, not a bug, though it does mean the first bring-up has a
manual step in the middle and I'd rather admit that than hide it in a
Makefile.

## 2. Decisions

**Cilium over Calico.** Both enforce NetworkPolicy properly, and for the
core task either would have been fine, so the honest tiebreakers were
tooling and one stretch goal. The FQDN egress stretch ("allow exactly one
external domain") is a `toFQDNs` rule in a CiliumNetworkPolicy, which
vanilla NetworkPolicy simply cannot express. And Hubble earned its keep in a
way I didn't script: after the netpols went in, the database cluster
degraded with vague timeout errors, and `hubble observe --verdict DROPPED`
showed `qoves-db-2 -> qoves-db-1:8000` being denied in one line. That was
CNPG's instance managers running peer health checks on a port I hadn't
allowed. Guessing that from logs alone would have taken an hour; the fix is
one commit (`netpol: allow cnpg instance-manager peer checks on 8000`).
The trade: minikube's bundled `--cni=cilium` ships whatever version minikube
froze, so I install Cilium myself, pinned, right after cluster creation.
Also worth knowing that Cilium's default install does not implement
hostPort, which is why ingress access here goes to the controller's NodePort
rather than node port 80.

**Sealed Secrets over SOPS and External Secrets.** SOPS needs a decryption
plugin wired into Argo CD's repo server, which means patching the one
component I promised to keep boring. ESO is the right production answer but
only makes sense against a real store; running Vault in dev mode to feed it
felt like theater, and the brief explicitly rules out ESO's fake provider.
Sealed Secrets is fully local, needs nothing beyond its controller, and its
ciphertext is safe in a public repo. The trade I'm accepting: the sealing
key lives only in the cluster, so losing the cluster also bricks every
secret in git. Production would back that key up, or more likely graduate
to ESO with Vault and leave consumers untouched, since the API only ever
sees a plain Secret either way.

**CloudNativePG over a raw StatefulSet.** I went back and forth, since a
raw StatefulSet is fewer moving parts and the brief blesses it. The operator
won for two reasons. Failover: with two instances, killing the primary is a
promotion, not an outage that waits for a human. The chaos drill measured
it: under two requests per second through the ingress, deleting the primary
produced roughly 38 seconds of 503s before the replica took over and traffic
went clean, with no manual action (`docs/proof/14-chaos-primary-kill.txt`).
Backups: `barmanObjectStore` plus a ScheduledBackup gives WAL archiving and
a `bootstrap.recovery` restore path I could drill through git. Two caveats
I hit in practice rather than in docs. In-tree Barman is deprecated from
1.26 and removed in 1.31, so this config has a hard migration deadline to
the Barman Cloud Plugin; I stayed in-tree because the plugin drags in
cert-manager and I didn't want another moving part in a three-day build.
And the new image catalog's `-standard` flavor does not ship the
barman-cloud binaries at all, which surfaced as
`barman-cloud-check-wal-archive: executable file not found` mid-backup; the
classic `18.4` image still carries them. The image contents and the backup
mechanism are being decoupled upstream, and pinning the future-style image
against the deprecated backup path is the one combination that doesn't work.

**Supply chain: sign at ingestion, verify at admission.** Kyverno enforces
that every image in `qoves-app` carries a valid cosign signature from our
key; `docs/proof/06-unsigned-image-denied.txt` shows the admission denial
for an unsigned tag, and the database pods themselves were (briefly,
unintentionally) blocked the same way, which at least proves the gate is
real. My first plan was nicer on paper: verify CNPG's upstream images
keyless against their GitHub Actions identity, so provenance would chain to
the actual build. Their new sigstore bundle v0.3 signatures and Kyverno
1.18's keyless verifier would not agree ("no matching signatures found"
after every permutation I could defend), and I wasn't willing to ship a
policy I couldn't explain. So upstream images get mirrored into our
registry and signed by us at ingestion, which is the pattern most shops run
anyway: you depend on your own key at admission time, not on someone else's
signing infrastructure. Related gotcha, pinned here for the walkthrough:
cosign v3 defaults to the new bundle format, which Kyverno's key-based
verifier does not discover, so the signing scripts pass
`--new-bundle-format=false`.

**CPU HPA, knowingly wrong.** The HPA scales on 70% CPU because CPU is the
only signal metrics-server offers without extra machinery. For this API it
is close to the wrong signal: the handler is I/O-bound on Postgres, so the
failure mode under real load is latency climbing while CPU idles, and a CPU
HPA sleeps through it. Under my synthetic load it did fire, for what it's
worth: eight parallel curl loops took utilization from 5% to 167% inside a
minute and the deployment went 2 to 5 replicas, capped exactly where the
quota math says it should (`docs/proof/11-hpa-scale.txt`). The right signal
is requests per second or p95 latency per pod, which we already export via
`http_requests_total`; prometheus-adapter or KEDA feeding that into the HPA
is the first thing I'd add with another day. I kept CPU because a mis-tuned
custom-metrics pipeline is worse than an honest simple one.

**Readiness on /healthz, liveness on /.** This one is arguable and I want
to argue it. Gating readiness on the DB means a database outage pulls every
API pod out of the ingress, which amplifies a partial failure into a full
503 at the edge. I chose it anyway. Every meaningful endpoint of this API
needs Postgres, so serving traffic without it is serving errors with extra
steps; failing readiness sheds load at the LB, where it belongs. The kubelet
probing /healthz every ten seconds also gives Prometheus a steady per-pod
stream of DB reachability, which is exactly what the alert keys on.
Liveness stays on `/` so a DB outage never restarts healthy pods. If the
app had DB-free endpoints worth serving during an outage, I'd flip this.

**One alert.** `ApiDatabaseUnreachable` fires after five sustained minutes
of 503s from /healthz. It's actionable (check the DB pods, the PVC, the
netpols), it's user-facing (readiness is already shedding traffic when it
fires), and the `for: 5m` keeps single blips out of anyone's night. It's
also not hypothetical: the capture in `docs/proof/08-prometheus.txt` caught
it in `firing` state, picked up from the 503 burst of a live primary
switchover. I disabled the chart's hundred-odd default rules on purpose; a
pager that only speaks when users are hurting is the entire point of Part
H, and I'd rather defend one good alert than mute ninety bad ones in the
first on-call week.

## 3. What minikube did for me

On real metal, `minikube start` unfolds into about a week of work. It ran
the kubeadm-equivalent bootstrap: PKI, etcd, control plane static pods,
node join. I'd own all of that, plus keeping etcd healthy, which deserves
its own sentence: minikube runs a single etcd with no snapshot schedule,
and on metal I'd run a three-member cluster with `etcdctl snapshot save` on
a cron and a rehearsed restore, because losing etcd without a snapshot is
losing the cluster.

The ingress addon quietly stands in for a real edge. There is no cloud
LoadBalancer here; ingress-nginx sits behind a NodePort (Cilium's default
install doesn't do hostPort, a detail that cost me one confused curl).
Self-managed, I'd run MetalLB or BGP from the top-of-rack switches to hand
out VIPs, with keepalived or HAProxy in front if the edge had to survive a
node loss.

Storage is where minikube flattered me most, and where it bit hardest
during the build. The default hostPath provisioner hands out directories
owned by root that ignore `fsGroup` entirely, which crashes any non-root
pod with a PVC; under the `restricted` Pod Security level everything here
is non-root, so both MinIO and Postgres refused to start. The CSI hostpath
addon fixed it because it actually implements the fsGroup contract. On
metal this becomes a genuine CSI driver with replication, Longhorn if I
want easy, Ceph if I want serious, and the difference stops being academic
the first time a node dies: hostPath data dies with the node, replicated
CSI volumes do not. The CNI, meanwhile, came from one pinned `cilium
install` instead of a design meeting about pod CIDRs, encapsulation versus
native routing, and whether kube-proxy stays.

## 4. Production gaps

What stands between this and real traffic, roughly in the order I'd fix
it. The Postgres pair failed over cleanly in drills, but 38 seconds of
503s is an SLO conversation nobody's had yet, and its backups live in a
MinIO that shares the cluster's fate; offsite backups in a different
failure domain are non-negotiable, and the Barman Cloud Plugin migration
has a hard deadline at CNPG 1.31 regardless. The sealed-secrets key exists
in exactly one place, so today a cluster loss also bricks every secret in
git, which is the strongest argument for graduating to ESO plus Vault.
Nothing here upgrades: no Kubernetes version strategy, no node OS patching,
no rehearsed operator upgrades. The supply chain verifies signatures only
in `qoves-app`, with a signing key that lives on a laptop instead of KMS
with rotation, and no SBOM or provenance attestations; the keyless
verification of upstream builds that I abandoned belongs back on the
roadmap once the tooling agrees with itself. Argo CD is a single replica
managing its own cluster. The edge stretch shows one cluster driving
another, but a real second region needs replicated data, global load
balancing, and a failover runbook someone has actually executed. I'd also
extend default-deny beyond the app namespace; monitoring and kyverno
currently trust their neighbors more than they should.

## 5. Runbook: the database primary dies

Symptoms: `ApiDatabaseUnreachable` pages, or /healthz starts returning 503
through the ingress while `/` still answers.

1. Look before touching: `kubectl -n qoves-app get cluster qoves-db` and
   `kubectl -n qoves-app get pods -l cnpg.io/cluster=qoves-db`. CNPG has
   probably already promoted the replica; `status.currentPrimary` tells
   you. In the drill, promotion completed and 503s stopped roughly 40
   seconds after the primary died, with zero manual action. If that
   happened, your job is step 5, not heroics.
2. If a pod is stuck Pending or CrashLooping, `kubectl describe` it. The
   usual suspects, in order: PVC unbound (storage layer), the
   ResourceQuota rejecting the pod (`kubectl -n qoves-app get quota`), or
   a network policy cutting the instance off from its peer or the
   operator. For that last one, don't guess:
   `hubble observe --namespace qoves-app --verdict DROPPED` names the
   exact flow being denied, which is how the 8000/tcp peer-check gap was
   found during the build.
3. If the volume itself is gone (on this rig, node-local storage), do not
   resurrect the pod. Recover from object storage through git:
   `./scripts/restore-drill.sh` commits a `bootstrap.recovery` cluster
   that reads the barman archive from MinIO, waits for it to come up, and
   verifies the data (`docs/proof/12-restore-drill.txt` is a rehearsal of
   exactly this). The rehearsal earned its keep, too: the first attempt sat
   blocked because every DB netpol selected `cnpg.io/cluster: qoves-db` by
   name, so a restored cluster with a different name had no path to the API
   server. Untested restores aren't backups. Point the app at the restored cluster by updating the
   sealed `DATABASE_URL` and the service name, commit, let Argo sync.
4. Confirm like a user would: `curl -H 'Host: qoves.local'` against the
   ingress returns 200, the alert resolves, and `kubectl -n qoves-app get
   backups` shows the schedule running against the recovered cluster.
5. Write down what died and whether promotion was clean. Every mutation
   made during the incident is already a commit, so the postmortem
   timeline is `git log --since`, not someone's memory of their shell
   history.

The pattern underneath the steps: reads are free, the operator is usually
ahead of you, and any change goes through git even at 3am, because the
alternative is a cluster whose true state lives nowhere.
