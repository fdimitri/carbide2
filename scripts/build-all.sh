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

echo "==> [1/3] carbide2:dev (workspace pod)"
docker buildx build --load \
  -t carbide2:dev \
  --build-context "client=$CLIENT" \
  --build-context "worker=$WORKER" \
  "$SERVER"

echo "==> [2/3] carbide2-control:dev (control plane + dashboard)"
docker buildx build --load \
  -t carbide2-control:dev \
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
