# KUBE.md — Quick orientation for inspecting the carbide2 dev cluster

You don't need to know Kubernetes to operate this — most of it is automation.
What follows is the minimum mental model plus the commands you can paste to
see what's going on.

## Mental model in 60 seconds

- **Cluster** = a Kubernetes control plane + worker nodes. Ours runs locally
  inside Docker via **k3d** (k3s-in-Docker). Cluster name: `carbide-dev`.
- **Node** = a machine (or container) that runs your workloads. We have one.
- **Namespace** = a folder for resources. Ours of interest:
  - `kube-system`, `traefik`, `cnpg-system` — infrastructure.
  - `carbide-system` — the shared Postgres (CloudNativePG, "CNPG") cluster.
  - `ws-1`, `ws-2`, ... — one per workspace/project.
- **Pod** = the running container(s). One `ws-1` pod runs the Rails server.
- **Deployment** = a controller that keeps N pods alive and rolls updates.
- **Service** = a stable cluster-internal DNS name + IP for a set of pods.
  e.g. `ws-1.ws-1.svc.cluster.local:3000` reaches the workspace Rails app.
- **IngressRoute** (Traefik CRD) = "route external HTTP `/w/1/*` to the
  `ws-1` service". This is how the browser reaches the workspace.
- **PVC** (PersistentVolumeClaim) = a disk attached to a pod. Each workspace
  has one for `/srv/projects/<projectId>`.
- **Helm chart** = a templated bundle of K8s manifests + a values file. Our
  per-workspace chart is `carbide2-server/charts/workspace`; each install of it
  is a **release** (e.g. `ws-1`).
- **CRD** = a custom resource type registered by an operator. Traefik adds
  `IngressRoute`; CNPG adds `Cluster` and `Database`.

## Layout

Paths are relative to this meta-repo; `carbide2-server/` is the submodule.

| Path                                           | What it is                                    |
| ---------------------------------------------- | --------------------------------------------- |
| `scripts/deploy.rb`                            | Brings up the node (k3d or host-native k3s), Traefik, CNPG, Postgres, MinIO. `--cluster.role init` for the first node, `--cluster.role join` to add another control-plane server. |
| `scripts/lib/carbide_node.rb`                  | `Carbide::Node` — the Ruby node lifecycle (create/install/join, registry CA trust, shared infra). Replaced the old `dev-cluster-*.sh` / `dev-agent-k3s.sh` bash scripts. |
| `scripts/examples/`                            | Copyable starting configs: k3d single-node, k3s single-node, k3s multi-node + Longhorn. |
| `carbide2-server/deploy/cnpg-cluster.yaml`     | The shared `carbide-pg` Postgres definition.  |
| `carbide2-server/charts/workspace/`            | Per-workspace Helm chart (deploy + svc + ingress + PVC + test pod). |
| `carbide2-server/scripts/smoke-test.sh`        | HTTP probe of `/up` via Traefik.              |
| `carbide2-server/scripts/test-rails.sh`        | `rails test` inside the workspace pod.        |
| `carbide2-server/scripts/test-substrate.sh`    | Runs all 4 test layers in order.              |
| `carbide2-server/.github/workflows/substrate-tests.yml` | CI: builds everything from scratch and runs the orchestrator. |

## Multi-node: the self-hosted registry

Single-node dev (k3d, or one-node k3s) needs no registry — deploy.rb imports the
built images straight into that node's containerd. But a **multi-node** cluster
schedules pods on nodes that never saw `docker build`, so those pods
`ImagePullBackOff`. The fix is a self-hosted registry every node pulls from.

Enable it by passing `--registry.host` to deploy.rb (opt-in; unset = the
single-node import path):

```sh
# On the deploy host (also the first k3s server node):
./scripts/deploy.rb --cluster.backend k3s --registry.host <this-host-fqdn>
```

What that does:

- Brings up a standalone `registry:2` container on the deploy host over TLS
  (cert minted from the same carbide mkcert root CA), independent of the cluster.
- Builds **immutable, per-component SHA-tagged** images and pushes them:
  `carbide2:<server>-<worker>`, `carbide2-control:<control>`,
  `carbide2-shell:<server>`. Re-deploys skip build+push when the tag already
  exists.
- Pins those tags into the control-plane chart, so the operator stamps them onto
  workspace/shell pods and every node pulls the same image.

