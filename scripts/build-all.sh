#!/usr/bin/env bash
# Compatibility shim: the image build lives in scripts/build.rb now (shared with
# scripts/deploy.rb via scripts/lib/carbide_images.rb). This wrapper is kept so
# existing docs/scripts that call build-all.sh keep working. It forwards all
# args and honours the old REGISTRY / SKIP_SHELL env knobs (build.rb reads them).
set -euo pipefail
exec ruby "$(dirname "$0")/build.rb" "$@"
