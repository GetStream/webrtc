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
printf '%s\n' "$help_text" | grep -q 'make migrate plan'
! printf '%s\n' "$help_text" | grep -q 'package apple'
python3 "$ROOT/scripts/migration_gate.py" --selftest
"$ROOT/scripts/migrate.sh" selftest

layout="$(fake_layout)"
layout_make=(make DEPS_ROOT="$layout" WEBRTC_SRC="$layout/src")

for platform in ios macos; do
  package_plan="$("${layout_make[@]}" -n "package-$platform")"
  [[ "$package_plan" == *--zip* ]]
  package_plan="$("${layout_make[@]}" -n "package-$platform" ZIP=0)"
  [[ "$package_plan" != *--zip* ]]
done

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
"$ROOT/scripts/tests/rewrite-android-namespace-test.sh"
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
mkdir -p "$fake_bin" "$deps_tmp/webrtc/src" "$deps_tmp/.gclient-git-cache"
init_git_tree "$deps_tmp/webrtc/src"
cat > "$fake_bin/gclient" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_GCLIENT_LOG}"
if [[ "${1:-}" == sync ]]; then
  # depot_tools 9be95df5: the git cache must not overlap the gclient root.
  root="$(pwd -P)"
  cache="$(cd "${GIT_CACHE_PATH:?}" && pwd -P)"
  case "$cache/" in "$root"/*) echo "git cache inside gclient root" >&2; exit 1 ;; esac
  case "$root/" in "$cache"/*) echo "git cache contains gclient root" >&2; exit 1 ;; esac
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
    GIT_CACHE_PATH="$deps_tmp/.gclient-git-cache" \
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
grep -q "$deps_tmp/.gclient-git-cache" "$deps_tmp/cache_env"
mkdir -p "$deps_tmp/webrtc/src/third_party/.git/objects/info"
printf '%s\n' \
  "$deps_tmp/webrtc/.gclient_deps/.gclient-git-cache/fake-repo/objects" \
  > "$deps_tmp/webrtc/src/third_party/.git/objects/info/alternates"
PATH="$fake_bin:$PATH" \
  DEPS_ROOT="$deps_tmp/webrtc" \
  WEBRTC_SRC="$deps_tmp/webrtc/src" \
  GIT_CACHE_PATH="$deps_tmp/.gclient-git-cache" \
  RUN_HOOKS=0 JOBS=2 \
  "$ROOT/scripts/deps.sh" sync >/dev/null
grep -qx "$deps_tmp/.gclient-git-cache/fake-repo/objects" \
  "$deps_tmp/webrtc/src/third_party/.git/objects/info/alternates"
! grep -q '.gclient_deps/.gclient-git-cache' \
  "$deps_tmp/webrtc/src/third_party/.git/objects/info/alternates"
printf '%s\n' \
  "/home/runner/work/webrtc/webrtc/.gclient-git-cache/fake-repo/objects" \
  > "$deps_tmp/webrtc/src/third_party/.git/objects/info/alternates"
PATH="$fake_bin:$PATH" \
  DEPS_ROOT="$deps_tmp/webrtc" \
  WEBRTC_SRC="$deps_tmp/webrtc/src" \
  GIT_CACHE_PATH="$deps_tmp/.gclient-git-cache" \
  RUN_HOOKS=0 JOBS=2 \
  "$ROOT/scripts/deps.sh" sync >/dev/null
grep -qx "$deps_tmp/.gclient-git-cache/fake-repo/objects" \
  "$deps_tmp/webrtc/src/third_party/.git/objects/info/alternates"
! grep -q '/home/runner/work' \
  "$deps_tmp/webrtc/src/third_party/.git/objects/info/alternates"
PATH="$fake_bin:$PATH" \
  DEPS_ROOT="$deps_tmp/webrtc" \
  WEBRTC_SRC="$deps_tmp/webrtc/src" \
  GIT_CACHE_PATH="$deps_tmp/.gclient-git-cache" \
  RUN_HOOKS=0 JOBS=2 SHALLOW=0 \
  "$ROOT/scripts/deps.sh" sync >/dev/null
grep -q 'sync -j2 --nohooks' "$deps_tmp/sync_args"
! grep -q -- '--no-history' "$deps_tmp/sync_args"
! grep -q -- '--shallow' "$deps_tmp/sync_args"
if PATH="$fake_bin:$PATH" \
  DEPS_ROOT="$deps_tmp/webrtc" \
  WEBRTC_SRC="$deps_tmp/webrtc/src" \
  GIT_CACHE_PATH="$deps_tmp/webrtc/.gclient-git-cache" \
  RUN_HOOKS=0 JOBS=2 \
  "$ROOT/scripts/deps.sh" sync >/dev/null 2>"$deps_tmp/overlap_err"; then
  echo "expected the fake gclient to reject a git cache inside the root" >&2
  exit 1
fi
grep -q 'git cache inside gclient root' "$deps_tmp/overlap_err"
rm -rf "$deps_tmp/webrtc/.gclient-git-cache" "$deps_tmp/.gclient-git-cache"
mkdir -p "$deps_tmp/webrtc/.gclient-git-cache/fake-repo/objects"
printf '%s\n' \
  "$deps_tmp/webrtc/.gclient-git-cache/fake-repo/objects" \
  > "$deps_tmp/webrtc/src/third_party/.git/objects/info/alternates"
legacy_out="$(
  env -u GIT_CACHE_PATH PATH="$fake_bin:$PATH" \
    DEPS_ROOT="$deps_tmp/webrtc" \
    WEBRTC_SRC="$deps_tmp/webrtc/src" \
    RUN_HOOKS=0 JOBS=2 \
    "$ROOT/scripts/deps.sh" sync
)"
printf '%s\n' "$legacy_out" | grep -q "mv $deps_tmp/webrtc/.gclient-git-cache"
[[ ! -e "$deps_tmp/webrtc/.gclient-git-cache" ]]
[[ -d "$deps_tmp/.gclient-git-cache/fake-repo/objects" ]]
grep -qx "$deps_tmp/.gclient-git-cache" "$deps_tmp/cache_env"
grep -qx "$deps_tmp/.gclient-git-cache/fake-repo/objects" \
  "$deps_tmp/webrtc/src/third_party/.git/objects/info/alternates"
mkdir -p "$deps_tmp/webrtc/.gclient-git-cache"
touch "$deps_tmp/webrtc/.gclient-git-cache/stale"
legacy_out="$(
  env -u GIT_CACHE_PATH PATH="$fake_bin:$PATH" \
    DEPS_ROOT="$deps_tmp/webrtc" \
    WEBRTC_SRC="$deps_tmp/webrtc/src" \
    RUN_HOOKS=0 JOBS=2 \
    "$ROOT/scripts/deps.sh" sync
)"
printf '%s\n' "$legacy_out" | grep -q "note: $deps_tmp/webrtc/.gclient-git-cache is unused"
[[ -f "$deps_tmp/webrtc/.gclient-git-cache/stale" ]]
[[ -d "$deps_tmp/.gclient-git-cache/fake-repo/objects" ]]
rm -rf "$deps_tmp/webrtc/.gclient-git-cache"
(
  # shellcheck source=common.sh
  source "$ROOT/scripts/common.sh"
  [[ "$(default_git_cache_path /a/webrtc)" == /a/.gclient-git-cache ]]
  [[ "$(default_git_cache_path /a/webrtc/)" == /a/.gclient-git-cache ]]
  [[ "$(default_git_cache_path 'D:\a\webrtc\webrtc')" == 'D:\a\webrtc/.gclient-git-cache' ]]
)
printf 'print-git-cache:\n\t@echo $(GIT_CACHE_PATH)\n' > "$deps_tmp/print.mk"
[[ "$(env -u GIT_CACHE_PATH make -s -C "$ROOT" -f Makefile -f "$deps_tmp/print.mk" \
  print-git-cache DEPS_ROOT=/a/webrtc)" == /a/.gclient-git-cache ]]
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
[[ ! -e "$gha/actions/artifact-upload/action.yml" ]]
! grep -q 'github.run_id' "$gha/actions/artifact-download/action.yml"
! grep -q 'github.run_id' "$gha/actions/artifact-put/action.yml"
! grep -q 'WEBRTC_REF' "$gha/actions/artifact-download/action.yml"
! grep -q 'WEBRTC_REF' "$gha/actions/artifact-put/action.yml"
! grep -q 'webrtc_ref:' "$gha/actions/artifact-download/action.yml"
! grep -q 'webrtc_ref:' "$gha/actions/artifact-put/action.yml"
! grep -q 'secrets\.' "$gha/actions/artifact-download/action.yml"
! grep -q 'secrets\.' "$gha/actions/artifact-put/action.yml"
! grep -q 'secrets\.' "$gha/actions/restore-tree/action.yml"
grep -q 'tar cf "${tar_file}"' "$gha/actions/artifact-put/action.yml"
! grep -q 'tar cf -' "$gha/actions/artifact-put/action.yml"
! grep -q 's3 cp -' "$gha/actions/artifact-put/action.yml"
! grep -q 's3 cp "s3://${BUCKET}/${object}" -' \
  "$gha/actions/artifact-download/action.yml"
! grep -q 's3 cp "s3://${BUCKET}/${object}" "${tar_file}"' \
  "$gha/actions/artifact-download/action.yml"
grep -q 's3api get-object' "$gha/actions/artifact-download/action.yml"
grep -q 'bytes=${have}-' "$gha/actions/artifact-download/action.yml"
grep -q 'resume_from=' "$gha/actions/artifact-download/action.yml"
grep -q 's3 cp "${tar_file}" "s3://${BUCKET}/${object}"' \
  "$gha/actions/artifact-put/action.yml"
grep -q 'AWS_MAX_ATTEMPTS' "$gha/actions/artifact-download/action.yml"
grep -q 'AWS_RETRY_MODE' "$gha/actions/artifact-download/action.yml"
grep -q 'cli-read-timeout' "$gha/actions/artifact-download/action.yml"
grep -q 'size mismatch' "$gha/actions/artifact-download/action.yml"
grep -q 'tar xf "${tar_file}"' "$gha/actions/artifact-download/action.yml"
grep -q 'git -C src checkout -- resources' "$gha/actions/artifact-download/action.yml"
grep -q 'git -C src checkout -- resources' "$gha/actions/restore-tools/action.yml"
grep -q '.hetzner-hit-bytes' "$gha/actions/artifact-download/action.yml"
grep -q '.hetzner-hit-bytes' "$gha/actions/artifact-put/action.yml"
grep -q '1073741824' "$gha/actions/artifact-put/action.yml"
grep -q 'skip upload:' "$gha/actions/artifact-put/action.yml"
grep -q 'object="artifacts/\${{ github.repository }}/\${OBJECT_STEM}.tar"' \
  "$gha/actions/artifact-put/action.yml"
grep -q 'object="artifacts/\${{ github.repository }}/\${OBJECT_STEM}.tar"' \
  "$gha/actions/artifact-download/action.yml"
! grep -qE 'name: Deps$' "$gha/workflows/_make.yml"
! grep -q 'name: Hetzner backfill' "$gha/workflows/_make.yml"
! grep -q 'path: deps-key' "$gha/workflows/_make.yml"
! grep -q 'name: deps-key' "$gha/workflows/_make.yml"
grep -q 'cache_key: build-ios' "$gha/workflows/_make.yml"
grep -q 'cache_key: build-macos' "$gha/workflows/_make.yml"
grep -q 'cache_key: build-android' "$gha/workflows/_make.yml"
! grep -q 'name: deps-windows' "$gha/workflows/_make.yml"
! grep -q 'uses: ./src/.github/actions/artifact-put' "$gha/workflows/_make.yml"
grep -A5 'name: Build iOS' "$gha/workflows/_make.yml" | grep -q 'needs: \[plan\]'
! grep -A8 'name: Build iOS' "$gha/workflows/_make.yml" | grep -q deps
grep -A5 'name: Test iOS' "$gha/workflows/_make.yml" | grep -q 'needs: \[plan\]'
! grep -A8 'name: Test iOS' "$gha/workflows/_make.yml" | grep -q deps
grep -q 'restore-git-cache' "$gha/actions/restore-tree/action.yml"
grep -q 'hetzner_access_key' "$gha/actions/restore-tree/action.yml"
! grep -q 'actions/download-artifact' "$gha/actions/restore-tree/action.yml"
! grep -q 'tar xf' "$gha/actions/restore-tree/action.yml"
! grep -q 'artifact-download' "$gha/actions/restore-tree/action.yml"
grep -q 'SHALLOW: "1"' "$gha/actions/restore-tree/action.yml"
grep -q 'RUN_HOOKS: "1"' "$gha/actions/restore-tree/action.yml"
! grep -q 'RUN_HOOKS: "0"' "$gha/workflows/_make.yml"
! grep -q 'Drop git-cache alternates' "$gha/actions/restore-tree/action.yml"
for f in workflows/_make.yml actions/restore-tree/action.yml \
  actions/setup-webrtc/action.yml actions/artifact-put/action.yml; do
  if grep -nE '(workspace }}|GITHUB_WORKSPACE})/\.gclient-git-cache|^[[:space:]]*GIT_CACHE_PATH:' \
    "$gha/$f"; then
    echo "$f: git cache inside the gclient root, or GIT_CACHE_PATH overridden" >&2
    exit 1
  fi
done
grep -q 'default_git_cache_path "${GITHUB_WORKSPACE}"' "$gha/actions/setup-webrtc/action.yml"
grep -q 'GIT_CACHE_PATH=${git_cache}' "$gha/actions/setup-webrtc/action.yml"
grep -q 'mv .gclient-git-cache "${git_cache}"' "$gha/actions/artifact-download/action.yml"
grep -q 'cache="${GIT_CACHE_PATH:?}"' "$gha/actions/artifact-put/action.yml"
! grep -q 'GIT_CACHE_PATH: ${{ github.workspace }}/.gclient-git-cache' \
  "$gha/actions/restore-tree/action.yml"
! grep -q 'GIT_CACHE_PATH: ${{ github.workspace }}/.gclient-git-cache' \
  "$gha/workflows/_make.yml"
grep -q 'rewrite_git_cache_alternates' "$ROOT/scripts/deps.sh"
grep -q -- '-C "${cache_parent}" .gclient-git-cache' "$gha/actions/artifact-put/action.yml"
# GNU tar rejects a trailing -C with no member after it.
grep -q 'if ((${#members\[@\]})); then' "$gha/actions/artifact-put/action.yml"
grep -qx '          tar cf "${tar_file}" -C "${cache_parent}" .gclient-git-cache' \
  "$gha/actions/artifact-put/action.yml"
grep -q 'src/resources' "$gha/actions/artifact-put/action.yml"
grep -q '.cipd' "$gha/actions/artifact-put/action.yml"
! grep -q 'src/third_party' "$gha/actions/artifact-put/action.yml"
! grep -q 'src/third_party' "$gha/actions/artifact-download/action.yml"
! grep -q 'src/third_party' "$gha/actions/restore-tree/action.yml"
grep -A12 'members=()' "$gha/actions/artifact-put/action.yml" | \
  grep -q 'src/resources'
grep -A12 'members=()' "$gha/actions/artifact-put/action.yml" | \
  grep -q '.cipd'
! grep -A12 'members=()' "$gha/actions/artifact-put/action.yml" | \
  grep -q 'third_party'
grep -q 'pack members:' "$gha/actions/artifact-put/action.yml"
grep -q 'cache_key: webrtc-cache' "$gha/workflows/_make.yml"
grep -q 'products/ios/WebRTC.xcframework.zip' "$gha/workflows/_make.yml"
grep -q 'products/macos/WebRTC.xcframework.zip' "$gha/workflows/_make.yml"

if grep -qE 'make rename |final-(apple|android)-renamed|StreamWebRTC\.xcframework|libwebrtc-renamed\.aar' \
  "$gha/workflows/_make.yml"; then
  echo "wrapper artifact creation belongs in the downstream repositories" >&2
  exit 1
fi
grep -q 'rewrite-android-namespace.sh' "$ROOT/Makefile"
grep -q 'pin-android-java.sh' "$ROOT/Makefile"
grep -q 'direct_deps_only = false' "$ROOT/../sdk/android/BUILD.gn"
grep -q 'jar_excluded_patterns = stream_android_jar_excluded_patterns' \
  "$ROOT/../sdk/android/BUILD.gn"
grep -q '"kotlin/\*"' "$ROOT/../extensions/android/stream_android_jar.gni"
grep -q 'verify-android-jar.sh' "$ROOT/scripts/package-android.sh"
jar_root="$(mktemp -d)"
# make_jar OUT ENTRY...: an ENTRY not ending in .class is an empty file. A
# class ENTRY is "path.class" plus "|m=name:desc" (method), "|n=name:desc"
# (native method), and "|r=Owner.name:desc" (method reference).
make_jar() {
  python3 - "$@" <<'PY'
import struct, sys, zipfile
def cls(name, attrs):
    pool, index = [], {}
    def add(key, raw):
        if key not in index:
            pool.append(raw)
            index[key] = len(pool)
        return index[key]
    def utf8(s):
        b = s.encode()
        return add(("u", s), b"\x01" + struct.pack(">H", len(b)) + b)
    def klass(s):
        return add(("c", s), b"\x07" + struct.pack(">H", utf8(s)))
    def nat(n, d):
        return add(("n", n, d), b"\x0c" + struct.pack(">HH", utf8(n), utf8(d)))
    this_class, super_class = klass(name), klass("java/lang/Object")
    methods = b""
    count = 0
    for attr in attrs:
        kind, _, value = attr.partition("=")
        if kind == "r":
            owner_name, _, desc = value.partition(":")
            owner, _, mname = owner_name.rpartition(".")
            add(("r", value), b"\x0a" + struct.pack(">HH", klass(owner),
                                                     nat(mname, desc)))
        else:
            mname, _, desc = value.partition(":")
            access = 0x0108 if kind == "n" else 0x0009
            methods += struct.pack(">HHHH", access, utf8(mname), utf8(desc), 0)
            count += 1
    head = b"\xca\xfe\xba\xbe" + struct.pack(">HHH", 0, 52, len(pool) + 1)
    return (head + b"".join(pool)
            + struct.pack(">HHHHH", 0x21, this_class, super_class, 0, 0)
            + struct.pack(">H", count) + methods + struct.pack(">H", 0))
with zipfile.ZipFile(sys.argv[1], "w") as zf:
    for entry in sys.argv[2:]:
        path, *attrs = entry.split("|")
        if path.endswith(".class"):
            zf.writestr(path, cls(path[:-len(".class")], attrs))
        else:
            zf.writestr(path, b"")
PY
}
gen='org/jni_zero/GEN_JNI'
track_jni="org/webrtc/MediaStreamTrackJni.class|r=$gen.org_webrtc_MediaStreamTrack_getId:(J)Ljava/lang/String;"
track_gen="$gen.class|m=org_webrtc_MediaStreamTrack_getId:(J)Ljava/lang/String;"
make_jar "$jar_root/ok.jar" META-INF/MANIFEST.MF \
  org/webrtc/MediaStreamTrack.class "$track_jni" \
  "$track_gen|r=J/N.M0ETufK1:(J)Ljava/lang/String;" \
  'J/N.class|n=M0ETufK1:(J)Ljava/lang/String;' org/jni_zero/JniZero.class
"$ROOT/scripts/verify-android-jar.sh" --jar "$jar_root/ok.jar" >/dev/null
make_jar "$jar_root/repackaged.jar" \
  "io/getstream/webrtc/VideoTrackJni.class|r=$gen.io_getstream_webrtc_VideoTrack_addSink:(JJ)V" \
  "$gen.class|m=io_getstream_webrtc_VideoTrack_addSink:(JJ)V" \
  org/jni_zero/JniZero.class
"$ROOT/scripts/verify-android-jar.sh" --jar "$jar_root/repackaged.jar" >/dev/null
make_jar "$jar_root/nogenjni.jar" "$track_jni"
if "$ROOT/scripts/verify-android-jar.sh" --jar "$jar_root/nogenjni.jar" \
  2>"$jar_root/err"; then
  echo "expected a jar without GEN_JNI to fail" >&2
  exit 1
fi
grep -q 'no org/jni_zero/GEN_JNI.class' "$jar_root/err"
make_jar "$jar_root/nojn.jar" "$track_jni" \
  "$track_gen|r=J/N.M0ETufK1:(J)Ljava/lang/String;"
if "$ROOT/scripts/verify-android-jar.sh" --jar "$jar_root/nojn.jar" \
  2>"$jar_root/err"; then
  echo "expected GEN_JNI forwarding to a missing J.N to fail" >&2
  exit 1
fi
grep -q 'no J/N.class' "$jar_root/err"
# The 57-character name has length byte 0x39 ("9"), which a byte-pattern
# scan of the constant pool skips.
init='org_webrtc_PeerConnectionFactory_initializeAndroidGlobals'
make_jar "$jar_root/partial.jar" "$track_jni" \
  "org/webrtc/PeerConnectionFactoryJni.class|r=$gen.$init:()V" \
  "org/webrtc/VideoTrackJni.class|r=$gen.org_webrtc_VideoTrack_addSink:(JJ)V" \
  "$track_gen|m=org_webrtc_VideoTrack_addSink:(J)V"
if "$ROOT/scripts/verify-android-jar.sh" --jar "$jar_root/partial.jar" \
  2>"$jar_root/err"; then
  echo "expected GEN_JNI missing a proxy method to fail" >&2
  exit 1
fi
grep -q "org/webrtc/PeerConnectionFactoryJni: $init()V" "$jar_root/err"
grep -q 'org/webrtc/VideoTrackJni: org_webrtc_VideoTrack_addSink(JJ)V' \
  "$jar_root/err"
if grep -q 'MediaStreamTrack_getId' "$jar_root/err"; then
  echo "GEN_JNI check flagged a proxy method that is present" >&2
  exit 1
fi
grep -q '":libwebrtc_final_jni_java",' "$ROOT/../sdk/android/BUILD.gn"
grep -q 'srcjar_deps = \[ ":libjingle_peerconnection_so__jni_registration" \]' \
  "$ROOT/../sdk/android/BUILD.gn"
grep -q 'java_targets = \[ ":libwebrtc_java_targets" \]' \
  "$ROOT/../sdk/android/BUILD.gn"
grep -q '^  java_group("libwebrtc_java_targets") {' \
  "$ROOT/../sdk/android/BUILD.gn"
make_jar "$jar_root/kotlin.jar" "$track_jni" "$track_gen" \
  kotlin/TypeAliasesKt.class META-INF/kotlin-stdlib.kotlin_module
if "$ROOT/scripts/verify-android-jar.sh" --jar "$jar_root/kotlin.jar" \
  2>"$jar_root/err"; then
  echo "expected a jar with kotlin/ to fail" >&2
  exit 1
fi
grep -qx '  kotlin' "$jar_root/err"
make_jar "$jar_root/nojni.jar" org/webrtc/VideoTrack.class
if "$ROOT/scripts/verify-android-jar.sh" --jar "$jar_root/nojni.jar" \
  2>"$jar_root/err"; then
  echo "expected a jar without *Jni.class to fail" >&2
  exit 1
fi
grep -q 'no generated \*Jni.class' "$jar_root/err"
# make_so OUT SYMBOL...: an ELF64 library exporting SYMBOLs. ELF32=1 writes a
# 32-bit library (armeabi-v7a, x86). NO_SECTIONS=1 omits the section header
# table, like a fully stripped file.
make_so() {
  python3 - "$@" <<'PY'
import os, struct, sys
out, *names = sys.argv[1:]
is32 = os.environ.get("ELF32") == "1"
sym_fmt, sym_size = ("<IIIBBH", 16) if is32 else ("<IBBHQQ", 24)
sh_fmt, sh_size, eh_size = ("<IIIIIIIIII", 40, 52) if is32 else (
    "<IIQQQQIIQQ", 64, 64)
dynstr = b"\0" + b"".join(n.encode() + b"\0" for n in names)
syms = b"\0" * sym_size
pos = 1
for n in names:
    syms += (struct.pack(sym_fmt, pos, 0, 0, 0x12, 0, 1) if is32
             else struct.pack(sym_fmt, pos, 0x12, 0, 1, 0, 0))
    pos += len(n) + 1
data_off = eh_size
str_off = data_off + len(syms)
sh_off = str_off + len(dynstr)
sh = b"\0" * sh_size
sh += struct.pack(sh_fmt, 0, 11, 2, 0, data_off, len(syms), 2, 1, 4, sym_size)
sh += struct.pack(sh_fmt, 0, 3, 2, 0, str_off, len(dynstr), 0, 0, 1, 0)
shnum = 3
if os.environ.get("NO_SECTIONS") == "1":
    sh, sh_off, shnum = b"", 0, 0
if is32:
    ehdr = (b"\x7fELF\x01\x01\x01" + b"\0" * 9
            + struct.pack("<HHIIIIIHHHHHH", 3, 40, 1, 0, 0, sh_off, 0,
                          eh_size, 0, 0, sh_size, shnum, 0))
else:
    ehdr = (b"\x7fELF\x02\x01\x01" + b"\0" * 9
            + struct.pack("<HHIQQQIHHHHHH", 3, 183, 1, 0, 0, sh_off, 0,
                          eh_size, 0, 0, sh_size, shnum, 0))
open(out, "wb").write(ehdr + syms + dynstr + sh)
PY
}
make_jar "$jar_root/natives.jar" \
  'J/N.class|n=M0ETufK1:(J)V' \
  'org/webrtc/EncryptionManager.class|n=nativeCreate:(Ljava/lang/String;I)J|n=nativeDispose:(J)V|m=isEnabled:()Z' \
  'org/webrtc/Simulcast_Factory.class|n=nativeCreate:(J)J'
make_so "$jar_root/ok.so" Java_J_N_M0ETufK1 \
  Java_org_webrtc_EncryptionManager_nativeCreate \
  'Java_org_webrtc_EncryptionManager_nativeDispose__J' \
  Java_org_webrtc_Simulcast_1Factory_nativeCreate
ELF32=1 make_so "$jar_root/ok32.so" Java_J_N_M0ETufK1 \
  Java_org_webrtc_EncryptionManager_nativeCreate \
  Java_org_webrtc_EncryptionManager_nativeDispose \
  Java_org_webrtc_Simulcast_1Factory_nativeCreate
"$ROOT/scripts/verify-android-natives.sh" --jar "$jar_root/natives.jar" \
  --so "$jar_root/ok.so" --so "$jar_root/ok32.so" >/dev/null
ELF32=1 make_so "$jar_root/nodefine32.so" Java_J_N_M0ETufK1 \
  Java_org_webrtc_EncryptionManager_nativeCreate
if "$ROOT/scripts/verify-android-natives.sh" --jar "$jar_root/natives.jar" \
  --so "$jar_root/nodefine32.so" 2>"$jar_root/err"; then
  echo "expected a 32-bit library missing exports to fail" >&2
  exit 1
fi
grep -q 'nodefine32.so exports no Java_\* symbol for 2 native methods' \
  "$jar_root/err"
make_so "$jar_root/nodefine.so" Java_J_N_M0ETufK1 \
  Java_org_webrtc_Simulcast_1Factory_nativeCreate
if "$ROOT/scripts/verify-android-natives.sh" --jar "$jar_root/natives.jar" \
  --so "$jar_root/ok.so" --so "$jar_root/nodefine.so" 2>"$jar_root/err"; then
  echo "expected natives without exports to fail" >&2
  exit 1
fi
grep -q 'nodefine.so exports no Java_\* symbol for 2 native methods' \
  "$jar_root/err"
grep -q '  org/webrtc/EncryptionManager.nativeCreate(Ljava/lang/String;I)J' \
  "$jar_root/err"
if grep -q 'ok.so\|isEnabled' "$jar_root/err"; then
  echo "verify-android-natives.sh flagged a library or a non-native method" >&2
  exit 1
fi
NO_SECTIONS=1 make_so "$jar_root/stripped.so" Java_J_N_M0ETufK1
if "$ROOT/scripts/verify-android-natives.sh" --jar "$jar_root/natives.jar" \
  --so "$jar_root/stripped.so" 2>"$jar_root/err"; then
  echo "expected a library without section headers to fail" >&2
  exit 1
fi
grep -q 'stripped.so has no ELF section headers' "$jar_root/err"
python3 - "$ROOT/scripts" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from jvm_classfile import _modified_utf8, jni_mangle
# U+1F600 as modified UTF-8: two 3-byte surrogates. JNI escapes each
# UTF-16 unit.
name = _modified_utf8(b"a\xed\xa0\xbd\xed\xb8\x80_b\xc0\x80")
assert jni_mangle(name) == "a_0d83d_0de00_1b_00000", jni_mangle(name)
PY
grep -q 'verify-android-natives.sh' "$ROOT/scripts/package-android.sh"
grep -q -- '--slices lists no slices' "$ROOT/scripts/package-android.sh"
grep -q '^DEFINE_JNI(EncryptionManager)$' \
  "$ROOT/../sdk/android/src/jni/pc/encryption_manager.cc"
rm -rf "$jar_root"
jni_root="$(mktemp -d)"
mkdir -p "$jni_root/sdk/android/api/org/webrtc" "$jni_root/sdk/android/src/jni"
cat > "$jni_root/sdk/android/BUILD.gn" <<'EOF'
dist_jar("libwebrtc") {
  deps = [ ":foo_java", ":bar_java", ":libwebrtc_final_jni_java" ]
}
rtc_android_library("foo_java") {
  deps = [ ":generated_foo_jni_java" ]
}
rtc_android_library("bar_java") {
  deps = [ ":generated_bar_jni_java" ]
}
rtc_shared_library("libjingle_peerconnection_so") {
  deps = [ ":foo_jni", "//third_party/jni_zero" ]
  java_targets = [ ":libwebrtc_java_targets" ]
}
rtc_library("foo_jni") {
  sources = [ "src/jni/foo.cc" ]
  deps = [ ":generated_foo_jni" ]
}
rtc_library("bar_jni") {
  sources = [ "src/jni/bar.cc" ]
  deps = [ ":generated_bar_jni" ]
}
generate_jni("generated_foo_jni") {
  sources = [ "api/org/webrtc/Foo.java", "api/org/webrtc/Old.java" ]
}
generate_jni("generated_bar_jni") {
  sources = [ "api/org/webrtc/Bar.java" ]
}
EOF
printf 'class Foo { @NativeMethods interface Natives { long create(); } }\n' \
  > "$jni_root/sdk/android/api/org/webrtc/Foo.java"
printf 'class Old {\n  // a native call\n  private static native long nativeCreate();\n}\n' \
  > "$jni_root/sdk/android/api/org/webrtc/Old.java"
printf 'class Bar { @NativeMethods interface Natives { long create(); } }\n' \
  > "$jni_root/sdk/android/api/org/webrtc/Bar.java"
printf '#include "sdk/android/generated_foo_jni/Foo_jni.h"\n' \
  > "$jni_root/sdk/android/src/jni/foo.cc"
printf '#include "sdk/android/generated_bar_jni/Bar_jni.h"\nDEFINE_JNI(Bar)\n' \
  > "$jni_root/sdk/android/src/jni/bar.cc"
if "$ROOT/scripts/check-android-jni.sh" --src "$jni_root" 2>"$jni_root/err"; then
  echo "expected check-android-jni.sh to fail" >&2
  exit 1
fi
grep -q 'generated_bar_jni: libwebrtc packs its Java, but' "$jni_root/err"
grep -q 'foo.cc: includes Foo_jni.h but never invokes DEFINE_JNI(Foo)' \
  "$jni_root/err"
grep -q 'Old.java:3: plain `native` method' "$jni_root/err"
if grep -q 'bar.cc\|Bar.java\|Foo.java' "$jni_root/err"; then
  echo "check-android-jni.sh flagged a file that invokes DEFINE_JNI" >&2
  exit 1
fi
cp "$jni_root/sdk/android/BUILD.gn" "$jni_root/sdk/android/BUILD.gn.good"
python3 - "$jni_root/sdk/android/BUILD.gn" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
text = text.replace(', ":libwebrtc_final_jni_java"', "")
text = text.replace('  java_targets = [ ":libwebrtc_java_targets" ]\n', "")
open(path, "w").write(text)
PY
if "$ROOT/scripts/check-android-jni.sh" --src "$jni_root" 2>"$jni_root/err"; then
  echo "expected missing GEN_JNI wiring to fail" >&2
  exit 1
fi
grep -q 'deps omit :libwebrtc_final_jni_java' "$jni_root/err"
grep -q 'java_targets omit :libwebrtc_java_targets' "$jni_root/err"
cp "$jni_root/sdk/android/BUILD.gn.good" "$jni_root/sdk/android/BUILD.gn"
sed -i.bak 's/deps = \[ ":foo_jni",/deps = [ ":foo_jni", ":bar_jni",/' \
  "$jni_root/sdk/android/BUILD.gn"
printf '#include "sdk/android/generated_foo_jni/Foo_jni.h"\nDEFINE_JNI(Foo)\n' \
  > "$jni_root/sdk/android/src/jni/foo.cc"
printf 'class Old { @NativeMethods interface Natives { long create(); } }\n' \
  > "$jni_root/sdk/android/api/org/webrtc/Old.java"
"$ROOT/scripts/check-android-jni.sh" --src "$jni_root" >/dev/null
grep -q 'check-android-jni.sh' "$ROOT/../agents/skills/migrate/resolve-conflicts.md"
rm -rf "$jni_root"
pin_root="$(mktemp -d)"
mkdir -p "$pin_root/build/android/gyp"
cat > "$pin_root/build/android/gyp/compile_java.py" <<'EOF'
        # Keep consistent with javac_cmd in //build/android/gyp/turbine.py.
        # LINT.IfChange
        '25',
EOF
printf "%s\n" "    javac_cmd = ['--release', '25']" \
  > "$pin_root/build/android/gyp/turbine.py"
"$ROOT/scripts/pin-android-java.sh" --src "$pin_root"
grep -q "'17'" "$pin_root/build/android/gyp/compile_java.py"
grep -q "'17'" "$pin_root/build/android/gyp/turbine.py"
"$ROOT/scripts/pin-android-java.sh" --src "$pin_root"
grep -q "'17'" "$pin_root/build/android/gyp/compile_java.py"
printf '%s\n' 'javac_cmd = ["--release", "25"]' \
  > "$pin_root/build/android/gyp/turbine.py"
if "$ROOT/scripts/pin-android-java.sh" --src "$pin_root" 2>"$pin_root/err"; then
  echo "expected a moved Java release pin to fail" >&2
  exit 1
fi
grep -q 'Java release pin not found' "$pin_root/err" || {
  echo "unexpected pin failure:" >&2
  cat "$pin_root/err" >&2
  exit 1
}
rm -rf "$pin_root"
grep -q 'env -u TARGET' "$ROOT/Makefile"
grep -q 'libjingle_peerconnection_so/libstream_jingle_peerconnection_so' "$ROOT/Makefile"
grep -q 'io.getstream.webrtc' "$gha/workflows/_make.yml"
grep -q 'products-android-repackaged' "$gha/workflows/_make.yml"
grep -q 'final-android/libwebrtc.aar' "$gha/workflows/_make.yml"
grep -q 'variant=repackaged' "$gha/workflows/promote-release.yml"
grep -q 'promote_from_upstream_tag' "$gha/workflows/promote-release.yml"
! grep -q 'android_namespace:' "$gha/workflows/build.yml"
! grep -q 'android_namespace:' "$gha/workflows/package.yml"
! grep -q 'android_namespace:' "$gha/workflows/release.yml"
test ! -e "$gha/workflows/manual-platform-tests.yml"
test ! -e "$gha/workflows/publish.yml"
test ! -e "$gha/actions/prepare-apple/action.yml"
test ! -e "$gha/actions/prepare-android/action.yml"
test ! -e "$gha/actions/prepare-common-v2/action.yml"
grep -q 'pull_request:' "$gha/workflows/test.yml"
grep -q "github.event.pull_request.head.sha" "$gha/workflows/test.yml"
grep -q 'name: Build Android$' "$gha/workflows/_make.yml"
! grep -q 'name: Build Android (${{' "$gha/workflows/_make.yml"
grep -q 'name: Test Android' "$gha/workflows/_make.yml"
grep -q "(inputs.mode == 'test' || inputs.mode == 'release') && inputs.android" "$gha/workflows/_make.yml"
grep -q 'needs: \[plan, test_ios, test_macos, test_android, test_windows\]' "$gha/workflows/_make.yml"
grep -q 'Release is blocked: Android tests' "$gha/workflows/_make.yml"
grep -q 'make test android' "$gha/workflows/_make.yml"
test_jobs="$(awk '/name: Test iOS$/,/name: Tests passed$/' "$gha/workflows/_make.yml")"
! grep -q 'artifact-put' <<<"$test_jobs"
! grep -q 'make test android is not wired' "$gha/workflows/_make.yml"
grep -q 'run-android-tests.sh' "$ROOT/Makefile"
grep -q -- '--overlay android-test' "$ROOT/Makefile"
grep -q 'ANDROID_TEST_OUT := $(WEBRTC_SRC)/out/android_tests' "$ROOT/Makefile"
! grep -q -- '--out "$(OUT)/android_tests"' "$ROOT/Makefile"
! grep -q 'no device runner' "$ROOT/Makefile"
grep -q 'target_os = "android"' "$ROOT/gn/android-test.args"
grep -q 'target_cpu = "x64"' "$ROOT/gn/android-test.args"
grep -q 'rtc_include_tests = true' "$ROOT/gn/android-test.args"
grep -q 'android-gtest-filter.txt' "$ROOT/scripts/run-android-tests.sh"
grep -q '^-AudioDeviceTest.RunPlayoutWithFileAsSource$' "$ROOT/scripts/android-gtest-filter.txt"
grep -q '^-AudioDeviceTest.VerifyAudioParameters$' "$ROOT/scripts/android-gtest-filter.txt"
bash -n "$ROOT/scripts/run-android-tests.sh"
python3 - <<'PY'
import os
def device_rel(host, output):
    rel = os.path.relpath(host, output)
    parts = []
    while rel:
        rel, name = os.path.split(rel)
        if name and name != os.pardir:
            parts.insert(0, name)
    return "/".join(parts)
host = "/webrtc/src/resources/reference_video_640x360_30fps.y4m"
sibling = device_rel(host, "/webrtc/out/android_tests")
inside = device_rel(host, "/webrtc/src/out/android_tests")
assert sibling == "src/resources/reference_video_640x360_30fps.y4m", sibling
assert inside == "resources/reference_video_640x360_30fps.y4m", inside
PY

cache_sh="$gha/scripts/webrtc-cache.sh"
cache_wf="$gha/workflows/update-webrtc-cache.yml"
cache_daily="$gha/workflows/update-webrtc-cache-daily.yml"
bash -n "$cache_sh"
got="$("$cache_sh" resolve-tag automatic 42 3 20261109)"
[[ "$got" == "20261109-42.3" ]]
got="$("$cache_sh" resolve-tag '' 42 3 20261109)"
[[ "$got" == "20261109-42.3" ]]
got="$("$cache_sh" resolve-tag '  nightly_1  ' 42 3 20261109)"
[[ "$got" == "nightly_1" ]]
if "$cache_sh" resolve-tag current 1 1 20261109 >/dev/null; then
  echo "expected tag current to be rejected" >&2
  exit 1
fi
if "$cache_sh" resolve-tag latest 1 1 20261109 >/dev/null; then
  echo "expected tag latest to be rejected" >&2
  exit 1
fi
fp_root="$(mktemp -d)"
fp_empty="$(CACHE_ROOT="$fp_root" "$cache_sh" fingerprint)"
mkdir -p "$fp_root/.gclient-git-cache/repo"
printf 'x' > "$fp_root/.gclient-git-cache/repo/obj"
fp_changed="$(CACHE_ROOT="$fp_root" "$cache_sh" fingerprint)"
[[ "$fp_empty" != "$fp_changed" ]]
list="$(CACHE_ROOT="$fp_root" "$cache_sh" list-members)"
[[ "$list" == ".gclient-git-cache" ]]
rm -rf "$fp_root"
[[ "$("$cache_sh" members-for ios)" == ".cipd src/resources" ]]
[[ "$("$cache_sh" members-for macos)" == ".cipd src/resources" ]]
android_members="$("$cache_sh" members-for android)"
[[ "$android_members" == ".cipd src/resources src/build/linux/*-sysroot" ]]
if "$cache_sh" members-for windows >/dev/null; then
  echo "expected windows tools platform to be rejected" >&2
  exit 1
fi
tools="$(mktemp -d)"
mkdir -p \
  "$tools/.cipd" \
  "$tools/src/resources" \
  "$tools/src/build/linux/debian_bullseye_amd64-sysroot/usr" \
  "$tools/src/build/linux/debian_bullseye_i386-sysroot" \
  "$tools/src/build/linux/sysroot_scripts"
printf 'x' > "$tools/.cipd/pkg"
printf 'y' > "$tools/src/resources/clip.y4m"
printf 'z' > "$tools/src/build/linux/debian_bullseye_amd64-sysroot/usr/lib.so"
printf 's' > "$tools/src/build/linux/sysroot_scripts/install-sysroot.py"
tools_list="$(ARCHIVE_ROOT="$tools" ARCHIVE_MEMBERS="$android_members" "$cache_sh" list-members)"
[[ "$tools_list" == $'.cipd\nsrc/resources\nsrc/build/linux/debian_bullseye_amd64-sysroot' ]]
rm -rf "$tools"
if "$cache_sh" resolve-tag 'bad tag' 1 1 20261109 >/dev/null; then
  echo "expected invalid tag to be rejected" >&2
  exit 1
fi
grep -q 'starting from an empty git cache' "$cache_sh"
grep -q 'retry_oras oras blob fetch' "$cache_sh"
grep -q 'PULL_CONCURRENCY:-3' "$cache_sh"
grep -q 'wait -n' "$cache_sh"
grep -q 'stitching' "$cache_sh"
grep -q 'zstd -d -T0 -c -v' "$cache_sh"
! grep -q 'report_extract' "$cache_sh"
grep -q 'retry_oras oras blob push' "$cache_sh"
grep -q 'retry_oras oras tag' "$cache_sh"
grep -q 'chunks-done' "$cache_sh"
grep -q 'zstd -T0 -3 -c -v' "$cache_sh"
grep -q 'name: Update WebRTC Cache$' "$cache_wf"
grep -q 'workflow_dispatch:' "$cache_wf"
grep -q 'workflow_call:' "$cache_wf"
! grep -q 'schedule:' "$cache_wf"
grep -q 'packages: write' "$cache_wf"
grep -q 'contents: read' "$cache_wf"
grep -q 'github.token' "$gha/actions/restore-git-cache/action.yml"
! grep -q 'secrets\.' "$cache_wf"
grep -q 'ghcr.io/getstream/webrtc-cache' "$cache_wf"
grep -q 'default: automatic' "$cache_wf"
grep -q 'default: true' "$cache_wf"
grep -q 'TARGET_OS: ios,mac,android,unix' "$cache_wf"
grep -q 'RUN_HOOKS: "0"' "$cache_wf"
grep -q 'restore-git-cache' "$cache_wf"
grep -q 'skip_latest_pull:' "$cache_wf"
grep -q 'skip: ${{ inputs.skip_latest_pull }}' "$cache_wf"
grep -q 'cache unchanged; left' "$cache_wf"
grep -q 'needs.publish.outputs.run_tools' "$cache_wf"
grep -q 'needs.publish.outputs.git_cache_tag' "$cache_wf"
grep -q 'tools-status' "$cache_wf"
grep -q 'tools package missing; publishing from the current git cache' "$cache_wf"
grep -q 'tools-status' "$cache_sh"
grep -q 'ghcr.io/getstream/webrtc-tools-' "$cache_wf"
grep -q 'members-for' "$cache_wf"
grep -q 'platform: android' "$cache_wf"
grep -q 'target_os: android,unix' "$cache_wf"
grep -q 'members-for' "$gha/actions/restore-tools/action.yml"
grep -q 'ghcr.io/getstream/webrtc-tools-' "$gha/actions/restore-tools/action.yml"
grep -q 'restore-tools' "$gha/actions/restore-tree/action.yml"
grep -q 'build-android) platform=android' "$gha/actions/restore-tree/action.yml"
grep -q 'dirname "$GITHUB_WORKSPACE"' "$gha/actions/restore-git-cache/action.yml"
grep -q 'oras-project/setup-oras@v2$' "$gha/actions/restore-git-cache/action.yml"
grep -q 'packages: read' "$gha/workflows/build.yml"
grep -q 'packages: read' "$gha/workflows/test.yml"
! grep -q 'ORAS_SHA256' "$cache_wf"
grep -q 'group: webrtc-cache' "$cache_wf"
! grep -q 'concurrency:' "$cache_daily"
grep -q 'name: Update WebRTC Cache daily' "$cache_daily"
grep -q 'cron: "0 4 \* \* \*"' "$cache_daily"
grep -q 'uses: \./\.github/workflows/update-webrtc-cache\.yml' "$cache_daily"
grep -q 'packages: write' "$cache_daily"
grep -q 'tag: automatic' "$cache_daily"
grep -q 'update_latest: true' "$cache_daily"
! grep -q 'update_current' "$cache_wf"
! grep -q 'update_current' "$cache_daily"
! grep -q 'workflow_dispatch:' "$cache_daily"
[[ ! -e "$gha/workflows/webrtc-cache.yml" ]]

echo "ok"
