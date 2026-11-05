#!/usr/bin/env bash
#
# Distribute the shared contracts package from backend/ to frontend/.
#
# The two submodules are independent repositories, so they cannot share a
# workspace. Instead the backend packs the package and the frontend installs the
# tarball at a pinned version (architecture section 4.6).
#
# The tarball's bytes are what `bun.lock` records, so this script installs from
# a clean state and fails loudly if the recorded integrity does not match. A
# stale tarball would otherwise only surface on a fresh CI checkout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACTS_DIR="$ROOT/backend/contracts"
VENDOR_DIR="$ROOT/frontend/vendor"

VERSION="$(python3 -c "import json;print(json.load(open('$CONTRACTS_DIR/package.json'))['version'])")"
TARBALL="social-resizer-contracts-${VERSION}.tgz"

echo "==> Building @social-resizer/contracts@${VERSION}"
(cd "$CONTRACTS_DIR" && bun install --silent && bun run build)

echo "==> Packing ${TARBALL}"
mkdir -p "$VENDOR_DIR"
rm -f "$VENDOR_DIR"/social-resizer-contracts-*.tgz
(cd "$CONTRACTS_DIR" && bun pm pack --destination "$VENDOR_DIR" >/dev/null)

echo "==> Reinstalling frontend from a clean state"
# Deleting the lockfile forces bun to re-record the tarball's integrity.
# `bun install` alone happily reuses a cached, now-stale hash.
rm -rf "$ROOT/frontend/node_modules" "$ROOT/frontend/bun.lock"
(cd "$ROOT/frontend" && bun install --silent)

echo "==> Verifying a frozen install (what CI does)"
rm -rf "$ROOT/frontend/node_modules"
(cd "$ROOT/frontend" && bun install --frozen-lockfile --silent)

echo "==> Done. frontend/ now consumes ${TARBALL}"
