#!/usr/bin/env bash
# setmeup.sh — provision a clean host with everything deploy.rb needs.
#
# Target: Ubuntu 24.04 LTS (Noble) and 26.04 — confirmed working without
# intervention. Other Debian-family releases will probably work but are
# UNTESTED — the script warns and continues if --force is given.
#
# What it installs:
#   ESSENTIAL (always, unless already present):
#     - apt build/runtime deps (build-essential, libpq-dev, libssl-dev, …)
#     - Docker engine + buildx + compose v2  (Ubuntu's docker.io + plugin pkgs)
#     - kubectl, helm                         (pinned upstream releases)
#     - k3d                                    (default backend; k3s-in-Docker.
#                                              Skipped with --kube-backend=k3s,
#                                              where dev-cluster-k3s.sh installs
#                                              host-native k3s at deploy time)
#     - rbenv + ruby-build + Ruby + bundler   (to run deploy.rb under a writable
#                                              gem dir; deploy.rb re-execs here)
#     - mkcert (+ libnss3-tools)              (locally-trusted TLS certs so wss://
#                                              works; skip with --no-mkcert)
#     - MinIO client as 'mcli'                 (build-client uploads SPA builds to
#                                              the MinIO static tier; installed as
#                                              'mcli' because Debian's 'mc' package
#                                              is Midnight Commander. --no-minio-client
#                                              skips)
#   OPTIONAL (behind flags):
#     --node       Node.js 20 (Vite client build outside containers + Playwright)
#     --socat      socat      (host LM Studio relay for local LLM agents)
#     --no-mkcert  skip the default mkcert install (bring your own TLS / --no-tls)
#     --no-minio-client  skip the default MinIO client (mcli) install
#     --kube-backend=k3s  provision for host-native k3s instead of k3d (skips the
#                  k3d install; k3s itself is installed by deploy.rb at run time)
#     --registry-host=HOST  trust a self-hosted registry on THIS node so it can
#                  pull SHA-tagged images: installs the registry CA into the OS
#                  trust store and writes /etc/rancher/k3s/registries.yaml. Run
#                  on every k3s node (server + agents). Pair with --registry-ca=PATH
#                  (default ./carbide-rootCA.pem, exported by deploy.rb) and
#                  optionally --registry-port=PORT (default 5000).
#     --all        all of the above optionals
#
# After this finishes (and you re-login for the docker group), the deploy is:
#     git clone --recurse-submodules https://github.com/fdimitri/carbide2.git
#     cd carbide2 && ./scripts/deploy.rb
#
# Idempotent: re-running skips anything already present at the pinned version.
# Pinned versions are the ones verified on the reference box (Ubuntu 24.04.2).
#
# END-OF-HELP

set -euo pipefail

# --- pinned tool versions (verified known-working) --------------------------
KUBECTL_VERSION="v1.30.0"
HELM_GET_URL="https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"
K3D_VERSION="v5.8.3"
RUBY_VERSION="3.4.2"
NODE_MAJOR="20"
# MinIO client, installed as 'mcli' (Debian's 'mc' package is Midnight Commander).
MINIO_MC_RELEASE="RELEASE.2025-08-13T08-35-41Z"

# --- flags ------------------------------------------------------------------
WANT_NODE=0
WANT_SOCAT=0
WANT_MKCERT=1
WANT_MINIO_CLIENT=1
FORCE=0
# Which local Kubernetes backend to provision for. k3d (default) is k3s-in-Docker
# and is installed here. k3s is host-native and is installed at deploy time by
# carbide2-server/scripts/dev-cluster-k3s.sh (with the right --disable flags), so
# for k3s we just skip the k3d binary and leave docker/kubectl/helm in place.
KUBE_BACKEND=k3d
# Optional self-hosted registry trust (see configure_registry_trust). Read from
# env here so REGISTRY_HOST=... setmeup.sh works; flags below override.
REGISTRY_HOST="${REGISTRY_HOST:-}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
REGISTRY_CA="${REGISTRY_CA:-carbide-rootCA.pem}"
for arg in "$@"; do
  case "$arg" in
    --node)      WANT_NODE=1 ;;
    --socat)     WANT_SOCAT=1 ;;
    --mkcert)    WANT_MKCERT=1 ;;
    --no-mkcert) WANT_MKCERT=0 ;;
    --minio-client)    WANT_MINIO_CLIENT=1 ;;
    --no-minio-client) WANT_MINIO_CLIENT=0 ;;
    --kube-backend=*)  KUBE_BACKEND="${arg#*=}" ;;
    --k3d)       KUBE_BACKEND=k3d ;;
    --k3s)       KUBE_BACKEND=k3s ;;
    --registry-host=*) REGISTRY_HOST="${arg#*=}" ;;
    --registry-port=*) REGISTRY_PORT="${arg#*=}" ;;
    --registry-ca=*)   REGISTRY_CA="${arg#*=}" ;;
    --all)       WANT_NODE=1; WANT_SOCAT=1; WANT_MKCERT=1; WANT_MINIO_CLIENT=1 ;;
    --force)     FORCE=1 ;;
    -h|--help)
      sed -n '2,/END-OF-HELP/p' "$0" | sed -e '/END-OF-HELP/d' -e 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "setmeup: unknown arg: $arg (try --help)" >&2; exit 1 ;;
  esac
