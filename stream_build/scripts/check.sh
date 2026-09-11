#!/usr/bin/env bash
# Sanity check for the Makefile wrapper (no real gclient tree required).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# make check exports WEBRTC_SRC/DEPS_ROOT. Fixtures must not inherit them.
unset WEBRTC_SRC DEPS_ROOT WEBRTC_ROOT BOOTSTRAP_SRC

init_git_tree() {
  local dir="$1"
  mkdir -p "$dir"
  printf 'hooks = []\n' > "$dir/DEPS"
  git -C "$dir" init -q
  git -C "$dir" config user.email "check@example.com"
  git -C "$dir" config user.name "check"
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" add DEPS
  git -C "$dir" commit -q -m init
}

fake_layout() {
  local parent
  parent="$(mktemp -d)/webrtc"
  mkdir -p "$parent/src"
  printf 'hooks = []\n' > "$parent/src/DEPS"
  printf '%s\n' 'solutions = [{"name": "src", "managed": False}]' \
    > "$parent/.gclient"
  printf '%s\n' "$parent"
}

help_text="$(make -s help)"
[[ "$help_text" == *"make build|test|package"* ]]
printf '%s\n' "$help_text" | grep -q 'make bootstrap'
printf '%s\n' "$help_text" | grep -q 'CONFIG=release (default'
printf '%s\n' "$help_text" | grep -q 'make combine'
printf '%s\n' "$help_text" | grep -q 'make rename apple'
printf '%s\n' "$help_text" | grep -q 'SKIP_MACCATALYST=1'
printf '%s\n' "$help_text" | grep -q 'make package ios'
printf '%s\n' "$help_text" | grep -q 'make package macos'
! printf '%s\n' "$help_text" | grep -q 'package apple'

layout="$(fake_layout)"
layout_make=(make DEPS_ROOT="$layout" WEBRTC_SRC="$layout/src")

usage="$("${layout_make[@]}" build 2>&1 || true)"
printf '%s\n' "$usage" | grep -q 'usage: make build'
! printf '%s\n' "$usage" | grep -q '|apple'

text="$("${layout_make[@]}" -s print-gn-args TARGET=ios-arm64-device CONFIG=release)"
printf '%s\n' "$text" | grep -q 'stream_enable_rendering_backend = true'
printf '%s\n' "$text" | grep -q 'target_os = "ios"'
printf '%s\n' "$text" | grep -q 'is_debug = false'

debug="$("${layout_make[@]}" -s print-gn-args TARGET=macos-arm64 CONFIG=debug GN_ARGS='rtc_use_h264=false')"
printf '%s\n' "$debug" | grep -q 'is_debug = true'
printf '%s\n' "$debug" | grep -q 'target_os = "mac"'
printf '%s\n' "$debug" | grep -q 'rtc_use_h264 = false'

android="$("${layout_make[@]}" -s print-gn-args TARGET=android-arm64-v8a)"
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
combine_none="$(
  make combine PRODUCTS="$empty" SKIP_LICENSES=1 \
    DEPS_ROOT="$layout" WEBRTC_SRC="$layout/src" 2>&1 || true
)"
printf '%s\n' "$combine_none" | grep -q 'no WebRTC.xcframework'
rm -rf "$empty"

one="$(mktemp -d)"
mkdir -p "$one/ios/WebRTC.xcframework"
printf 'stub\n' > "$one/ios/WebRTC.xcframework/Info.plist"
make combine PRODUCTS="$one" SKIP_LICENSES=1 \
  DEPS_ROOT="$layout" WEBRTC_SRC="$layout/src"
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
make rename apple XCFRAMEWORK="$rename_src" RENAMED="$rename_out" \
  DEPS_ROOT="$layout" WEBRTC_SRC="$layout/src"
