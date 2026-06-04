# carbide2

Meta-repository for the **CARB/IDE2** stack. This repo owns the version
pointers (submodule SHAs) for the three component repos so they always
build together as a known-good triple:

| Submodule | Repo | Role |
|-----------|------|------|
| `carbide2-client/`  | [fdimitri/carbide2-client](https://github.com/fdimitri/carbide2-client)   | Vue 3 + Vite + Monaco SPA (dashboard + workspace IDE) |
| `carbide2-server/`  | [fdimitri/carbide2-server](https://github.com/fdimitri/carbide2-server)   | Per-project workspace pod (Rails + worker + WS + PTY + Postgres‑backed FS) |
| `carbide2-control/` | [fdimitri/carbide2-control](https://github.com/fdimitri/carbide2-control) | Control-plane Rails (auth, projects API) + Kubernetes operator (Workspace CR) |

## Why a meta-repo

The client SPA is built and shipped twice — once into the workspace image
(`carbide2-server`) and once into the control-plane image (`carbide2-control`)
as the dashboard. They **must** be the same build; if they drift, the dashboard
and the IDE start disagreeing about API contracts and WS protocol versions.

Vendoring the client as a submodule in *both* server and control would force
two separate hash bumps every time the client moves, and they could easily
fall out of sync. Instead, neither server nor control tracks the client at
all. This meta-repo is the single place that records "client version X goes
with server version Y goes with control version Z".

Docker builds consume the client as a *named build context*
(`--build-context client=...`), so the component Dockerfiles never need to
clone anything — the meta-repo's checkout supplies the source tree.

## Clone

```bash
git clone --recurse-submodules https://github.com/fdimitri/carbide2.git
cd carbide2
```

Or update an existing checkout:

```bash
git submodule update --init --recursive
git submodule update --remote --merge   # advance each submodule to its latest main
```

## Build everything

Requires Docker with BuildKit (`docker buildx`):

```bash
./scripts/build-all.sh
```

Produces three images locally:

- `carbide2:dev` — workspace pod (used by the operator for per-project pods)
- `carbide2-control:dev` — control-plane Rails + operator + bundled dashboard SPA
- `carbide2-shell:dev` — per-project terminal container the workspace pod spawns

## Deploy the local k3d stack

One idempotent command takes a machine from nothing to a serving dashboard.
It builds the images, brings up the `carbide-dev` cluster (CNPG, Traefik,
Postgres), imports the images into the cluster, installs the Workspace CRD,
and installs/upgrades the control-plane (Rails dashboard + operator):

```bash
./scripts/deploy.rb
```

Re-run it any time to rebuild and redeploy after a code change — it also
rolls the workspace pods. Flags: `--no-build` (skip image build, just
re-import + redeploy) and `--no-infra` (skip cluster/infra bring-up).

The orchestrator is Ruby: it shells out to `docker`/`k3d`/`helm` for the
build/deploy steps but reads cluster state (pod readiness, Workspace CR
phases) through `kubeclient` — the same client the operator uses — for its
verification report. Requires `ruby` + `bundler` on the host; the two gems
it needs are installed on first run via `bundler/inline`.

Then visit <https://localhost:8443/> for the dashboard (the plain-HTTP
<http://localhost:8080/> redirects there; the dev cert is self-signed, so
your browser will warn the first time). The seed user is
`admin@example.com` / `password`.

> `./scripts/build-all.sh` only builds images; `./scripts/deploy.rb` is what
> actually puts the stack on the cluster. Running `build-all.sh` plus the
> infra-only `carbide2-server/scripts/dev-cluster.sh` leaves Traefik up with
> no routes — every URL 404s until the control plane is deployed.

## Licence

GPLv3. See `LICENSE`.
