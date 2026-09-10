#!/usr/bin/env bash
# Sanity check for the Makefile wrapper (no WebRTC tree required).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

help_text="$(make -s help)"
[[ "$help_text" == *"make build|test|package"* ]]
printf '%s\n' "$help_text" | grep -q 'CONFIG=release (default'
printf '%s\n' "$help_text" | grep -q 'make combine'
printf '%s\n' "$help_text" | grep -q 'make rename apple'
printf '%s\n' "$help_text" | grep -q 'SKIP_MACCATALYST=1'
printf '%s\n' "$help_text" | grep -q 'make package ios'
printf '%s\n' "$help_text" | grep -q 'make package macos'
! printf '%s\n' "$help_text" | grep -q 'package apple'

usage="$(make build 2>&1 || true)"
printf '%s\n' "$usage" | grep -q 'usage: make build'
! printf '%s\n' "$usage" | grep -q '|apple'

text="$(make -s print-gn-args TARGET=ios-arm64-device CONFIG=release)"
printf '%s\n' "$text" | grep -q 'stream_enable_rendering_backend = true'
printf '%s\n' "$text" | grep -q 'target_os = "ios"'
printf '%s\n' "$text" | grep -q 'is_debug = false'

debug="$(make -s print-gn-args TARGET=macos-arm64 CONFIG=debug GN_ARGS='rtc_use_h264=false')"
printf '%s\n' "$debug" | grep -q 'is_debug = true'
printf '%s\n' "$debug" | grep -q 'target_os = "mac"'
printf '%s\n' "$debug" | grep -q 'rtc_use_h264 = false'

android="$(make -s print-gn-args TARGET=android-arm64-v8a)"
printf '%s\n' "$android" | grep -q 'target_os = "android"'
printf '%s\n' "$android" | grep -q 'target_cpu = "arm64"'

ninja_target="$("$ROOT/scripts/gn-gen.sh" --ninja-target ios-arm64-device)"
[[ "$ninja_target" == framework_objc ]]

banner="$(make --no-print-directory announce VERB=build PLATFORM=ios CONFIG=release)"
printf '%s\n' "$banner" | grep -q '==> build ios'
printf '%s\n' "$banner" | grep -q 'config:     release'
printf '%s\n' "$banner" | grep -q 'deps_root:'
printf '%s\n' "$banner" | grep -q '/ios$'
printf '%s\n' "$banner" | grep 'slices:' | grep -q 'catalyst-arm64'
printf '%s\n' "$banner" | grep 'slices:' | grep -q 'catalyst-x64'

ios_skip="$(make --no-print-directory announce VERB=package PLATFORM=ios SKIP_MACCATALYST=1)"
printf '%s\n' "$ios_skip" | grep -q 'skip_maccatalyst: 1'
printf '%s\n' "$ios_skip" | grep 'slices:' | grep -q 'ios-arm64-device'
! printf '%s\n' "$ios_skip" | grep 'slices:' | grep -q 'catalyst'

macos_banner="$(make --no-print-directory announce VERB=package PLATFORM=macos SKIP_MACCATALYST=1)"
printf '%s\n' "$macos_banner" | grep -q '/macos$'
printf '%s\n' "$macos_banner" | grep 'slices:' | grep -q 'macos-arm64'
printf '%s\n' "$macos_banner" | grep 'slices:' | grep -q 'macos-x64'

test_banner="$(make --no-print-directory announce VERB=test PLATFORM=macos CONFIG=release)"
printf '%s\n' "$test_banner" | grep -q '==> test macos'
printf '%s\n' "$test_banner" | grep -q 'config:     debug (tests always debug)'

empty="$(mktemp -d)"
combine_none="$(make combine PRODUCTS="$empty" SKIP_LICENSES=1 2>&1 || true)"
printf '%s\n' "$combine_none" | grep -q 'no WebRTC.xcframework'
rm -rf "$empty"

one="$(mktemp -d)"
mkdir -p "$one/ios/WebRTC.xcframework"
printf 'stub\n' > "$one/ios/WebRTC.xcframework/Info.plist"
make combine PRODUCTS="$one" SKIP_LICENSES=1
[[ -f "$one/WebRTC.xcframework/Info.plist" ]]
rm -rf "$one"

rename_root="$(mktemp -d)"
rename_src="$rename_root/WebRTC.xcframework"
mkdir -p "$rename_src/ios-arm64/WebRTC.framework/Headers"
mkdir -p "$rename_src/ios-arm64/WebRTC.framework/Modules"
printf '%s\n' '<?xml version="1.0"?><plist><dict><key>CFBundleName</key><string>WebRTC</string></dict></plist>' \
  > "$rename_src/Info.plist"