done

case "$KUBE_BACKEND" in
  k3d|k3s) ;;
  *) echo "setmeup: unknown --kube-backend '$KUBE_BACKEND' (expected k3d or k3s)" >&2; exit 1 ;;
esac

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Trust a self-hosted registry on THIS node: install its CA into the OS trust
# store (curl/docker) and, for k3s, pin the CA in registries.yaml so containerd
# can pull over TLS. One-time per node; run on the server and every agent.
configure_registry_trust() {
  local host="$1" port="$2" ca="$3"
  local endpoint="$host"
  [[ "$host" == *:* ]] || endpoint="$host:$port"

  [[ -f "$ca" ]] || die "registry CA not found: $ca (copy the deploy host's carbide-rootCA.pem here, or pass --registry-ca=PATH)"

  log "trusting registry CA for $endpoint (OS trust store + k3s registries.yaml)"
  sudo install -m 0644 "$ca" /usr/local/share/ca-certificates/carbide-registry-ca.crt
  sudo update-ca-certificates >/dev/null

  local ca_dest="/etc/rancher/k3s/carbide-registry-ca.pem"
  sudo mkdir -p /etc/rancher/k3s
  sudo install -m 0644 "$ca" "$ca_dest"
  # NOTE: this replaces any existing registries.yaml.
  sudo tee /etc/rancher/k3s/registries.yaml >/dev/null <<YAML
configs:
  "$endpoint":
    tls:
      ca_file: "$ca_dest"
YAML

  if systemctl is-active --quiet k3s 2>/dev/null; then
    log "restarting k3s to pick up registries.yaml"
    sudo systemctl restart k3s
  elif systemctl is-active --quiet k3s-agent 2>/dev/null; then
    log "restarting k3s-agent to pick up registries.yaml"
    sudo systemctl restart k3s-agent
  else
    log "k3s not running yet — registries.yaml takes effect when it starts"
  fi
}

[[ $EUID -eq 0 ]] && die "do not run as root — run as your normal user; the script uses sudo where needed."
have sudo || die "sudo not found — install it or run the apt/install steps manually."

# --- OS gate ----------------------------------------------------------------
# Confirmed working without intervention: Ubuntu 24.04 and 26.04. Other
# Debian-family releases likely work but are untested; --force overrides.
OS_ID="$( . /etc/os-release 2>/dev/null && echo "${ID:-}" )"
OS_VER="$( . /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}" )"
OS_OK=0
if [[ "$OS_ID" == "ubuntu" ]]; then
  case "$OS_VER" in
    24.04|26.04) OS_OK=1 ;;
  esac
fi
if [[ $OS_OK -ne 1 ]]; then
  if [[ $FORCE -eq 1 ]]; then
    warn "OS is ${OS_ID:-unknown} ${OS_VER:-?}, not a confirmed Ubuntu (24.04/26.04) — continuing because --force was given (UNTESTED)."
  else
    die "this provisioner is confirmed only on Ubuntu 24.04 and 26.04 (found: ${OS_ID:-unknown} ${OS_VER:-?}). Re-run with --force to try anyway."
  fi
fi

ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
[[ "$ARCH" == "amd64" ]] || warn "architecture is '$ARCH', not amd64 — pinned binaries below assume amd64 and may fail."

# ---------------------------------------------------------------------------
# 1. apt packages (build/runtime deps + Docker + buildx + compose)
# ---------------------------------------------------------------------------
# The 'pg' gem needs libpq-dev; ruby-build needs the -dev headers; postgresql-client
# gives psql for poking at the CNPG database. docker.io is Ubuntu's Docker engine;
# docker-buildx-plugin / docker-compose-v2 are SEPARATE packages (build-all.sh
# uses `docker buildx build --load`, quickstart.sh uses `docker compose`).
APT_PKGS=(
  build-essential git curl ca-certificates gnupg lsb-release
  pkg-config libpq-dev libyaml-dev libffi-dev zlib1g-dev libssl-dev
  libreadline-dev libsqlite3-dev autoconf bison
  postgresql-client
  docker.io docker-buildx docker-compose-v2
)
[[ $WANT_SOCAT -eq 1 ]] && APT_PKGS+=(socat)

