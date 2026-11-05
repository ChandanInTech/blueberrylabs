#!/usr/bin/env bash
#
# Distribute the shared contracts package from backend/ to frontend/.
#
# The two submodules are independent repositories, so they cannot share a
# workspace. Instead the backend packs the package and the frontend installs the
# tarball at a pinned version (architecture section 4.6).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACTS_DIR="$ROOT/backend/contracts"
VENDOR_DIR="$ROOT/frontend/vendor"

VERSION="$(python3 -c "import json,sys; print(json.load(open('$CONTRACTS_DIR/package.json'))['version'])")"
TARBALL="social-resizer-contracts-${VERSION}.tgz"

echo "==> Building @social-resizer/contracts@${VERSION}"
(cd "$CONTRACTS_DIR" && bun install --silent && bun run build)

echo "==> Packing ${TARBALL}"
mkdir -p "$VENDOR_DIR"
rm -f "$VENDOR_DIR"/social-resizer-contracts-*.tgz
(cd "$CONTRACTS_DIR" && bun pm pack --destination "$VENDOR_DIR" >/dev/null)

echo "==> Installing into frontend/"
(cd "$ROOT/frontend" && bun install --silent)

echo "==> Done. frontend/ now consumes ${TARBALL}"
