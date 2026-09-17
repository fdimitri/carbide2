# Installing CARB/IDE2

This is the **meta-repo** install guide: it takes a clean host from nothing to a
running CARB/IDE2 stack (control plane + dashboard, with per-project workspace
pods) on a local k3d cluster. The same two scripts also drive multi-node k3s and
a self-hosted image registry — those are covered in `KUBE.md`.

The two tools that do the work:

| Script | Purpose |
|--------|---------|
| [`scripts/setmeup.sh`](scripts/setmeup.sh) | Provision a clean host with every dependency `deploy.rb` needs. |
| [`scripts/deploy.rb`](scripts/deploy.rb) | Build images, bring up the cluster + infra, install the charts, set up TLS, verify. Idempotent — also the redeploy path. |

> `./scripts/deploy.rb --help` lists every option. All configuration is flags +
> YAML (`--config`), not environment variables.

---

## 0. Requirements

- **Ubuntu 24.04 LTS (Noble) or 26.04, amd64.** `setmeup.sh` gates on these;
  other Debian-family releases probably work but are untested (`--force` to try).
- A normal (non-root) user with `sudo`. Do **not** run the scripts as root.
- Outbound network access (pulls Docker, kubectl, helm, k3d, Ruby, images).
- **The machine + browser you'll reach the dashboard from** must trust the root
  CA (§5) — independent of the deploy host's OS. Supported: Windows, Linux, macOS
  with the default browser, or Firefox on any platform.

---

## 1. Provision the host

```bash
git clone --recurse-submodules https://github.com/fdimitri/carbide2.git
cd carbide2
./scripts/setmeup.sh
```

Installs (skipping anything already at the pinned version): apt build deps,
Docker + buildx + compose, `kubectl`, helm, rbenv + Ruby + bundler, and — for the
k3d backend — `k3d`. mkcert and the MinIO client (`mcli`) are on by default.

Useful flags:

| Flag | Effect |
|------|--------|
| `--k3d` / `--k3s` / `--kube-backend=k3d\|k3s` | Pick the backend up front (otherwise it asks). k3s itself is installed by `deploy.rb` at deploy time, not here. |
| `--node` | Install Node.js 20 (Vite/Playwright outside containers). |
| `--socat` | socat (host LM Studio relay for local LLM agents). |
| `--no-mkcert` | Skip mkcert (then `deploy.rb --no-tls`, or bring your own certs). |
| `--registry-host=HOST` `--registry-ca=PATH` | Trust a self-hosted registry's CA in the OS store on this node. |
| `--all` / `--force` | Turn on everything off-by-default / bypass the OS gate. |

**Then log out and back in** (or `newgrp docker && exec $SHELL -l`) so the
`docker` group membership and rbenv shell wiring take effect. Verify:

```bash
docker ps          # works without sudo
rbenv version      # 3.4.2
```

---

## 2. Configuration model

`deploy.rb` reads three layers, last one wins:

1. `scripts/defaults.yaml` — every default lives here.
2. `--config input.yaml` — an override file (see `scripts/examples/`).
3. CLI flags — every `--a.b.c` flag sets the `a.b.c` key.

There are **no environment-variable knobs.** The blocks that matter (ADR-028):

- **`node`** — what this box *is*: `backend` (k3d / k3s / none), `role` (k3s init / join).
- **`images`** — what it *does* with images: `build`, `shell`, `push`, `consume` (auto / import / pull).
- **`registry`** — where the registry is: `host`, `port`, `ca`, `serve`.
- **`cluster`** — shared cluster facts: `name`, `http-port`, `https-port`, `server-url`, `token`.
- **`storage`** — `backend` (local-path / longhorn).
- **`public`** — browser-facing `host` / `url`.
- **`jwt`** — signing-key `secret` + host-side `key-dir`.

Emit the fully-resolved config (secrets included) to a file without deploying:

```bash
./scripts/deploy.rb --yaml-out cluster.yaml       # secrets included — keep it safe
./scripts/deploy.rb --yaml-safeout cluster.safe.yaml  # secrets redacted
```

---

## 3. Deploy (single-node k3d, the default)

```bash
./scripts/deploy.rb
```

That's the whole thing for a local dev box. `deploy.rb` resolves the
browser-facing hostname from `--public.host`, falling back to `hostname -f`; it
**refuses to silently guess `localhost`**, so on a box reachable by name, pass it:

```bash
./scripts/deploy.rb --public.host carbide-ws3.frankd.local
```

Pipeline: ensure k3d cluster `carbide-dev` + infra → build images → import into
the cluster → apply the Workspace CRD → helm-install the control plane → roll +
verify. First run is slow (Ruby source-built; helper gems compile).

When it finishes, the dashboard serves at
**`https://<host>:8443/`** (or `--cluster.https-port` if you overrode it).