log "apt-get update"
sudo apt-get update -y
log "installing apt packages: ${APT_PKGS[*]}"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_PKGS[@]}"

# ---------------------------------------------------------------------------
# 2. Docker daemon + group membership
# ---------------------------------------------------------------------------
log "enabling + starting docker daemon"
sudo systemctl enable --now docker >/dev/null 2>&1 || warn "could not enable docker via systemctl (WSL/no-systemd? start dockerd manually)."

if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
  log "adding $USER to the 'docker' group"
  sudo usermod -aG docker "$USER"
  NEED_RELOGIN=1
fi

# ---------------------------------------------------------------------------
# 3. kubectl (pinned upstream binary — apt's is often stale)
# ---------------------------------------------------------------------------
if have kubectl; then
  log "kubectl already present: $(kubectl version --client 2>/dev/null | head -1)"
else
  log "installing kubectl ${KUBECTL_VERSION}"
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
  sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm -f /tmp/kubectl
fi

# ---------------------------------------------------------------------------
# 4. helm
# ---------------------------------------------------------------------------
if have helm; then
  log "helm already present: $(helm version --short 2>/dev/null)"
else
  log "installing helm (latest v3 via get-helm-3)"
  curl -fsSL "$HELM_GET_URL" | bash
fi

# ---------------------------------------------------------------------------
# 5. k3d (pinned)
# ---------------------------------------------------------------------------
# Only for the k3d backend. For k3s, dev-cluster-k3s.sh installs k3s host-native
# at deploy time (with the traefik/local-storage disables), so there's nothing
# to pre-install here beyond the docker/kubectl/helm already handled above.
if [[ "$KUBE_BACKEND" == "k3d" ]]; then
  if have k3d; then
    log "k3d already present: $(k3d version 2>/dev/null | head -1)"
  else
    log "installing k3d ${K3D_VERSION}"
    curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | TAG="${K3D_VERSION}" bash
  fi
else
  log "kube-backend=k3s — skipping k3d; deploy.rb's dev-cluster-k3s.sh installs k3s (host-native) at deploy time"
fi

# ---------------------------------------------------------------------------
# 6. rbenv + Ruby + bundler
# ---------------------------------------------------------------------------
# deploy.rb installs helper gems via bundler/inline, which needs a Ruby whose gem
# dir is writable. A managed rbenv Ruby gives that (and deploy.rb explicitly
# re-execs under ~/.rbenv/shims/ruby when the active gem dir isn't writable).
RBENV_ROOT="${RBENV_ROOT:-$HOME/.rbenv}"
if [[ ! -d "$RBENV_ROOT" ]]; then
  log "installing rbenv into $RBENV_ROOT"
  git clone --depth 1 https://github.com/rbenv/rbenv.git "$RBENV_ROOT"
  git clone --depth 1 https://github.com/rbenv/ruby-build.git "$RBENV_ROOT/plugins/ruby-build"
else
  log "rbenv already present at $RBENV_ROOT"
fi

# Make rbenv available for the rest of THIS script run.
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"
eval "$(rbenv init - bash)"

# Persist to ~/.bashrc once.
if ! grep -q 'rbenv init' "$HOME/.bashrc" 2>/dev/null; then
  log "wiring rbenv into ~/.bashrc"
  {
    echo ''
    echo '# rbenv (added by carbide2 setmeup.sh)'
    echo "export PATH=\"$RBENV_ROOT/bin:\$PATH\""
    echo 'eval "$(rbenv init - bash)"'
  } >> "$HOME/.bashrc"
  NEED_RELOGIN=1
fi

if rbenv versions --bare 2>/dev/null | grep -qx "$RUBY_VERSION"; then
  log "Ruby $RUBY_VERSION already installed via rbenv"
else
  log "installing Ruby $RUBY_VERSION via ruby-build (compiles from source — slow)"
  rbenv install -s "$RUBY_VERSION"
fi
rbenv global "$RUBY_VERSION"
rbenv rehash

if ! gem list -i bundler >/dev/null 2>&1; then
  log "installing bundler"
  gem install bundler --no-document
  rbenv rehash
fi

