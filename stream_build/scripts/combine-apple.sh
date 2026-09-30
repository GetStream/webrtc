#!/usr/bin/env bash
# Discover platform xcframeworks under PRODUCTS/*/ and emit one WebRTC.xcframework.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_darwin
require_cmd xcodebuild

SRC="${WEBRTC_SRC:-}"
OUT=""
PRODUCTS=""
NAME="WebRTC"
ZIP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --products) PRODUCTS="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --zip) ZIP=1; shift ;;
    *) die "combine-apple.sh: unknown flag $1" ;;
  esac
done

[[ -n "$PRODUCTS" ]] || die "combine-apple.sh requires --products"

shopt -s nullglob
found=()
for xcf in "$PRODUCTS"/*/"${NAME}.xcframework"; do
  [[ -d "$xcf" ]] && found+=("$xcf")
done
shopt -u nullglob

if [[ ${#found[@]} -eq 0 ]]; then
  die "no ${NAME}.xcframework under ${PRODUCTS}/*/ — run make package ios and/or make package macos"
fi

echo "combine: found ${#found[@]} platform xcframework(s):"
for xcf in "${found[@]}"; do
  echo "  $xcf"
done

dest="${PRODUCTS}/${NAME}.xcframework"
rm -rf "$dest"

if [[ ${#found[@]} -eq 1 ]]; then
  echo "combine: one platform — copying ${found[0]} -> $dest"
  cp -R "${found[0]}" "$dest"
else
  require_cmd find
  xc_args=(-create-xcframework)
  added=0
  while IFS= read -r fw; do
    [[ -d "$fw" ]] || continue
    xc_args+=(-framework "$fw")
    dsym=""
    if [[ -d "${fw}.dSYM" ]]; then
      dsym="${fw}.dSYM"
    elif [[ -d "$(dirname "$fw")/dSYMs/$(basename "$fw").dSYM" ]]; then
      dsym="$(dirname "$fw")/dSYMs/$(basename "$fw").dSYM"
    fi
    if [[ -n "$dsym" ]]; then
      xc_args+=(-debug-symbols "$dsym")
    fi
    added=1
  done < <(find "${found[@]}" -name '*.framework' -type d | sort)
  [[ "$added" -eq 1 ]] || die "no .framework slices inside: ${found[*]}"
  xc_args+=(-output "$dest")
  echo "xcodebuild ${xc_args[*]}"
  xcodebuild "${xc_args[@]}"
fi

if [[ "${SKIP_LICENSES:-0}" == 1 ]]; then
  echo "skipping license generation (SKIP_LICENSES=1)"
else
  [[ -n "$SRC" ]] || die "combine-apple.sh requires --src (or WEBRTC_SRC) to generate licenses"
  [[ -n "$OUT" ]] || die "combine-apple.sh requires --out to generate licenses"
  require_cmd python3
  license_script="$SRC/tools_webrtc/libs/generate_licenses.py"
  [[ -f "$license_script" ]] || die "missing $license_script"

  gn_targets=()
  build_dirs=()
  seen_ios=0
  seen_macos=0
  for xcf in "${found[@]}"; do
    platform="$(basename "$(dirname "$xcf")")"
    case "$platform" in
      macos)
        if [[ "$seen_macos" -eq 0 ]]; then
          gn_targets+=(--target "//sdk:mac_framework_objc")
          seen_macos=1
        fi
        for dir in "$OUT"/macos-*; do
          [[ -d "$dir" ]] && build_dirs+=("$dir")
        done
        ;;
      *)
        if [[ "$seen_ios" -eq 0 ]]; then
          gn_targets+=(--target "//sdk:framework_objc")
          seen_ios=1
        fi
        if [[ "$platform" == ios ]]; then
          for dir in "$OUT"/ios-* "$OUT"/catalyst-*; do
            [[ -d "$dir" ]] && build_dirs+=("$dir")
          done
        else
          for dir in "$OUT/${platform}-"*; do
            [[ -d "$dir" ]] && build_dirs+=("$dir")
          done
        fi
        ;;
    esac
  done
  [[ ${#gn_targets[@]} -gt 0 ]] || die "no license GN targets for: ${found[*]}"
  [[ ${#build_dirs[@]} -gt 0 ]] || die "no slice out dirs under $OUT for license generation"
  echo "python3 $license_script ${gn_targets[*]} $dest ${build_dirs[*]}"
  python3 "$license_script" "${gn_targets[@]}" "$dest" "${build_dirs[@]}"
  echo "wrote ${dest}/LICENSE.md"
fi

if [[ "$ZIP" -eq 1 ]]; then
  if command -v ditto >/dev/null 2>&1; then
    ditto -c -k --sequesterRsrc --keepParent \
      "$dest" \
      "${PRODUCTS}/${NAME}.xcframework.zip"
  else
    (
      cd "$PRODUCTS"
      zip --symlinks -r "${NAME}.xcframework.zip" "${NAME}.xcframework"
    )
  fi
fi

echo "wrote $dest"