[[ -d "$rename_src/ios-arm64/WebRTC.framework" ]]
[[ -d "$rename_out/StreamWebRTC.xcframework/ios-arm64/StreamWebRTC.framework" ]]
grep -q 'StreamWebRTC' "$rename_out/StreamWebRTC.xcframework/ios-arm64/StreamWebRTC.framework/Modules/module.modulemap"
grep -q 'import <StreamWebRTC' "$rename_out/StreamWebRTC.xcframework/ios-arm64/StreamWebRTC.framework/Headers/StreamWebRTC.h"
! grep -q 'import <WebRTC' "$rename_out/StreamWebRTC.xcframework/ios-arm64/StreamWebRTC.framework/Headers/StreamWebRTC.h"
rm -rf "$rename_root" "$rename_out"

aar_dir="$(mktemp -d)"
printf 'aar-stub\n' > "$aar_dir/libwebrtc.aar"
make rename android AAR="$aar_dir/libwebrtc.aar" RENAMED="$aar_dir/renamed" \
  DEPS_ROOT="$layout" WEBRTC_SRC="$layout/src"
[[ -f "$aar_dir/libwebrtc.aar" ]]
[[ -f "$aar_dir/renamed/libwebrtc.aar" ]]
cmp -s "$aar_dir/libwebrtc.aar" "$aar_dir/renamed/libwebrtc.aar"
rm -rf "$aar_dir" "$(dirname "$layout")"

wrong="$(mktemp -d)/not-src"
init_git_tree "$wrong"
wrong_root="$(dirname "$wrong")"
if WEBRTC_SRC="$wrong" DEPS_ROOT="$wrong_root" \
  "$ROOT/scripts/bootstrap.sh" --check 2>"$wrong.err"; then
  echo "expected --check to fail on non-src checkout" >&2
  exit 1
fi
grep -q 'run: make bootstrap' "$wrong.err"
[[ "$(cat "$wrong.err")" == "run: make bootstrap" ]]

# help/check/bootstrap stay ungated; every other user verb hits the guard.
help_wrong="$(WEBRTC_SRC="$wrong" DEPS_ROOT="$wrong_root" make -s help)"
printf '%s\n' "$help_wrong" | grep -q 'make bootstrap'

expect_make_bootstrap() {
  local err="$wrong.err"
  if WEBRTC_SRC="$wrong" DEPS_ROOT="$wrong_root" \
    make --no-print-directory "$@" 2>"$err"; then
    echo "expected make $* to fail on non-src checkout" >&2
    exit 1
  fi
  grep -q 'run: make bootstrap' "$err"
}

expect_make_bootstrap build ios
expect_make_bootstrap test macos
expect_make_bootstrap package ios
expect_make_bootstrap deps
expect_make_bootstrap runhooks
expect_make_bootstrap combine
expect_make_bootstrap rename apple
expect_make_bootstrap clean
expect_make_bootstrap print-gn-args TARGET=ios-arm64-device
rm -rf "$wrong_root" "$wrong.err"

# 1-3 pass without .gclient; deps/build/test/package still need it.
bare="$(mktemp -d)/webrtc"
mkdir -p "$bare/src"
printf 'hooks = []\n' > "$bare/src/DEPS"
WEBRTC_SRC="$bare/src" DEPS_ROOT="$bare" \
  "$ROOT/scripts/bootstrap.sh" --check
if WEBRTC_SRC="$bare/src" DEPS_ROOT="$bare" \
  "$ROOT/scripts/bootstrap.sh" --check --gclient 2>"$bare.err"; then
  echo "expected --check --gclient to fail without .gclient" >&2
  exit 1
fi
grep -q 'run: make bootstrap' "$bare.err"
if WEBRTC_SRC="$bare/src" DEPS_ROOT="$bare" \
  make --no-print-directory build ios 2>"$bare.err"; then
  echo "expected make build to fail without .gclient" >&2
  exit 1
fi
grep -q 'run: make bootstrap' "$bare.err"
bare_rename="$(
  WEBRTC_SRC="$bare/src" DEPS_ROOT="$bare" \
    make --no-print-directory rename 2>&1 || true
)"
printf '%s\n' "$bare_rename" | grep -q 'usage: make rename'
! printf '%s\n' "$bare_rename" | grep -q 'run: make bootstrap'
rm -rf "$(dirname "$bare")" "$bare.err"

