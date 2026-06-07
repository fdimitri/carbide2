# Installing CARB/IDE2

This is the **meta-repo** install guide: it takes a clean host from nothing to a
running CARB/IDE2 stack (control plane + dashboard, with per-project workspace
pods) on a local k3d cluster.

The two tools that do the work:

| Script | Purpose |
|--------|---------|
| [`scripts/setmeup.sh`](scripts/setmeup.sh) | Provision a clean host with every dependency `deploy.rb` needs. |
| [`scripts/deploy.rb`](scripts/deploy.rb) | Build images, bring up the cluster + infra, install the charts, set up TLS, verify. Idempotent — also the redeploy path. |

> Component-specific notes live in [`carbide2-server/INSTALL.md`](carbide2-server/INSTALL.md)
> (docker-compose dev, volume layout) and [`carbide2-server/DEPLOY-k3d.md`](carbide2-server/DEPLOY-k3d.md).

---

## 0. Requirements

- **Ubuntu 24.04 LTS (Noble), amd64.** `setmeup.sh` hard-gates on this; other
  Debian-family releases probably work but are untested (`--force` to try).
- A normal (non-root) user with `sudo`. Do **not** run the scripts as root.
- Outbound network access (pulls Docker, kubectl, helm, k3d, Ruby).
- **Whatever machine and browser you'll reach the dashboard from** must trust
  the root CA (§5) — this is independent of the deploy host's OS. The supported
  cases are Windows, Linux, or macOS with their default browser, or Firefox on
  any platform. (When the deploy host is WSL2 the browser is almost always the
  Windows side, but a remote browser on any other box works the same way.)

## 1. Provision the host

```bash
git clone --recurse-submodules https://github.com/fdimitri/carbide2.git
cd carbide2
./scripts/setmeup.sh --mkcert     # add --node for host-side Vite/Playwright; --all for everything
```

Installs (skipping anything already present at the pinned version): apt build
deps, Docker + buildx + compose, `kubectl v1.30.0`, helm, `k3d v5.8.3`,
rbenv + `Ruby 3.4.2` + bundler, and — behind flags — node / socat / mkcert.

**Then log out and back in** (or `newgrp docker && exec $SHELL -l`) so the
`docker` group membership and rbenv shell wiring take effect. Verify:

```bash
docker ps          # works without sudo
rbenv version      # 3.4.2
```

## 2. Choose what to deploy

The default branch is `main` (the deployable line). To deploy in-progress work
from `dev`, check it out and refresh submodules:

```bash
git checkout dev
git submodule update --init --recursive
```

`deploy.rb` self-updates to `main` by default (`DEPLOY_REF`/`--ref` overrides);
pass `--no-pull` to deploy **exactly what you have checked out** (required when
deploying local/dev work — see §4).

## 3. Deploy

A real box is reached by hostname, so the TLS cert SANs and the Rails host
allowlist must cover its FQDN. `deploy.rb` refuses to silently guess
`localhost`:

```bash
export PUBLIC_HOST="$(hostname -f)"      # or e.g. carbide-ws3.frankd.local
export TLS_HOSTS="$PUBLIC_HOST localhost 127.0.0.1 ::1 <box-LAN-IP>"
./scripts/deploy.rb
```

Pipeline: ensure k3d cluster `carbide-dev` + infra → build the three images
(`carbide2:dev`, `carbide2-control:dev`, `carbide2-shell:dev`) → import into the
cluster → apply the Workspace CRD → helm-install the control plane → roll +
verify. First run is slow (Ruby was source-built; helper gems compile).

When it finishes, the dashboard serves at **`https://<PUBLIC_HOST>:8443/`**.

### Ports

`HTTP_PORT` / `HTTPS_PORT` are env knobs (defaults `8080` / `8443`). For a
production-style deploy on the standard HTTPS port:

```bash
HTTPS_PORT=443 HTTP_PORT=80 PUBLIC_HOST="$(hostname -f)" ./scripts/deploy.rb
# dashboard then at https://<PUBLIC_HOST>/  (no port suffix)
```

## 4. Iterating / redeploying

`deploy.rb` is idempotent. Useful flags:

| Flag | Effect |
|------|--------|
| `--no-pull` | Skip the self-update; deploy exactly what's checked out. **Use this for local/dev work.** |
| `--no-build` | Skip the image build; re-import + redeploy existing images. |
| `--no-infra` | Skip cluster/infra bring-up (cluster already exists). |
| `--no-tls` | Skip mkcert TLS (Traefik's default self-signed cert). |
| `--ref <branch>` / `DEPLOY_REF` | Which meta-repo ref to deploy (default `main`). |
| `--roll-scope all\|control\|none` | Which deployments to restart after deploy. |

Apply only a fresh TLS cert without rebuilding: `./scripts/deploy.rb --no-build --no-infra --no-pull`.

Cluster lifecycle:

```bash
k3d cluster stop  carbide-dev
k3d cluster start carbide-dev
k3d cluster delete carbide-dev      # full teardown
```

## 5. Trust the root CA (the one manual step `wss://` needs)

CARB/IDE2 uses WebSockets over TLS (`wss://`). A browser's click-through on an
untrusted cert does **not** extend to the WS connection, so `wss://` silently
fails until the signing CA is trusted on the machine running the browser.

`deploy.rb` exports the mkcert root CA to **`carbide-rootCA.pem`** in the repo
root and prints per-OS import steps at the end of a TLS run. Copy that file to
the browser machine and import it:

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

Fully restart the browser afterward. **Firefox** keeps its own store — import via
Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import.

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
so it needs a separate import **even if** you already trusted the CA for the
system or Chrome:

- Settings → Privacy & Security → Certificates → **View Certificates…**
- **Authorities** tab → **Import…** → select `carbide-rootCA.pem`
- Check **“Trust this CA to identify websites.”** → OK, then restart Firefox.

## 6. Verify

- Dashboard loads at `https://<PUBLIC_HOST>:<HTTPS_PORT>/` with no cert warning.
- Create a project → the workspace pod comes up → a terminal opens and a file
  edit round-trips.
- Cluster health: `kubectl get pods -A` (control plane in `carbide-system`,
  workspaces in `ws-*`).

## 7. Real (non-mkcert) certificates

For a CA-signed cert instead of mkcert, two standalone steps bracket your CA and
touch nothing else:

```bash
PUBLIC_HOST=host.example.com ./scripts/deploy.rb --csr        # writes tls/<host>.key + .csr — submit the CSR
./scripts/deploy.rb --import-cert ./tls/<host>.crt            # loads the signed cert into the Traefik default
```
