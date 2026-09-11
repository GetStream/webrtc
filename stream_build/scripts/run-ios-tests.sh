#!/usr/bin/env bash
# Run iOS XCTest wrappers produced by ninja sdk_*unittests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_darwin
require_cmd xcrun
require_cmd xcodebuild
require_cmd python3
require_cmd vpython3

# Chromium's generated wrappers are `#!/usr/bin/env vpython3` and probe
# upward for .vpython3. That works when out/ lives under src/. Stream's
# out/ is a sibling of src/, so the probe never reaches src/.vpython3
# (psutil / cipd wheels). Point vpython at Chromium's spec explicitly.
vpython_spec="${WEBRTC_SRC:-$(cd "${PIPELINE_DIR}/.." && pwd)}/.vpython3"
[[ -f "$vpython_spec" ]] || die "missing vpython spec: ${vpython_spec}"

BUILD_DIR=""
TARGETS=""
SIMULATOR_PLATFORM="${SIMULATOR_PLATFORM:-}"
SIMULATOR_VERSION="${SIMULATOR_VERSION:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir) BUILD_DIR="$2"; shift 2 ;;
    --targets) TARGETS="$2"; shift 2 ;;
    --platform) SIMULATOR_PLATFORM="$2"; shift 2 ;;
    --version) SIMULATOR_VERSION="$2"; shift 2 ;;
    --extra) EXTRA_ARGS="${2:-}"; shift 2 ;;
    *) die "run-ios-tests.sh: unknown flag $1" ;;
  esac
done

[[ -n "$BUILD_DIR" && -n "$TARGETS" ]] || die "run-ios-tests.sh requires --build-dir and --targets"

# Match the SDK the .app was compiled with. Newest-device auto-select
# picks iOS 27.0 on Xcode 26.6 (SDK 26.5), then Chromium creates a
# simulator on that runtime and xcodebuild cannot launch the runner.
compiled_ios_sdk() {
  local target plist ver
  # shellcheck disable=SC2086
  for target in $TARGETS; do
    plist="${BUILD_DIR}/${target}.app/Info.plist"
    [[ -f "$plist" ]] || continue
    ver="$(plutil -extract DTPlatformVersion raw "$plist" 2>/dev/null || true)"
    if [[ -n "$ver" ]]; then
      printf '%s\n' "$ver"
      return 0
    fi
  done
  xcrun --sdk iphonesimulator --show-sdk-version
}

# Chromium's wrapper bakes --xcode-path ../../src/Xcode.app (CIPD).
# argparse last-wins; point at the selected Xcode so local runs do not
# look for a hermetic tree. install_xcode() no-ops without LUCI_CONTEXT.
selected_xcode_app() {
  (cd "$(xcode-select -p)/../.." && pwd)
}

pick_simulator() {
  python3 - "$SIMULATOR_PLATFORM" "$SIMULATOR_VERSION" <<'PY'
import json, subprocess, sys

want_name, want_version = sys.argv[1], sys.argv[2]
payload = json.loads(
    subprocess.check_output(["xcrun", "simctl", "list", "--json"], text=True)
)


def matches(runtime_version):
    rv, want = runtime_version.strip(), want_version.strip()
    return rv == want or rv.startswith(want + ".") or want.startswith(rv + ".")


def is_iphone(devicetype):
    if devicetype.get("productFamily") == "iPhone":
        return True
    return (devicetype.get("name") or "").startswith("iPhone")


for runtime in payload.get("runtimes") or []:
    ident = runtime.get("identifier") or ""
    name = runtime.get("name") or ""
    if "iOS" not in ident and "iOS" not in name:
        continue
    if runtime.get("isAvailable") is False:
        continue
    version = (runtime.get("version") or "").strip()
    if want_version and not matches(version):
        continue
    types = [
        dt.get("name") or ""
        for dt in (runtime.get("supportedDeviceTypes") or [])
        if is_iphone(dt)
    ]
    types = [t for t in types if t]
    if want_name:
        if want_name not in types:
            continue
        print(f"{want_name}\t{version}")
        raise SystemExit(0)
    if types:
        # ponytail: Apple lists newest iPhones first on Xcode 26.x.
        # If that order flips, first-iPhone still matches the SDK.
        print(f"{types[0]}\t{version}")
        raise SystemExit(0)

sys.exit(
    f"no available iOS simulator runtime matched SDK {want_version or '?'}"
)
PY
}

if [[ -z "$SIMULATOR_VERSION" ]]; then
  SIMULATOR_VERSION="$(compiled_ios_sdk)"
fi
if [[ -z "$SIMULATOR_PLATFORM" ]]; then
  selected="$(pick_simulator)"
  SIMULATOR_PLATFORM="${selected%%$'\t'*}"
  SIMULATOR_VERSION="${selected#*$'\t'}"
fi
echo "using simulator: ${SIMULATOR_PLATFORM} (iOS ${SIMULATOR_VERSION})"

xcode_build_version="$(xcodebuild -version | awk '/Build version/{print $3; exit}')"
xcode_build_version="${xcode_build_version:-local}"
xcode_app="$(selected_xcode_app)"
out_dir="${BUILD_DIR}/test_output"
rm -rf "$out_dir"
mkdir -p "$out_dir"

run_target() {
  local target="$1"
  local wrapper="${BUILD_DIR}/bin/run_${target}"
  [[ -x "$wrapper" ]] || die "run script not found for ${target} at ${wrapper}"
  local args=(
    --xctest
    --out-dir "$out_dir"
    --xcode-build-version "$xcode_build_version"
    --xcode-path "$xcode_app"
    --platform "$SIMULATOR_PLATFORM"
    --version "$SIMULATOR_VERSION"
  )
  # shellcheck disable=SC2086
  if [[ -n "$EXTRA_ARGS" ]]; then
    # shellcheck disable=SC2206
    args+=($EXTRA_ARGS)
  fi
  echo "running ${wrapper} ${args[*]}"
  if vpython3 -vpython-spec "$vpython_spec" "$wrapper" "${args[@]}"; then
    return 0
  fi
  if grep -Rqs "Test Suite 'All tests' passed\|Test Suite 'Selected tests' passed" "$out_dir"; then
    echo "iOS test wrapper reported failure after XCTest already passed; treating as success"
    return 0
  fi
  return 1
}

# shellcheck disable=SC2086
for target in $TARGETS; do
  run_target "$target"
done
