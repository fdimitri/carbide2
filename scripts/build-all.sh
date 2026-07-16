#!/usr/bin/env bash
# Build the workspace and control-plane images from this meta-repo's
# checkout. Each image consumes carbide2-client/ as a named build
# context so the component Dockerfiles never need to know where the
# client lives.
#
# Requires Docker with BuildKit (docker buildx).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLIENT="$ROOT/carbide2-client"
SERVER="$ROOT/carbide2-server"
CONTROL="$ROOT/carbide2-control"
WORKER="$ROOT/carbide2-worker"

for d in "$CLIENT" "$SERVER" "$CONTROL" "$WORKER"; do
  [ -d "$d" ] || { echo "missing submodule: $d (run: git submodule update --init)" >&2; exit 1; }
done

short_sha() {
  git -C "$1" rev-parse --short=12 HEAD
}

META_SHA="$(short_sha "$ROOT")"
CLIENT_SHA="$(short_sha "$CLIENT")"
SERVER_SHA="$(short_sha "$SERVER")"
CONTROL_SHA="$(short_sha "$CONTROL")"
WORKER_SHA="$(short_sha "$WORKER")"
BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "==> [1/3] carbide2:dev (workspace pod)"
docker buildx build --load \
  -t carbide2:dev \
  --build-arg "META_SHA=$META_SHA" \
  --build-arg "CLIENT_SHA=$CLIENT_SHA" \
  --build-arg "SERVER_SHA=$SERVER_SHA" \
  --build-arg "WORKER_SHA=$WORKER_SHA" \
  --build-arg "BUILD_TIME=$BUILD_TIME" \
  --build-context "client=$CLIENT" \
  --build-context "worker=$WORKER" \
  "$SERVER"

echo "==> [2/3] carbide2-control:dev (control plane + dashboard)"
docker buildx build --load \
  -t carbide2-control:dev \
  --build-arg "META_SHA=$META_SHA" \
  --build-arg "CLIENT_SHA=$CLIENT_SHA" \
  --build-arg "CONTROL_SHA=$CONTROL_SHA" \
  --build-arg "BUILD_TIME=$BUILD_TIME" \
  --build-context "client=$CLIENT" \
  "$CONTROL"

# The workspace shell pod (per-project terminal container) runs this image.
# The operator defaults CARBIDE_SHELL_IMAGE to carbide2-shell:dev, so the
# cluster expects this tag to exist or shell pods ImagePullBackOff.
# SKIP_SHELL=1 skips this (slow) build — safe when carbide2-shell:dev already
# exists and only client/server/control code changed.
if [ -n "${SKIP_SHELL:-}" ]; then
  echo "==> [3/3] carbide2-shell:dev — SKIPPED (SKIP_SHELL set)"
else
  echo "==> [3/3] carbide2-shell:dev (per-project terminal container)"
  docker buildx build --load \
    -t carbide2-shell:dev \
    -f "$SERVER/Dockerfile.shell" \
    "$SERVER"
fi

echo
echo "Done. Images:"
# docker --format strips leading literal spaces, so anchor on the repo name and
# indent the display ourselves with sed.
docker images --format '{{.Repository}}:{{.Tag}}  {{.Size}}' \
  | grep -E '^(carbide2|carbide2-control|carbide2-shell):dev' \
  | sed 's/^/  /'