### Ports

```bash
./scripts/deploy.rb --cluster.http-port 80 --cluster.https-port 443
# dashboard then at https://<host>/  (no port suffix)
```

---

## 4. Multi-node k3s + self-hosted registry

Single-node k3d imports local `:dev` images; a multi-node cluster needs a
registry every node pulls SHA-tagged images from. This is covered in depth in
`KUBE.md`; the short version:

```bash
# one box serves the registry + pushes SHA tags
./scripts/deploy.rb --node.backend k3s --registry.host <fqdn> --registry.serve --images.push
# other boxes join as control-plane servers
./scripts/deploy.rb --config cluster.yaml --node.role join
```

Replicated storage on multi-node:

```bash
./scripts/deploy.rb --storage.backend longhorn
```

---

## 5. Iterating / redeploying

`deploy.rb` is idempotent. Common flags:

| Flag | Effect |
|------|--------|
| `--ref <branch>` | Meta-repo ref to deploy (default `main`). |
| `--no-pull` | Skip self-update; deploy **exactly what's checked out** (required for local/dev work). |
| `--no-images.build` | Skip image build (re-import + redeploy). |
| `--no-images.shell` | Build everything except the slow `carbide2-shell` image. |
| `--no-client` | Skip building + uploading the pinned SPA client. |
| `--no-infra` | Skip cluster/infra bring-up (already exists). |
| `--no-tls` | Skip mkcert TLS (Traefik default cert). |
| `--roll-scope all\|control\|none` | Which deployments to restart after deploy. |
| `--config FILE` | Merge a YAML config over the defaults. |

Cluster lifecycle:

```bash
k3d cluster stop  carbide-dev
k3d cluster start carbide-dev
k3d cluster delete carbide-dev      # full teardown
```

---

## 6. Trust the root CA (the one manual step `wss://` needs)

CARB/IDE2 uses WebSockets over TLS (`wss://`). A browser's click-through on an
untrusted cert does **not** extend to the WS connection, so `wss://` silently
fails until the signing CA is trusted on the machine running the browser.

`deploy.rb` exports the mkcert root CA to **`carbide-rootCA.pem`** in the repo
root and prints per-OS import steps at the end of a TLS run. Copy it to the
browser machine and import it.

### Copy it off the deploy host

```bash
scp <user>@<deploy-host>:~/carbide2/carbide-rootCA.pem .
```

### Windows (Chromium/Edge use the Windows store; no admin needed)

```powershell
# certutil (cmd or PowerShell):
certutil.exe -addstore -user -f Root carbide-rootCA.pem
# …or PowerShell-native:
Import-Certificate -FilePath .\carbide-rootCA.pem -CertStoreLocation Cert:\CurrentUser\Root
```

Under **WSL2** the browser is on the Windows host — copy across the mount first:

```bash
cp carbide-rootCA.pem /mnt/c/Users/Public/carbide-rootCA.pem
# then in Windows:  certutil.exe -addstore -user -f Root C:\Users\Public\carbide-rootCA.pem
```

Fully restart the browser afterward.

### Linux

```bash
# System trust store (curl, Node, etc.):
sudo cp carbide-rootCA.pem /usr/local/share/ca-certificates/carbide-rootCA.crt   # must end in .crt
sudo update-ca-certificates

# Chrome/Chromium use NSS, not the system store — needs libnss3-tools:
sudo apt-get install -y libnss3-tools
certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n "carbide" -i carbide-rootCA.pem
```

(If mkcert is installed on the browser machine, `mkcert -install` after copying
its CAROOT achieves the same thing.)

### macOS

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain carbide-rootCA.pem
```

### Firefox (any platform)

Firefox ships its own certificate store and ignores the OS/system trust above,
so it needs a separate import **even if** you already trusted the CA elsewhere:

- Settings → Privacy & Security → Certificates → **View Certificates…**
- **Authorities** tab → **Import…** → select `carbide-rootCA.pem`
- Check **"Trust this CA to identify websites."** → OK, then restart Firefox.

---

## 7. Verify

- Dashboard loads at `https://<host>:<https-port>/` with no cert warning.
- Create a workspace → the workspace pod comes up → a terminal opens and a file
  edit round-trips.
- Cluster health: `kubectl get pods -A` (control plane in `carbide-system`,
  workspaces in `ws-*`).

---

## 8. Real (non-mkcert) certificates

For a CA-signed cert instead of mkcert, two standalone steps bracket your CA and
touch nothing else:

```bash
./scripts/deploy.rb --public.host host.example.com --csr
# → writes tls/<host>.key + tls/<host>.csr — submit the CSR to your CA
./scripts/deploy.rb --import-cert ./tls/<host>.crt
# → loads the signed cert (+ the .key) as the Traefik default
```
