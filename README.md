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

## Installing

See **[INSTALL.md](INSTALL.md)** for the full walkthrough: prerequisites,
`setmeup.sh`, the `deploy.rb` config model (three layers, no ENV knobs), the
single-node k3d deploy, multi-node k3s + self-hosted registry, the CA-trust step
`wss://` needs, and real-cert setup. `KUBE.md` covers cluster inspection and the
multi-node registry in depth.

In short, from a clean box:

```bash
git clone --recurse-submodules https://github.com/fdimitri/carbide2.git
cd carbide2
./scripts/setmeup.sh     # provision the host; log out/in for the docker group
./scripts/deploy.rb      # k3d single-node baseline
```

The two deploy entry points are:

- **`./scripts/configure.rb`** — a small HTTPS wizard (default `:8099`) that asks
  about topology, registry, and storage, writes `cluster.yaml`, and runs
  `deploy.rb` for you, streaming output back to the page. `--no-sudo` skips the
  root prompt when you're only deploying k3d.
- **`./scripts/deploy.rb`** — the idempotent orchestrator. `--help` lists every
  option; configuration is `scripts/defaults.yaml` → `--config <file>` →
  `--a.b.c` flags, with no environment-variable knobs.

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
