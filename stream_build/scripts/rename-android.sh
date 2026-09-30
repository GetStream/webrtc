#!/usr/bin/env bash
# Copy libwebrtc.aar into PRODUCTS/renamed/. The Android wrapper publishes
# that filename as-is (Maven coords live in stream-video-android-webrtc).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

NAME="libwebrtc.aar"
SRC=""
DEST_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC="$2"; shift 2 ;;
    --dest) DEST_DIR="$2"; shift 2 ;;
    *) die "rename-android.sh: unknown flag $1" ;;
  esac
done

[[ -n "$SRC" && -n "$DEST_DIR" ]] || die "rename-android.sh requires --src --dest"
[[ -f "$SRC" ]] || die "no AAR at $SRC"
base="$(basename "$SRC")"
[[ "$base" == "$NAME" ]] || die "expected $NAME, got $base"

mkdir -p "$DEST_DIR"
src_abs="$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")"
dest_abs="$(cd "$DEST_DIR" && pwd)/$NAME"
[[ "$src_abs" != "$dest_abs" ]] || die "refusing to overwrite input $SRC"

cp "$src_abs" "$dest_abs"
echo "copied $src_abs -> $dest_abs"
echo "original preserved at $src_abs"
