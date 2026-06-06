#!/usr/bin/env bash
# setmeup.sh — provision a clean host with everything deploy.rb needs.
#
# Target: Ubuntu 24.04 LTS (Noble). Known-working there. Other Debian-family
# releases will probably work but are UNTESTED — the script warns and continues
# if --force is given.
#
# What it installs:
#   ESSENTIAL (always, unless already present):
#     - apt build/runtime deps (build-essential, libpq-dev, libssl-dev, …)
#     - Docker engine + buildx + compose v2  (Ubuntu's docker.io + plugin pkgs)
#     - kubectl, helm, k3d                    (pinned upstream releases)
#     - rbenv + ruby-build + Ruby + bundler   (to run deploy.rb under a writable
#                                              gem dir; deploy.rb re-execs here)
#   OPTIONAL (behind flags):
#     --node      Node.js 20 (Vite client build outside containers + Playwright)
#     --socat     socat       (host LM Studio relay for local LLM agents)
#     --mkcert    mkcert      (locally-trusted TLS certs; deploy.rb --no-tls skips)
#     --all       all of the above optionals
#
# After this finishes (and you re-login for the docker group), the deploy is:
#     git clone --recurse-submodules https://github.com/fdimitri/carbide2.git
#     cd carbide2 && ./scripts/deploy.rb
#
# Idempotent: re-running skips anything already present at the pinned version.
# Pinned versions are the ones verified on the reference box (Ubuntu 24.04.2).

set -euo pipefail

# --- pinned tool versions (verified known-working) --------------------------
KUBECTL_VERSION="v1.30.0"
HELM_GET_URL="https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"
K3D_VERSION="v5.8.3"
RUBY_VERSION="3.4.2"
NODE_MAJOR="20"

# --- flags ------------------------------------------------------------------
WANT_NODE=0
WANT_SOCAT=0
WANT_MKCERT=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --node)   WANT_NODE=1 ;;
    --socat)  WANT_SOCAT=1 ;;
    --mkcert) WANT_MKCERT=1 ;;
    --all)    WANT_NODE=1; WANT_SOCAT=1; WANT_MKCERT=1 ;;
    --force)  FORCE=1 ;;
    -h|--help)
      sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "setmeup: unknown arg: $arg (try --help)" >&2; exit 1 ;;
  esac
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[[ $EUID -eq 0 ]] && die "do not run as root — run as your normal user; the script uses sudo where needed."
have sudo || die "sudo not found — install it or run the apt/install steps manually."

# --- OS gate ----------------------------------------------------------------
OS_ID="$( . /etc/os-release 2>/dev/null && echo "${ID:-}" )"
OS_VER="$( . /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}" )"
if [[ "$OS_ID" != "ubuntu" || "$OS_VER" != "24.04" ]]; then
  if [[ $FORCE -eq 1 ]]; then
    warn "OS is ${OS_ID:-unknown} ${OS_VER:-?}, not ubuntu 24.04 — continuing because --force was given (UNTESTED)."
  else
    die "this provisioner is verified only on Ubuntu 24.04 (found: ${OS_ID:-unknown} ${OS_VER:-?}). Re-run with --force to try anyway."
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
if have k3d; then
  log "k3d already present: $(k3d version 2>/dev/null | head -1)"
else
  log "installing k3d ${K3D_VERSION}"
  curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | TAG="${K3D_VERSION}" bash
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
# 8. Optional: mkcert (locally-trusted TLS)
# ---------------------------------------------------------------------------
if [[ $WANT_MKCERT -eq 1 ]]; then
  if have mkcert; then
    log "mkcert already present: $(mkcert -version 2>/dev/null)"
  else
    log "installing mkcert via apt"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mkcert || \
      warn "apt mkcert install failed — install manually from github.com/FiloSottile/mkcert if you need local TLS."
  fi
fi

# ---------------------------------------------------------------------------
# 9. Summary
# ---------------------------------------------------------------------------
echo
log "provisioning complete. Versions:"
for t in docker kubectl helm k3d ruby bundle; do
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

cat <<EOF

Next:
  git clone --recurse-submodules https://github.com/fdimitri/carbide2.git
  cd carbide2 && ./scripts/deploy.rb

EOF

if [[ "${NEED_RELOGIN:-0}" -eq 1 ]]; then
  warn "log out and back in (or run: newgrp docker && exec \$SHELL -l) so the"
  warn "'docker' group membership and rbenv shell wiring take effect before deploying."
fi
