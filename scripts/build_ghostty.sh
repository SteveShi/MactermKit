#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-main}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/ThirdParty/src/ghostty"
OUT_DIR="$ROOT/ThirdParty/lib"

mkdir -p "$ROOT/ThirdParty/src" "$OUT_DIR"

if [[ ! -d "$SRC" ]]; then
  git clone https://github.com/ghostty-org/ghostty.git "$SRC"
else
  git -C "$SRC" fetch --tags
fi

echo "Checking out Ghostty version $VERSION..."
git -C "$SRC" checkout "$VERSION"

# Apply MactermKit-specific patches (e.g. ghostty_surface_pid for exposing
# the PTY child pid). Idempotent: skipped if already applied.
PATCH_FILE="$ROOT/scripts/ghostty_surface_pid.patch"
if [[ -f "$PATCH_FILE" ]]; then
  if git -C "$SRC" apply --check "$PATCH_FILE" 2>/dev/null; then
    git -C "$SRC" apply "$PATCH_FILE"
    echo "Applied patch: $PATCH_FILE"
  else
    echo "Patch not applicable (already applied or version mismatch), skipping"
  fi
fi

ZIG_BIN="${ZIG_BIN:-}"
if [[ -z "$ZIG_BIN" && -x /opt/homebrew/opt/zig@0.15/bin/zig ]]; then
  ZIG_BIN="/opt/homebrew/opt/zig@0.15/bin/zig"
fi
if [[ -z "$ZIG_BIN" ]]; then
  ZIG_BIN="$(command -v zig || true)"
fi
if [[ -z "$ZIG_BIN" ]]; then
  echo "Zig is required to build Ghostty. Please set ZIG_BIN or ensure zig is in PATH."
  exit 1
fi

if [[ -z "${SDKROOT:-}" ]]; then
  export SDKROOT="$(xcrun --show-sdk-path 2>/dev/null || true)"
fi

(
  cd "$SRC"
  "$ZIG_BIN" build -Dapp-runtime=none -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native
)

rm -rf "$OUT_DIR/MactermKitCore.xcframework"
mv "$SRC/macos/GhosttyKit.xcframework" "$OUT_DIR/MactermKitCore.xcframework"

# Update modulemap to MactermKitCore
cat << 'EOF' > "$OUT_DIR/MactermKitCore.xcframework/macos-arm64/Headers/module.modulemap"
module MactermKitCore {
    umbrella header "ghostty.h"
    export *
}
EOF

echo "MactermKitCore.xcframework generated and copied to $OUT_DIR"