printf '%s\n' 'framework module WebRTC { umbrella header "WebRTC.h" }' \
  > "$rename_src/ios-arm64/WebRTC.framework/Modules/module.modulemap"
printf '%s\n' '#import <WebRTC/WebRTC.h>' \
  > "$rename_src/ios-arm64/WebRTC.framework/Headers/WebRTC.h"
printf 'stub\n' > "$rename_src/ios-arm64/WebRTC.framework/WebRTC"
printf '%s\n' '<?xml version="1.0"?><plist><dict></dict></plist>' \
  > "$rename_src/ios-arm64/WebRTC.framework/Info.plist"
rename_out="$(mktemp -d)"
make rename apple XCFRAMEWORK="$rename_src" RENAMED="$rename_out"
[[ -d "$rename_src/ios-arm64/WebRTC.framework" ]]
[[ -d "$rename_out/StreamWebRTC.xcframework/ios-arm64/StreamWebRTC.framework" ]]
grep -q 'StreamWebRTC' "$rename_out/StreamWebRTC.xcframework/ios-arm64/StreamWebRTC.framework/Modules/module.modulemap"
grep -q 'import <StreamWebRTC' "$rename_out/StreamWebRTC.xcframework/ios-arm64/StreamWebRTC.framework/Headers/StreamWebRTC.h"
! grep -q 'import <WebRTC' "$rename_out/StreamWebRTC.xcframework/ios-arm64/StreamWebRTC.framework/Headers/StreamWebRTC.h"
rm -rf "$rename_root" "$rename_out"

aar_dir="$(mktemp -d)"
printf 'aar-stub\n' > "$aar_dir/libwebrtc.aar"
make rename android AAR="$aar_dir/libwebrtc.aar" RENAMED="$aar_dir/renamed"
[[ -f "$aar_dir/libwebrtc.aar" ]]
[[ -f "$aar_dir/renamed/libwebrtc.aar" ]]
cmp -s "$aar_dir/libwebrtc.aar" "$aar_dir/renamed/libwebrtc.aar"
rm -rf "$aar_dir"

deps_tmp="$(mktemp -d)"
fake_bin="$deps_tmp/bin"
mkdir -p "$fake_bin" "$deps_tmp/src_repo" "$deps_tmp/deps/.gclient-git-cache"
printf 'hooks = []\n' > "$deps_tmp/src_repo/DEPS"
cat > "$fake_bin/gclient" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_GCLIENT_LOG}"
if [[ "${1:-}" == sync ]]; then
  printf '%s\n' "$*" > "${FAKE_GCLIENT_SYNC_ARGS}"
  printf '%s\n' "${GIT_CACHE_PATH-<unset>}" > "${FAKE_GCLIENT_CACHE}"
fi
exit 0
FAKE
chmod +x "$fake_bin/gclient"
export FAKE_GCLIENT_LOG="$deps_tmp/log"
export FAKE_GCLIENT_SYNC_ARGS="$deps_tmp/sync_args"
export FAKE_GCLIENT_CACHE="$deps_tmp/cache_env"
deps_out="$(
  PATH="$fake_bin:$PATH" \
    DEPS_ROOT="$deps_tmp/deps" \
    WEBRTC_SRC="$deps_tmp/src_repo" \
    GIT_CACHE_PATH="$deps_tmp/deps/.gclient-git-cache" \
    RUN_HOOKS=0 JOBS=2 \
    "$ROOT/scripts/deps.sh" sync
)"
printf '%s\n' "$deps_out" | grep -q 'will not reset it'
printf '%s\n' "$deps_out" | grep -q 'running: gclient sync -j2 --nohooks'
! printf '%s\n' "$deps_out" | grep -q -- '--revision'
grep -q '"managed": False' "$deps_tmp/deps/.gclient"
! grep -q '"revision"' "$deps_tmp/deps/.gclient"
grep -q 'sync -j2 --nohooks' "$deps_tmp/sync_args"
! grep -q -- '--revision' "$deps_tmp/sync_args"
grep -q "$deps_tmp/deps/.gclient-git-cache" "$deps_tmp/cache_env"
[[ -L "$deps_tmp/deps/src" ]]
if PATH="$fake_bin:$PATH" \
  DEPS_ROOT="$deps_tmp/deps" \
  WEBRTC_SRC="$deps_tmp/src_repo" \
  WEBRTC_REVISION=eeff9252f32a40d1671974c31c096ce9fa776130 \
  "$ROOT/scripts/deps.sh" sync 2>"$deps_tmp/pin_err"; then
  echo "expected pin to fail on symlink src" >&2
  exit 1
fi
grep -q 'src is your git checkout; will not reset it' "$deps_tmp/pin_err"
rm -rf "$deps_tmp"

echo "ok"
