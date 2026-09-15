#!/usr/bin/env bash
# Pack already-built Android ABI dirs into libwebrtc.aar.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_linux
require_cmd python3

SRC=""
OUT=""
PRODUCTS=""
SLICES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --products) PRODUCTS="$2"; shift 2 ;;
    --slices) SLICES="$2"; shift 2 ;;
    *) die "package-android.sh: unknown flag $1" ;;
  esac
done

[[ -n "$SRC" && -n "$OUT" && -n "$PRODUCTS" && -n "$SLICES" ]] || \
  die "package-android.sh requires --src --out --products --slices"

manifest="$SRC/sdk/android/AndroidManifest.xml"
[[ -f "$manifest" ]] || die "missing $manifest"

arch_from_slice() {
  printf '%s\n' "${1#android-}"
}

first=""
# shellcheck disable=SC2086
for slice in $SLICES; do
  dir="$OUT/$slice"
  [[ -d "$dir" ]] || die "missing build output $dir (run: make build android)"
  if [[ -z "$first" ]]; then
    first="$slice"
  fi
done

jar="$OUT/$first/lib.java/sdk/android/libwebrtc.jar"
[[ -f "$jar" ]] || die "missing classes jar at $jar"

mkdir -p "$PRODUCTS"
out_aar="$PRODUCTS/libwebrtc.aar"
rm -f "$out_aar"

python3 - "$out_aar" "$manifest" "$jar" "$OUT" $SLICES <<'PY'
import os
import sys
import zipfile

out_aar, manifest, jar, out_root, *slices = sys.argv[1:]
so_name = "libjingle_peerconnection_so.so"

with zipfile.ZipFile(out_aar, "w") as aar:
    aar.write(manifest, "AndroidManifest.xml")
    aar.write(jar, "classes.jar")
    for slice in slices:
        arch = slice[len("android-"):]
        so = os.path.join(out_root, slice, so_name)
        if not os.path.isfile(so):
            so = os.path.join(out_root, slice, "lib.unstripped", so_name)
        if not os.path.isfile(so):
            raise SystemExit(f"missing {so_name} in {out_root}/{slice}")
        aar.write(so, f"jni/{arch}/{so_name}")
print(f"wrote {out_aar}")
PY

if [[ "${SKIP_LICENSES:-0}" == 1 ]]; then
  echo "skipping license generation (SKIP_LICENSES=1)"
else
  require_cmd python3
  license_script="$SRC/tools_webrtc/libs/generate_licenses.py"
  [[ -f "$license_script" ]] || die "missing $license_script"
  build_dirs=()
  # shellcheck disable=SC2086
  for slice in $SLICES; do
    [[ -d "$OUT/$slice" ]] && build_dirs+=("$OUT/$slice")
  done
  [[ ${#build_dirs[@]} -gt 0 ]] || die "no slice out dirs for license generation"
  echo "python3 $license_script --target sdk/android:libwebrtc --target sdk/android:libjingle_peerconnection_so $PRODUCTS ${build_dirs[*]}"
  python3 "$license_script" \
    --target sdk/android:libwebrtc \
    --target sdk/android:libjingle_peerconnection_so \
    "$PRODUCTS" \
    "${build_dirs[@]}"
  echo "wrote ${PRODUCTS}/LICENSE.md"
fi
