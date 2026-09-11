#!/usr/bin/env bash
# Copy built Windows libs into PRODUCTS (optional zip).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_windows

OUT=""
PRODUCTS=""
SLICES=""
ZIP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --products) PRODUCTS="$2"; shift 2 ;;
    --slices) SLICES="$2"; shift 2 ;;
    --zip) ZIP=1; shift ;;
    *) die "package-windows.sh: unknown flag $1" ;;
  esac
done

[[ -n "$OUT" && -n "$PRODUCTS" && -n "$SLICES" ]] || \
  die "package-windows.sh requires --out --products --slices"

mkdir -p "$PRODUCTS/windows"
copied=0
# shellcheck disable=SC2086
for slice in $SLICES; do
  dir="$OUT/$slice"
  [[ -d "$dir" ]] || die "missing build output $dir (run: make build windows)"
  dest="$PRODUCTS/windows/$slice"
  mkdir -p "$dest"
  local_copied=0
  for name in webrtc.lib libwebrtc.a webrtc.dll webrtc.dll.lib; do
    if [[ -e "$dir/$name" ]]; then
      cp -R "$dir/$name" "$dest/"
      local_copied=1
    fi
  done
  if [[ "$local_copied" -eq 0 ]]; then
    die "no webrtc lib in $dir"
  fi
  copied=1
done

[[ "$copied" -eq 1 ]] || die "nothing to package"

if [[ "$ZIP" -eq 1 ]]; then
  (
    cd "$PRODUCTS"
    zip -r windows.zip windows
  )
fi

echo "wrote $PRODUCTS/windows"
