#!/usr/bin/env bash
# Copy WebRTC.xcframework → StreamWebRTC.xcframework (original untouched).
# Matches GetStream/webrtc fastlane rename_product and
# stream-video-swift-webrtc clone_and_modify_xcframework.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_darwin
require_cmd find
require_cmd file
require_cmd plutil
require_cmd install_name_tool

OLD="WebRTC"
NEW="StreamWebRTC"
SRC=""
DEST_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC="$2"; shift 2 ;;
    --dest) DEST_DIR="$2"; shift 2 ;;
    *) die "rename-apple.sh: unknown flag $1" ;;
  esac
done

[[ -n "$SRC" && -n "$DEST_DIR" ]] || die "rename-apple.sh requires --src --dest"
[[ -d "$SRC" ]] || die "no xcframework at $SRC"
base="$(basename "$SRC")"
[[ "$base" == "${OLD}.xcframework" ]] || die "expected ${OLD}.xcframework, got $base"

dest="${DEST_DIR}/${NEW}.xcframework"
src_abs="$(cd "$SRC" && pwd)"
mkdir -p "$DEST_DIR"
dest_parent="$(cd "$DEST_DIR" && pwd)"
dest_abs="${dest_parent}/${NEW}.xcframework"
[[ "$src_abs" != "$dest_abs" ]] || die "refusing to overwrite input $SRC"

rm -rf "$dest_abs"
cp -R "$src_abs" "$dest_abs"
echo "copied $src_abs -> $dest_abs"

while IFS= read -r -d '' path; do
  name="$(basename "$path")"
  case "$name" in
    "${OLD}.framework"|"${OLD}.dSYM"|"${OLD}.h"|"$OLD")
      dir="$(dirname "$path")"
      mv "$path" "${dir}/${name/${OLD}/${NEW}}"
      ;;
  esac
done < <(find "$dest_abs" -depth -print0)

while IFS= read -r -d '' file; do
  if [[ "$file" == *.plist ]]; then
    plutil -convert xml1 "$file"
  fi
  old_text="$(cat "$file")"
  new_text="${old_text//${OLD}/${NEW}}"
  if [[ "$old_text" != "$new_text" ]]; then
    printf '%s\n' "$new_text" > "$file"
  fi
done < <(find "$dest_abs" \( -name Info.plist -o -name module.modulemap \) -print0)

while IFS= read -r -d '' file; do
  old_text="$(cat "$file")"
  new_text="${old_text//import <${OLD}/import <${NEW}}"
  if [[ "$old_text" != "$new_text" ]]; then
    printf '%s\n' "$new_text" > "$file"
  fi
done < <(find "$dest_abs" -name '*.h' -print0)

while IFS= read -r -d '' fw; do
  (
    cd "$fw"
    if [[ -L "$NEW" ]]; then
      old_link="$(readlink "$NEW")"
      new_link="${old_link//${OLD}/${NEW}}"
      if [[ "$old_link" != "$new_link" ]]; then
        rm -f "$NEW"
        ln -s "$new_link" "$NEW"
      fi
    fi
    bin="$NEW"
    [[ -e "$bin" ]] || continue
    if file -b "$bin" | grep -q 'Mach-O'; then
      install_name_tool -id "@rpath/${NEW}.framework/${NEW}" "$bin"
    fi
  )
done < <(find "$dest_abs" -name "${NEW}.framework" -type d -print0)

echo "wrote $dest_abs"
echo "original preserved at $src_abs"
