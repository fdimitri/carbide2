# carbide2

Meta-repository for the **CARB/IDE2** stack. This repo owns the version
pointers (submodule SHAs) for the four component repos so they always build
together as a known-good set:

| Submodule | Repo | Role |
|-----------|------|------|
| `carbide2-client/`  | [fdimitri/carbide2-client](https://github.com/fdimitri/carbide2-client)   | Vue 3 + Vite + Monaco SPA (dashboard + workspace IDE) |
| `carbide2-server/`  | [fdimitri/carbide2-server](https://github.com/fdimitri/carbide2-server)   | Per-project workspace pod: Rails API, Postgres-backed FS, Helm chart |
| `carbide2-worker/`  | [fdimitri/carbide2-worker](https://github.com/fdimitri/carbide2-worker)   | EventMachine WebSocket worker — terminals/PTY, FS, chat, agent. Runs in the workspace pod |
| `carbide2-control/` | [fdimitri/carbide2-control](https://github.com/fdimitri/carbide2-control) | Control-plane Rails (auth, projects API) + Kubernetes operator (Workspace CR) |

[fdimitri/carbide2-docs](https://github.com/fdimitri/carbide2-docs) is a
companion repo, not yet a submodule here. The intent is that per-component
documentation moves into each component repo so it versions with the code it
describes, `carbide2-docs` keeps the global and generic material, and it pulls
the per-repo sections in at build time. Until then it's a separate checkout.

## Why a meta-repo

Nothing in the stack tracks the client, and no component tracks another. Each
repo can move on its own; this repo is the single place that records "client
version W goes with server X goes with worker Y goes with control Z".

The SPA is built once per **family** (`workspace` and `control` are different
bundles from the same source tree) and uploaded to a MinIO-backed static tier
at `/clients/<family>/<sha>/`, alongside a `registry.json`. Both the dashboard
and the workspace IDE load their client from that tier same-origin, so a build
is published in one place and served everywhere. A specific build can be pinned
per session with `?client=<family>@<sha>`, and `?client=latest` resets it.

The client isn't baked into any image. The workspace image consumes the worker
as a *named build context* (`--build-context worker=...`), so the component
Dockerfiles never clone anything — this repo's checkout supplies the source
trees.

## Prerequisites

Supported host: **Ubuntu 24.04 LTS** and **26.04** (both tested; other
Debian-family releases likely work but are untested). You need Docker (with
`buildx` + `compose`), `k3d`, `kubectl`, `helm`, and a managed Ruby + Bundler.
On a fresh box, install all of it with the provisioner:

```bash
git clone --recurse-submodules https://github.com/fdimitri/carbide2.git
cd carbide2
./scripts/setmeup.sh            # essentials only
./scripts/setmeup.sh --all      # + Node (client build/Playwright), socat (LLM relay), mkcert (TLS)
```

It's idempotent and skips anything already present. After it runs, **log out
and back in** (or `newgrp docker`) so the `docker` group and rbenv shell wiring
take effect. Known-working versions (pinned in `setmeup.sh`):

| Tool | Version |
|------|---------|
| Docker engine (+ buildx + compose v2) | 29.x |
| k3d | v5.8.3 |
| kubectl | v1.30+ |
| helm | v3.x |
| Ruby (via rbenv) | 3.4.2 |

> Other paths: `setmeup.sh` provisions the **k3d** deploy path used by
> `scripts/deploy.rb` (below). For the simpler single-host docker-compose
> stack instead, see `carbide2-server/INSTALL.md`.

Give the box **≥ 80 GB** of root disk — the images are large (`carbide2-shell`
alone is ~4 GB) and they live on the node's containerd, on the host root disk.

## Stand it up

Two paths. Both end at a serving dashboard; neither needs you to touch the
submodules by hand.

### Guided: `configure.rb`

```bash
./scripts/configure.rb
```

Serves a small HTTPS wizard (default `0.0.0.0:8099`, self-signed cert, minted
token printed to the terminal). It asks about topology, public URL, registry
and storage, shows the resolved settings as an editable tree, writes
`cluster.yaml`, and then runs `deploy.rb` for you with the output streamed back
to the page. For multi-node it runs the freeze-then-deploy sequence in the right
order — the step that's easiest to get wrong by hand.

The k3s backend needs root, so `sudo` is primed once in the terminal you
launched from and kept warm (a browser can't answer a password prompt). Pass
`--no-sudo` if you're only deploying k3d.

### Direct: `deploy.rb`

One idempotent command from nothing to a serving dashboard. It updates itself
and the submodules, brings up the cluster and infra (CNPG, Traefik, Postgres,
MinIO), builds the images, imports them into the cluster, builds and uploads
the pinned SPA clients to the static tier, installs the Workspace CRD, and
installs/upgrades the control plane. Re-run it after any code change; it also
rolls the workspace pods.

**Single node on k3d** — the zero-config baseline; the example matches
`defaults.yaml`, so bare `./scripts/deploy.rb` does the same thing. Storage is
node-local `local-path`, and k3d publishes the ingress on host 8080/8443.

```bash
./scripts/deploy.rb --config examples/k3d-local.yaml
```

Dashboard at <https://localhost:8443/> (plain-HTTP <http://localhost:8080/>
redirects there; the dev cert is self-signed, so your browser will warn the
first time). The seed user is `admin@example.com` / `password`.

**Single node on host-native k3s** — no Docker-in-the-middle; the ingress binds
the host's real 80/443 via klipper ServiceLB, so the box is reachable at its own
FQDN with no port mapping.

```bash
./scripts/deploy.rb --config examples/k3s-single-local.yaml
```

Set `public.host` in that file if `hostname -f` isn't the name you actually
browse to — it drives the ingress host rule, the mkcert SAN, and host-based
auth.

**Multi-node k3s with Longhorn** — a two-step flow, because `cluster.token` must
be minted once and shared: freeze the resolved config, then deploy every node
from that one frozen file. Pods can land on any node, so images come from a
self-hosted registry rather than a per-node import.

```bash
./scripts/deploy.rb --config examples/k3s-multinode-longhorn.yaml \
    --cluster.server-url https://<this-node>:6443 --yaml-out cluster.yaml
./scripts/deploy.rb --config cluster.yaml                      # first node
./scripts/deploy.rb --config cluster.yaml --cluster.role join  # every other node
```

Read [KUBE.md](KUBE.md) before running that one
— the registry CA trust, the join sequence, and the freeze-vs-deploy distinction
all matter, and the header comment in the example config walks through why each
override is there.

Useful flags:

| Flag | Effect |
|------|--------|
| `--no-build` | Skip the image build; re-import and redeploy only |
| `--no-client` | Skip building/uploading the SPA client |
| `--no-shell` | Build everything except the `carbide2-shell` image |
| `--no-infra` | Skip cluster/infra bring-up |
| `--no-pull` | Skip the self-update (git pull + submodules) step |
| `--no-tls` | Skip mkcert TLS setup (Traefik default cert) |
| `--cluster.backend k3s` | Deploy to host-native k3s instead of k3d |
| `--storage.backend longhorn` | Replicated RWO storage (multi-node) |
| `--registry.host HOST` | Push SHA-tagged images to a self-hosted registry every node pulls from |

Configuration is three layers merged last-wins: `scripts/defaults.yaml`, then
`--config <file>`, then any `--a.b.c` CLI flag. There are no ENV knobs. Freeze
the fully-resolved config with `--yaml-out FILE` (or `--yaml-safeout FILE` to
redact secrets); freezing exits without deploying. `--help` lists everything.

The orchestrator is Ruby: it shells out to `docker`/`k3d`/`helm` for the
build/deploy steps but reads cluster state (pod readiness, Workspace CR phases)
through `kubeclient` — the same client the operator uses — for its verification
report. The gems it needs are installed on first run via `bundler/inline`.

## Building images without deploying

```bash
./scripts/build-all.sh
```

Produces `carbide2:dev` (workspace pod — Rails + worker), `carbide2-control:dev`
(control plane + operator), and `carbide2-shell:dev` (the per-project terminal
container). This only builds images; `deploy.rb` is what puts the stack on a
cluster.

## Licence

GPLv3. See `LICENSE`.
