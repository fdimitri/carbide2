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

echo "==> [1/2] carbide2:dev (workspace pod)"
docker buildx build --load \
  -t carbide2:dev \
  --build-context "client=$CLIENT" \
  --build-context "worker=$WORKER" \
  "$SERVER"

echo "==> [2/2] carbide2-control:dev (control plane + dashboard)"
docker buildx build --load \
  -t carbide2-control:dev \
  --build-context "client=$CLIENT" \
  "$CONTROL"

echo
echo "Done. Images:"
docker images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' | grep -E '^  carbide2(-control)?:dev'
