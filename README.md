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

Produces two images locally:

- `carbide2:dev` — workspace pod (used by the operator for per-project pods)
- `carbide2-control:dev` — control-plane Rails + operator + bundled dashboard SPA

## Local k3d stack

```bash
./scripts/dev-cluster.sh   # creates the carbide-dev cluster + installs CNPG, traefik, control plane
```

Then visit <http://localhost:8088/> for the dashboard.

## Licence

GPLv3. See `LICENSE`.