**Automatic per node** — every k3s node must trust the registry CA so its
containerd can pull over TLS. `Carbide::Node` does this for you on both `--role
init` and `--role join`: it writes `/etc/rancher/k3s/registries.yaml` from the CA
**inlined in the emitted config** (`registry.ca`), so there's no PEM to scp
between machines. It's idempotent — the file is only rewritten (and k3s only
restarted) when the CA actually changes.

## Multi-node: adding more nodes

`deploy.rb --cluster.backend k3s` (`--cluster.role init`, the default) brings up
the **first k3s server** on the deploy host. To make the cluster multi-node, each
additional machine joins as a **full control-plane server** (HA embedded etcd),
not a second-class agent — every node is homogeneous and consumes the **same
emitted config**.

On the **first node**, first **freeze** the resolved config — this mints
`cluster.token` (on `--role init`), records the server URL other nodes reach it
on, and writes `cluster.yaml`. `--yaml-out` **exits without deploying**: it is a
freeze step, not the deploy.

```sh
./scripts/deploy.rb --cluster.backend k3s --registry.host <server-fqdn> \
  --cluster.server-url https://<server-ip-or-fqdn>:6443 \
  --yaml-out cluster.yaml            # cluster.yaml carries the real token — keep it secret
```

Then **deploy** the first node *from the frozen file*. `cluster.token` is now
present, so it is reused, not re-minted:

```sh
./scripts/deploy.rb --config cluster.yaml
```

