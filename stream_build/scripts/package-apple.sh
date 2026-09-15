#!/usr/bin/env bash
# lipo Apple framework slices and emit WebRTC.xcframework.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_darwin
require_cmd lipo
require_cmd xcodebuild

SRC="${WEBRTC_SRC:-}"
OUT=""
PRODUCTS=""
SLICES=""
NAME="WebRTC"
ZIP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --products) PRODUCTS="$2"; shift 2 ;;
    --slices) SLICES="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --zip) ZIP=1; shift ;;
    *) die "package-apple.sh: unknown flag $1" ;;
  esac
done

[[ -n "$OUT" && -n "$PRODUCTS" && -n "$SLICES" ]] || die "package-apple.sh requires --out --products --slices"

framework_in_slice() {
  printf '%s/%s/%s.framework\n' "$OUT" "$1" "$NAME"
}

framework_binary() {
  local fw="$1"
  local bin="$fw/$NAME"
  if [[ -e "$fw/Versions/A/$NAME" ]]; then
    printf '%s\n' "$fw/Versions/A/$NAME"
    return
  fi
  if [[ -L "$bin" ]]; then
    printf '%s/%s\n' "$fw" "$(readlink "$bin")"
    return
  fi
  printf '%s\n' "$bin"
}

dsym_binary() {
  printf '%s.dSYM/Contents/Resources/DWARF/%s\n' "$1" "$NAME"
}

lipo_group() {
  local dest="$1"
  shift
  local slices=("$@")
  local present=()
  local slice fw
  for slice in "${slices[@]}"; do
    fw="$(framework_in_slice "$slice")"
    if [[ -d "$fw" ]]; then
      present+=("$slice")
    fi
  done
  if [[ ${#present[@]} -eq 0 ]]; then
    return 1
  fi

  mkdir -p "$(dirname "$dest")"
  rm -rf "$dest"
  cp -R "$(framework_in_slice "${present[0]}")" "$dest"

  local binaries=()
  for slice in "${present[@]}"; do
    binaries+=("$(framework_binary "$(framework_in_slice "$slice")")")
  done
  local out_bin
  out_bin="$(framework_binary "$dest")"
  rm -f "$out_bin"
  lipo -create "${binaries[@]}" -output "$out_bin"

  local first_dsym="${OUT}/${present[0]}/${NAME}.dSYM"
  if [[ -d "$first_dsym" ]]; then
    rm -rf "${dest}.dSYM"
    cp -R "$first_dsym" "${dest}.dSYM"
    local dsym_bins=()
    for slice in "${present[@]}"; do
      local dsym="${OUT}/${slice}/${NAME}.dSYM"
      [[ -d "$dsym" ]] || continue
      dsym_bins+=("$(dsym_binary "$dsym")")
    done
    if [[ ${#dsym_bins[@]} -gt 0 ]]; then
      local out_dsym
      out_dsym="$(dsym_binary "${dest}.dSYM")"
      rm -f "$out_dsym"
      mkdir -p "$(dirname "$out_dsym")"
      lipo -create "${dsym_bins[@]}" -output "$out_dsym"
    fi
  fi
  return 0
}

contains_slice() {
  local needle="$1"
  local s
  # shellcheck disable=SC2086
  for s in $SLICES; do
    [[ "$s" == "$needle" ]] && return 0
  done
  return 1
}

work="${OUT}/_apple_universal"
rm -rf "$work"
mkdir -p "$work"

xc_args=(-create-xcframework)
added=0

add_framework() {
  local fw="$1"
  [[ -d "$fw" ]] || return 0
  xc_args+=(-framework "$fw")
  if [[ -d "${fw}.dSYM" ]]; then
    xc_args+=(-debug-symbols "${fw}.dSYM")
  fi
  added=1
}

if contains_slice ios-arm64-device && lipo_group "${work}/ios-device/${NAME}.framework" ios-arm64-device; then
  add_framework "${work}/ios-device/${NAME}.framework"
fi
if { contains_slice ios-arm64-simulator || contains_slice ios-x64-simulator; } && \
   lipo_group "${work}/ios-simulator/${NAME}.framework" ios-arm64-simulator ios-x64-simulator; then
  add_framework "${work}/ios-simulator/${NAME}.framework"
fi
if { contains_slice catalyst-arm64 || contains_slice catalyst-x64; } && \
   lipo_group "${work}/catalyst/${NAME}.framework" catalyst-arm64 catalyst-x64; then
  add_framework "${work}/catalyst/${NAME}.framework"
fi
if { contains_slice macos-arm64 || contains_slice macos-x64; } && \
   lipo_group "${work}/macos/${NAME}.framework" macos-arm64 macos-x64; then
  add_framework "${work}/macos/${NAME}.framework"
fi

[[ "$added" -eq 1 ]] || die "no Apple frameworks found under $OUT for slices: $SLICES"

mkdir -p "$PRODUCTS"
rm -rf "${PRODUCTS}/${NAME}.xcframework"
xc_args+=(-output "${PRODUCTS}/${NAME}.xcframework")
echo "xcodebuild ${xc_args[*]}"
xcodebuild "${xc_args[@]}"

xcframework="${PRODUCTS}/${NAME}.xcframework"
if [[ "${SKIP_LICENSES:-0}" == 1 ]]; then
  echo "skipping license generation (SKIP_LICENSES=1)"
else
  [[ -n "$SRC" ]] || die "package-apple.sh requires --src (or WEBRTC_SRC) to generate licenses"
  require_cmd python3
  license_script="$SRC/tools_webrtc/libs/generate_licenses.py"
  [[ -f "$license_script" ]] || die "missing $license_script"
  build_dirs=()
  # shellcheck disable=SC2086
  for slice in $SLICES; do
    [[ -d "$OUT/$slice" ]] && build_dirs+=("$OUT/$slice")
  done
  [[ ${#build_dirs[@]} -gt 0 ]] || die "no slice out dirs for license generation"
  gn_targets=()
  has_ios=0
  has_macos=0
  # shellcheck disable=SC2086
  for slice in $SLICES; do
    if [[ "$slice" == macos-* ]]; then
      has_macos=1
    else
      has_ios=1
    fi
  done
  [[ "$has_ios" -eq 1 ]] && gn_targets+=(--target "//sdk:framework_objc")
  [[ "$has_macos" -eq 1 ]] && gn_targets+=(--target "//sdk:mac_framework_objc")
  [[ ${#gn_targets[@]} -gt 0 ]] || die "no license GN targets for slices: $SLICES"
  echo "python3 $license_script ${gn_targets[*]} $xcframework ${build_dirs[*]}"
  python3 "$license_script" "${gn_targets[@]}" "$xcframework" "${build_dirs[@]}"
  echo "wrote ${xcframework}/LICENSE.md"
fi

if [[ "$ZIP" -eq 1 ]]; then
  if command -v ditto >/dev/null 2>&1; then
    ditto -c -k --sequesterRsrc --keepParent \
      "${PRODUCTS}/${NAME}.xcframework" \
      "${PRODUCTS}/${NAME}.xcframework.zip"
  else
    (
      cd "$PRODUCTS"
      zip --symlinks -r "${NAME}.xcframework.zip" "${NAME}.xcframework"
    )
  fi
fi

echo "wrote ${PRODUCTS}/${NAME}.xcframework"