# ---------------------------------------------------------------------------
# 7. Optional: Node.js (Vite build outside containers + Playwright)
# ---------------------------------------------------------------------------
if [[ $WANT_NODE -eq 1 ]]; then
  if have node; then
    log "node already present: $(node -v)"
  else
    log "installing Node.js ${NODE_MAJOR}.x via NodeSource"
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
  fi
fi

# ---------------------------------------------------------------------------
# 8. mkcert (locally-trusted TLS — default; --no-mkcert skips)
# ---------------------------------------------------------------------------
# deploy.rb's setup_tls uses mkcert so wss:// works without a real CA; browser
# trust needs libnss3-tools (certutil) alongside the mkcert binary.
if [[ $WANT_MKCERT -eq 1 ]]; then
  if have mkcert; then
    log "mkcert already present: $(mkcert -version 2>/dev/null)"
  else
    log "installing mkcert (+ libnss3-tools for browser trust) via apt"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mkcert libnss3-tools || \
      warn "apt mkcert install failed — install manually from github.com/FiloSottile/mkcert if you need local TLS (or deploy with --no-tls)."
  fi
else
  log "skipping mkcert (--no-mkcert) — deploy.rb needs --no-tls or your own certs for wss://"
fi

# ---------------------------------------------------------------------------
# 8b. MinIO client as 'mcli' (default; --no-minio-client skips)
# ---------------------------------------------------------------------------
# scripts/build-client uploads compiled SPA builds to the MinIO static tier with
# this client. It is installed as 'mcli' on purpose: Debian/Ubuntu's 'mc' package
# is GNU Midnight Commander (a file manager), which would otherwise shadow it.
if [[ $WANT_MINIO_CLIENT -eq 1 ]]; then
  if have mcli && mcli --version 2>&1 | grep -qi minio; then
    log "MinIO client already present: $(mcli --version 2>/dev/null | head -1)"
  else
    log "installing MinIO client ${MINIO_MC_RELEASE} as /usr/local/bin/mcli"
    if curl -fsSLo /tmp/mcli "https://dl.min.io/client/mc/release/linux-${ARCH}/archive/mc.${MINIO_MC_RELEASE}"; then
      sudo install -m 0755 /tmp/mcli /usr/local/bin/mcli
      rm -f /tmp/mcli
    else
      warn "MinIO client download failed — install manually from dl.min.io (as 'mcli') if you plan to run scripts/build-client."
    fi
  fi
else
  log "skipping MinIO client (--no-minio-client) — scripts/build-client needs 'mcli' (or CARBIDE_MC) to upload builds"
fi

# ---------------------------------------------------------------------------
# 9. Optional: trust a self-hosted registry on this node (--registry-host)
# ---------------------------------------------------------------------------
if [[ -n "$REGISTRY_HOST" ]]; then
  configure_registry_trust "$REGISTRY_HOST" "$REGISTRY_PORT" "$REGISTRY_CA"
fi
echo
log "provisioning complete. Versions:"
SUMMARY_TOOLS=(docker kubectl helm ruby bundle)
[[ "$KUBE_BACKEND" == "k3d" ]] && SUMMARY_TOOLS+=(k3d)
for t in "${SUMMARY_TOOLS[@]}"; do
  if have "$t"; then
    case "$t" in
      docker)  printf '  %-9s %s\n' docker  "$(docker --version 2>/dev/null)";;
      kubectl) printf '  %-9s %s\n' kubectl "$(kubectl version --client 2>/dev/null | head -1)";;
      helm)    printf '  %-9s %s\n' helm    "$(helm version --short 2>/dev/null)";;
      k3d)     printf '  %-9s %s\n' k3d     "$(k3d version 2>/dev/null | head -1)";;
      ruby)    printf '  %-9s %s\n' ruby    "$(ruby -v 2>/dev/null)";;
      bundle)  printf '  %-9s %s\n' bundler "$(bundle -v 2>/dev/null)";;
    esac
  else
    printf '  %-9s (MISSING)\n' "$t"
  fi
done
if have mcli && mcli --version 2>&1 | grep -qi minio; then
  printf '  %-9s %s\n' mcli "$(mcli --version 2>/dev/null | head -1)"
fi

cat <<EOF

Next:
  git clone --recurse-submodules https://github.com/fdimitri/carbide2.git
  cd carbide2 && ./scripts/deploy.rb

EOF

if [[ "${NEED_RELOGIN:-0}" -eq 1 ]]; then
  warn "log out and back in (or run: newgrp docker && exec \$SHELL -l) so the"
  warn "'docker' group membership and rbenv shell wiring take effect before deploying."
fi