# Named webrtc (git) -> webrtc/src. Parent .gclient + wrapper Makefile.
parent="$(mktemp -d)"
repo="$parent/webrtc"
init_git_tree "$repo"
CONFIRM=1 BOOTSTRAP_SRC="$repo" "$ROOT/scripts/bootstrap.sh" >/dev/null
[[ -f "$parent/webrtc/src/DEPS" ]]
[[ -f "$parent/webrtc/.gclient" ]]
[[ -f "$parent/webrtc/Makefile" ]]
grep -q 'created by bootstrap if missing' "$parent/webrtc/Makefile"
grep -q 'src/stream_build' "$parent/webrtc/Makefile"

mkdir -p "$parent/webrtc/src/stream_build"
cat > "$parent/webrtc/src/stream_build/Makefile" <<'STUB'
.DEFAULT_GOAL := help
FIRST := $(firstword $(MAKECMDGOALS))
REST := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
.PHONY: help $(MAKECMDGOALS)
help:
	@echo "stub-help CONFIG=$(CONFIG) JOBS=$(JOBS)"
ifneq ($(FIRST),)
ifneq ($(FIRST),help)
$(FIRST):
	@echo "stub-goals $(MAKECMDGOALS) CONFIG=$(CONFIG) JOBS=$(JOBS)"
endif
endif
ifneq ($(REST),)
$(REST):
	@:
endif
STUB
fwd="$(make -C "$parent/webrtc" --no-print-directory build ios CONFIG=debug JOBS=8)"
printf '%s\n' "$fwd" | grep -q 'stub-goals build ios'
printf '%s\n' "$fwd" | grep -q 'CONFIG=debug'
printf '%s\n' "$fwd" | grep -q 'JOBS=8'
[[ "$(printf '%s\n' "$fwd" | grep -c 'stub-goals')" == 1 ]]
fwd_all="$(make -C "$parent/webrtc" --no-print-directory)"
printf '%s\n' "$fwd_all" | grep -q 'stub-help'

printf '%s\n' 'all:' $'\t@echo foreign' > "$parent/webrtc/Makefile"
grep -q '"managed": False' "$parent/webrtc/.gclient"
! grep -q '"revision"' "$parent/webrtc/.gclient"
[[ ! -L "$parent/webrtc/src" ]]
[[ -d "$parent/webrtc/src/.git" ]]
git -C "$parent/webrtc/src" rev-parse --is-inside-work-tree >/dev/null
CONFIRM=1 BOOTSTRAP_SRC="$parent/webrtc/src" "$ROOT/scripts/bootstrap.sh" >/dev/null
[[ -f "$parent/webrtc/.gclient" ]]
grep -q foreign "$parent/webrtc/Makefile"
rm -f "$parent/webrtc/Makefile"
CONFIRM=1 BOOTSTRAP_SRC="$parent/webrtc/src" "$ROOT/scripts/bootstrap.sh" >/dev/null
grep -q 'created by bootstrap if missing' "$parent/webrtc/Makefile"
WEBRTC_SRC="$parent/webrtc/src" DEPS_ROOT="$parent/webrtc" \
  "$ROOT/scripts/bootstrap.sh" --check
WEBRTC_SRC="$parent/webrtc/src" DEPS_ROOT="$parent/webrtc" \
  "$ROOT/scripts/bootstrap.sh" --check --gclient

symlink_parent="$(mktemp -d)/webrtc"
mkdir -p "$symlink_parent"
real_src="$(mktemp -d)/real"
init_git_tree "$real_src"
ln -sfn "$real_src" "$symlink_parent/src"
if WEBRTC_SRC="$symlink_parent/src" DEPS_ROOT="$symlink_parent" \
  "$ROOT/scripts/bootstrap.sh" --check 2>"$symlink_parent.err"; then
  echo "expected --check to fail on symlink src" >&2
  exit 1
fi
grep -q 'run: make bootstrap' "$symlink_parent.err"
if CONFIRM=1 BOOTSTRAP_SRC="$symlink_parent/src" \
  "$ROOT/scripts/bootstrap.sh" 2>"$symlink_parent.err"; then
  echo "expected bootstrap to refuse symlink src" >&2
  exit 1