Copy `cluster.yaml` to each **other node** (it already inlines the registry CA,
so there's nothing else to hand-carry), then run there:

```sh
./scripts/deploy.rb --config cluster.yaml --cluster.role join
```

`Carbide::Node` trusts the registry CA, installs k3s as a joining **server**
(`server --server https://…:6443`, same shared token), and syncs kubeconfig. No
infra is re-installed — the shared cluster already has Traefik/CNPG/MinIO. Verify
on any node:

```sh
kubectl get nodes -o wide                # every node should show up, Ready
```

Cross-node networking (flannel) and the `carbide-pg`/`minio` Services work across
nodes automatically, so workspace pods scheduled on any node reach the shared
Postgres and the MinIO client tier without extra config. Uninstall a node with
`sudo /usr/local/bin/k3s-uninstall.sh`.

## Multi-node: a dedicated build/registry host (no k3s)

The default flow co-locates the registry + image builds on the k3s server. If you
want the (slow, from-source) image builds and the registry on a **separate,
beefier box that runs no k3s** — e.g. a WSL2 machine — split the deploy into two
roles with `--publish-only` / `--external-registry`:

**Build/registry host** (`--publish-only`, no k3s/helm — just docker + mkcert):

```sh
cd ~/repos/carbide2 && git pull && git submodule update --init --recursive
./scripts/deploy.rb --publish-only --registry.host <build-host-fqdn> --ref <ref>
```

This stands up the `registry:2` container, builds the SHA-tagged images, and
pushes them — then stops. The registry's mkcert root CA is inlined into the
emitted config for the k3s nodes to consume (see below), so there's no PEM to
scp around.

**k3s server** (`--external-registry` — pulls the already-pushed images, skips the
local registry + build). First **freeze** the resolved config (mints the token,
inlines the registry CA, then exits without deploying):

```sh
cd ~/repos/carbide2 && git pull && git submodule update --init --recursive
./scripts/deploy.rb --cluster.backend k3s --external-registry \
  --registry.host <build-host-fqdn> --registry.ca-file ./carbide-rootCA.pem \
  --cluster.server-url https://<server-ip-or-fqdn>:6443 \
  --ref <ref> --public.host <browser-fqdn> --yaml-out cluster.yaml
```

> Supply the registry CA with `--registry.ca-file PATH` (reads the file) — not by
> pasting the PEM into a plain YAML scalar, whose folded newlines containerd
> can't parse. If you must inline it in YAML, use a `|` block scalar (`ca: |`).

Then **deploy** the server *from the frozen file*:

```sh
./scripts/deploy.rb --config cluster.yaml
```

The server still builds+uploads the SPA client to in-cluster MinIO (that needs
cluster access, so it can't run on the build host) — the heavy *image* builds are
what moved to the build box. **Other nodes** then join with
`deploy.rb --config cluster.yaml --cluster.role join` exactly as in the section
above; the emitted `cluster.yaml` already carries the registry host + inlined CA,
so they trust and pull from the build host automatically.

Requirements for the split:

- The registry FQDN (`--registry.host`) must **resolve and be reachable on
  `:5000` from every k3s node** (server + agents), pointing at the build host —
  independent of the browser `--public.host` name, which only the browser needs.
- With **WSL2 mirrored networking** the VM shares the Windows host's network, so
  the registry port is reachable directly — nothing extra to do. (Only WSL2's
  default *NAT* mode needs a Windows-side `netsh interface portproxy` forwarding
  `:5000` into the VM.)

## The "show me everything" commands

Most useful inspection commands, roughly in the order you'd reach for them:

```sh
# Where am I pointing? Which cluster does kubectl talk to?
kubectl config current-context        # should be: k3d-carbide-dev

# All pods everywhere, with status and restart counts.
kubectl get pods -A

# A specific namespace.
kubectl -n ws-1 get all
kubectl -n carbide-system get cluster,pods   # CNPG status

# Why is X unhappy? "describe" shows events at the bottom.
kubectl -n ws-1 describe pod ws-1-<hash>

# Logs (the workspace Rails server log).
kubectl -n ws-1 logs deploy/ws-1                    # current container
kubectl -n ws-1 logs deploy/ws-1 -c workspace --tail=200
kubectl -n ws-1 logs deploy/ws-1 -p                 # previous (crashed) container
kubectl -n ws-1 logs -f deploy/ws-1                 # follow / tail -f

# Open a shell inside the workspace pod.
kubectl -n ws-1 exec -it deploy/ws-1 -c workspace -- bash

# Quick one-shot command in the pod.
kubectl -n ws-1 exec deploy/ws-1 -c workspace -- bundle exec rails runner 'puts Project.count'

# What services and ingress routes exist?
kubectl -n ws-1 get svc
kubectl -n ws-1 get ingressroute

# Disk usage (PVCs).
kubectl get pvc -A
```

## Helm — installed apps

```sh
helm list -A                                      # all installed releases
helm -n ws-1 status ws-1                          # current state of one release
helm -n ws-1 get values ws-1                      # the values it was installed with
helm -n ws-1 get manifest ws-1 | less             # rendered YAML actually applied
helm -n ws-1 upgrade ws-1 carbide2-server/charts/workspace --reuse-values
helm test ws-1 -n ws-1                            # run the chart's smoke pod
helm -n ws-1 uninstall ws-1                       # remove the release entirely
```

## Talking to the workspace from outside the cluster

Traefik listens on host port `8080` (and `8443`). The workspace ingress
strips the `/w/<projectId>` prefix and forwards to the pod's port 3000.

```sh
curl -i http://localhost:8080/w/1/up              # Rails health endpoint
curl    http://localhost:8080/w/1/                # the app itself
```

If you ever get a `403` with a "Blocked host" page, that's Rails 8's
`config.hosts` allowlist refusing the request — not Traefik. Either go
through `localhost`/Traefik, or add the host to `config.hosts` for that env.

## Talking to Postgres directly

CNPG manages a primary pod called `carbide-pg-1`. Credentials live in a
secret named `carbide-pg-app`.

```sh
# Open psql inside the primary pod (uses the app role automatically):
kubectl -n carbide-system exec -it carbide-pg-1 -- psql

# List databases / sizes:
kubectl -n carbide-system exec -it carbide-pg-1 -- psql -c '\l+'

# CNPG status (replication, switchover, backups):
kubectl -n carbide-system get cluster carbide-pg -o yaml | less
```

Note: in dev we grant the `carbide` role `CREATEDB` + `SUPERUSER` via
`deploy/cnpg-cluster.yaml` so Rails can run `db:create`/`db:drop` for the
test database. **Do not** copy that into production.

## When something is "stuck"

- Pod status `Pending` → look at `kubectl describe`; usually a PVC has no
  storage class or there's a scheduling constraint nothing satisfies.
- Pod status `CrashLoopBackOff` → `kubectl logs ... -p` to see the previous
  crash output.
- Pod status `ImagePullBackOff` → the image isn't on the node. For k3d:
  `k3d image import carbide2:dev -c carbide-dev`.
- Helm release stuck `pending-upgrade` → `helm history` then
  `helm rollback`.

## Tearing it all down

```sh
k3d cluster stop  carbide-dev   # keeps state on disk
k3d cluster start carbide-dev
k3d cluster delete carbide-dev  # wipes everything in the cluster
```

The Docker image (`carbide2:dev`) and the cloned repo are unaffected by any
of these.
