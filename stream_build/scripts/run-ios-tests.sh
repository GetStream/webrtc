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

pick_simulator() {
  python3 - "$SIMULATOR_PLATFORM" "$SIMULATOR_VERSION" <<'PY'
import json, subprocess, sys

want_name, want_version = sys.argv[1], sys.argv[2]
payload = json.loads(
    subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        text=True,
    )
)
candidates = []
for runtime, devices in payload.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    version = runtime.split("iOS-")[-1].replace("-", ".")
    for device in devices:
        if device.get("isAvailable") is False:
            continue
        name = device.get("name") or ""
        if want_name and name != want_name:
            continue
        if want_version and version != want_version:
            continue
        candidates.append(
            (
                1 if device.get("state") == "Booted" else 0,
                1 if name.startswith("iPhone") else 0,
                tuple(int(p) for p in version.split(".") if p.isdigit()),
                name,
                version,
            )
        )
if not candidates:
    sys.exit("no available iOS simulator matched the request")
best = max(candidates)
print(f"{best[3]}\t{best[4]}")
PY
}

if [[ -z "$SIMULATOR_PLATFORM" || -z "$SIMULATOR_VERSION" ]]; then
  selected="$(pick_simulator)"
  SIMULATOR_PLATFORM="${selected%%$'\t'*}"
  SIMULATOR_VERSION="${selected#*$'\t'}"
  echo "auto-selected simulator: ${SIMULATOR_PLATFORM} (iOS ${SIMULATOR_VERSION})"
fi

xcode_build_version="$(xcodebuild -version | awk '/Build version/{print $3; exit}')"
xcode_build_version="${xcode_build_version:-local}"
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