fi
grep -q 'refuses symlink src' "$symlink_parent.err"
rm -rf "$parent" "$(dirname "$symlink_parent")" "$(dirname "$real_src")" \
  "$symlink_parent.err"

# Non-interactive without CONFIRM=1 prints the plan and exits.
ni_parent="$(mktemp -d)"
ni_repo="$ni_parent/webrtc"
init_git_tree "$ni_repo"
ni_out="$(BOOTSTRAP_SRC="$ni_repo" "$ROOT/scripts/bootstrap.sh" 2>&1 || true)"
printf '%s\n' "$ni_out" | grep -q 'CONFIRM=1'
printf '%s\n' "$ni_out" | grep -q "mv $ni_repo"
[[ -d "$ni_repo/.git" ]]
rm -rf "$ni_parent"

deps_tmp="$(mktemp -d)"
fake_bin="$deps_tmp/bin"
mkdir -p "$fake_bin" "$deps_tmp/webrtc/src" "$deps_tmp/webrtc/.gclient-git-cache"
init_git_tree "$deps_tmp/webrtc/src"
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
wt_before="$(git -C "$deps_tmp/webrtc/src" worktree list | wc -l | tr -d ' ')"
deps_out="$(
  PATH="$fake_bin:$PATH" \
    DEPS_ROOT="$deps_tmp/webrtc" \
    WEBRTC_SRC="$deps_tmp/webrtc/src" \
    GIT_CACHE_PATH="$deps_tmp/webrtc/.gclient-git-cache" \
    RUN_HOOKS=0 JOBS=2 \
    "$ROOT/scripts/deps.sh" sync
)"
printf '%s\n' "$deps_out" | grep -q 'will not reset it'
printf '%s\n' "$deps_out" | grep -q 'running: gclient sync -j2 --no-history --shallow --nohooks'
! printf '%s\n' "$deps_out" | grep -q -- '--revision'
grep -q '"managed": False' "$deps_tmp/webrtc/.gclient"
! grep -q '"revision"' "$deps_tmp/webrtc/.gclient"
grep -q 'sync -j2 --no-history --shallow --nohooks' "$deps_tmp/sync_args"
! grep -q -- '--revision' "$deps_tmp/sync_args"
grep -q "$deps_tmp/webrtc/.gclient-git-cache" "$deps_tmp/cache_env"
mkdir -p "$deps_tmp/webrtc/src/third_party/.git/objects/info"
printf '%s\n' \
  "$deps_tmp/webrtc/.gclient_deps/.gclient-git-cache/fake-repo/objects" \
  > "$deps_tmp/webrtc/src/third_party/.git/objects/info/alternates"
PATH="$fake_bin:$PATH" \
  DEPS_ROOT="$deps_tmp/webrtc" \
  WEBRTC_SRC="$deps_tmp/webrtc/src" \
  GIT_CACHE_PATH="$deps_tmp/webrtc/.gclient-git-cache" \
  RUN_HOOKS=0 JOBS=2 \
  "$ROOT/scripts/deps.sh" sync >/dev/null
grep -qx "$deps_tmp/webrtc/.gclient-git-cache/fake-repo/objects" \
  "$deps_tmp/webrtc/src/third_party/.git/objects/info/alternates"
! grep -q '.gclient_deps/.gclient-git-cache' \
  "$deps_tmp/webrtc/src/third_party/.git/objects/info/alternates"
PATH="$fake_bin:$PATH" \
  DEPS_ROOT="$deps_tmp/webrtc" \
  WEBRTC_SRC="$deps_tmp/webrtc/src" \
  GIT_CACHE_PATH="$deps_tmp/webrtc/.gclient-git-cache" \
  RUN_HOOKS=0 JOBS=2 SHALLOW=0 \
  "$ROOT/scripts/deps.sh" sync >/dev/null
grep -q 'sync -j2 --nohooks' "$deps_tmp/sync_args"
! grep -q -- '--no-history' "$deps_tmp/sync_args"
! grep -q -- '--shallow' "$deps_tmp/sync_args"
[[ ! -L "$deps_tmp/webrtc/src" ]]
[[ -f "$deps_tmp/webrtc/src/DEPS" ]]
wt_after="$(git -C "$deps_tmp/webrtc/src" worktree list | wc -l | tr -d ' ')"
[[ "$wt_before" == "$wt_after" ]]
python3 - "$deps_tmp/webrtc" <<'PY'
import os
import sys
prefix = os.path.realpath(sys.argv[1])
gn = os.path.abspath(os.path.join(prefix, "src/build/config/gclient_args.gni"))
real_gn = os.path.realpath(gn)
if os.path.commonpath([prefix, real_gn]) != prefix:
    raise SystemExit("gclient_gn_args_file would escape %r -> %r" % (prefix, real_gn))
PY
if PATH="$fake_bin:$PATH" \
  DEPS_ROOT="$deps_tmp/webrtc" \
  WEBRTC_SRC="$deps_tmp/webrtc/src" \
  WEBRTC_REVISION=eeff9252f32a40d1671974c31c096ce9fa776130 \
  "$ROOT/scripts/deps.sh" sync 2>"$deps_tmp/pin_err"; then
  echo "expected pin to fail on seeded src" >&2
  exit 1
fi
grep -q 'src is seeded from your git checkout; will not reset it' "$deps_tmp/pin_err"

missing="$(mktemp -d)/webrtc"
mkdir -p "$missing"
if PATH="$fake_bin:$PATH" DEPS_ROOT="$missing" \
  "$ROOT/scripts/deps.sh" sync 2>"$deps_tmp/missing_err"; then
  echo "expected deps.sh to fail without src" >&2
  exit 1
fi
grep -q 'run: make bootstrap' "$deps_tmp/missing_err"

rm -rf "$deps_tmp/linkroot"
mkdir -p "$deps_tmp/linkroot"
ln -sfn "$deps_tmp/webrtc/src" "$deps_tmp/linkroot/src"
if PATH="$fake_bin:$PATH" DEPS_ROOT="$deps_tmp/linkroot" \
  "$ROOT/scripts/deps.sh" sync 2>"$deps_tmp/link_err"; then
  echo "expected deps.sh to refuse symlink src" >&2
  exit 1
fi
grep -q 'src is a symlink' "$deps_tmp/link_err"
rm -rf "$deps_tmp" "$missing"

gha="$ROOT/../.github"
! grep -q 'github.run_id' "$gha/actions/artifact-upload/action.yml"
! grep -q 'github.run_id' "$gha/actions/artifact-download/action.yml"
! grep -q 'WEBRTC_REF' "$gha/actions/artifact-upload/action.yml"
! grep -q 'WEBRTC_REF' "$gha/actions/artifact-download/action.yml"
! grep -q 'webrtc_ref:' "$gha/actions/artifact-upload/action.yml"
! grep -q 'webrtc_ref:' "$gha/actions/artifact-download/action.yml"
grep -q 'object="artifacts/\${{ github.repository }}/\${OBJECT_STEM}.tar"' \
  "$gha/actions/artifact-upload/action.yml"
grep -q 'object="artifacts/\${{ github.repository }}/\${OBJECT_STEM}.tar"' \
  "$gha/actions/artifact-download/action.yml"
grep -q 'path: deps-key' "$gha/workflows/_make.yml"
grep -q "deps_artifact == 'deps-key'" "$gha/actions/restore-tree/action.yml"
grep -q 'if_missing: skip' "$gha/workflows/_make.yml"
grep -q 'SHALLOW: "1"' "$gha/workflows/_make.yml"
grep -q 'RUN_HOOKS: "0"' "$gha/workflows/_make.yml"
! grep -q 'RUN_HOOKS: "1"' "$gha/workflows/_make.yml"
grep -q 'chromium-webrtc-resources' "$gha/workflows/_make.yml"
grep -q 'src/resources' "$gha/actions/artifact-upload/action.yml"
grep -q 'src/resources' "$gha/actions/artifact-download/action.yml"

echo "ok"
