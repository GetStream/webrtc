#!/usr/bin/env bash
# Run Android gtests on an adb device. Starts an x64 emulator when none is connected.
# System image is API 34 google_apis x86_64, downloaded into the
# WebRTC SDK tree on each cold run (third_party is not in the Hetzner cache).
# Upgrade path: bake that image into the runner or the build-android cache.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_linux
require_cmd python3
require_cmd vpython3

# Generated wrappers are `#!/usr/bin/env vpython3` and probe upward for
# .vpython3. out/ is a sibling of src/, so point vpython at the spec.
vpython_spec="${WEBRTC_SRC:-$(cd "${PIPELINE_DIR}/.." && pwd)}/.vpython3"
[[ -f "$vpython_spec" ]] || die "missing vpython spec: ${vpython_spec}"

BUILD_DIR=""
TARGETS=""
EXTRA_ARGS="${EXTRA_ARGS:-}"
IMAGE="system-images;android-34;google_apis;x86_64"
AVD_NAME="webrtc-test"
EMU_PID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir) BUILD_DIR="$2"; shift 2 ;;
    --targets) TARGETS="$2"; shift 2 ;;
    --extra) EXTRA_ARGS="${2:-}"; shift 2 ;;
    *) die "run-android-tests.sh: unknown flag $1" ;;
  esac
done

[[ -n "$BUILD_DIR" && -n "$TARGETS" ]] || die "run-android-tests.sh requires --build-dir and --targets"

webrtc_src="${WEBRTC_SRC:-$(cd "${PIPELINE_DIR}/.." && pwd)}"
webrtc_sdk="${webrtc_src}/third_party/android_sdk/public"
[[ -d "$webrtc_sdk" ]] || die "Android SDK missing at ${webrtc_sdk} (make deps with an android target_os)"

cleanup() {
  if [[ -n "${EMU_PID}" ]]; then
    kill "${EMU_PID}" 2>/dev/null || true
    wait "${EMU_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

pick_jdk() {
  local candidate
  for candidate in \
    /usr/lib/jvm/java-21-openjdk-amd64 \
    /usr/lib/jvm/java-17-openjdk-amd64 \
    /usr/lib/jvm/java-11-openjdk-amd64
  do
    if [[ -x "${candidate}/bin/java" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# Roots captured before ANDROID_SDK_ROOT is pointed at the WebRTC SDK.
RUNNER_SDK_ROOTS=()
[[ -d /usr/local/lib/android/sdk ]] && RUNNER_SDK_ROOTS+=(/usr/local/lib/android/sdk)
[[ -n "${ANDROID_SDK_ROOT:-}" && -d "${ANDROID_SDK_ROOT}" ]] && RUNNER_SDK_ROOTS+=("$ANDROID_SDK_ROOT")
[[ -n "${ANDROID_HOME:-}" && -d "${ANDROID_HOME}" ]] && RUNNER_SDK_ROOTS+=("$ANDROID_HOME")

find_sdk_bin() {
  local name="$1"
  shift
  local root candidate
  for root in "$@"; do
    [[ -n "$root" && -d "$root" ]] || continue
    for candidate in \
      "${root}/cmdline-tools/latest/bin/${name}" \
      "${root}/cmdline-tools/bin/${name}"
    do
      if [[ -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  done
  return 1
}

device_ready() {
  command -v adb >/dev/null 2>&1 || return 1
  adb devices | awk 'NR>1 && $2=="device" { found=1 } END { exit found ? 0 : 1 }'
}

install_emulator() {
  local sdkmanager jdk
  sdkmanager="$(find_sdk_bin sdkmanager "${RUNNER_SDK_ROOTS[@]+"${RUNNER_SDK_ROOTS[@]}"}" "$webrtc_sdk" || true)"
  [[ -n "$sdkmanager" ]] || die "sdkmanager not found; cannot install ${IMAGE}"
  if jdk="$(pick_jdk)"; then
    export JAVA_HOME="$jdk"
    export PATH="${JAVA_HOME}/bin:${PATH}"
  fi
  echo "installing ${IMAGE} into ${webrtc_sdk}"
  yes | "$sdkmanager" --sdk_root="$webrtc_sdk" --licenses >/dev/null || true
  "$sdkmanager" --sdk_root="$webrtc_sdk" \
    "cmdline-tools;latest" "platform-tools" "emulator" "$IMAGE"
}

ensure_device() {
  export ANDROID_SDK_ROOT="$webrtc_sdk"
  export ANDROID_HOME="$webrtc_sdk"
  export PATH="${webrtc_sdk}/platform-tools:${PATH}"

  if device_ready; then
    echo "using connected adb device"
    return 0
  fi

  local emulator_bin image_dir
  emulator_bin="${webrtc_sdk}/emulator/emulator"
  image_dir="${webrtc_sdk}/system-images/android-34/google_apis/x86_64"
  if [[ ! -x "$emulator_bin" || ! -d "$image_dir" ]]; then
    install_emulator
  fi
  [[ -x "$emulator_bin" && -d "$image_dir" ]] || die "emulator or ${IMAGE} still missing under ${webrtc_sdk}"
  export PATH="${webrtc_sdk}/platform-tools:${PATH}"
  command -v adb >/dev/null 2>&1 || die "adb missing after emulator install"

  if [[ -c /dev/kvm && ! -w /dev/kvm ]]; then
    sudo chmod 666 /dev/kvm || die "/dev/kvm is not writable"
  fi
  [[ -w /dev/kvm ]] || die "Android emulator needs /dev/kvm or an already connected adb device"

  local avdmanager
  avdmanager="$(find_sdk_bin avdmanager "$webrtc_sdk" "${RUNNER_SDK_ROOTS[@]+"${RUNNER_SDK_ROOTS[@]}"}" || true)"
  [[ -n "$avdmanager" ]] || die "avdmanager not found after installing cmdline-tools"

  export ANDROID_AVD_HOME="${BUILD_DIR}/avd"
  export ANDROID_EMULATOR_HOME="${BUILD_DIR}/emulator-home"
  mkdir -p "$ANDROID_AVD_HOME" "$ANDROID_EMULATOR_HOME"
  "$avdmanager" create avd --force -n "$AVD_NAME" -k "$IMAGE" >/dev/null <<EOF
no
EOF

  echo "starting emulator ${AVD_NAME}"
  "$emulator_bin" -avd "$AVD_NAME" -no-window -no-audio -no-boot-anim \
    -gpu swiftshader_indirect -no-snapshot -accel on \
    >"${BUILD_DIR}/emulator.log" 2>&1 &
  EMU_PID=$!

  adb wait-for-device
  local _ boot
  for _ in $(seq 1 150); do
    boot="$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    if [[ "$boot" == "1" ]]; then
      echo "emulator booted"
      return 0
    fi
    if ! kill -0 "$EMU_PID" 2>/dev/null; then
      die "emulator exited early; see ${BUILD_DIR}/emulator.log"
    fi
    sleep 2
  done
  die "emulator did not finish booting; see ${BUILD_DIR}/emulator.log"
}

run_target() {
  local target="$1"
  local wrapper="${BUILD_DIR}/bin/run_${target}"
  [[ -e "$wrapper" ]] || die "run script not found for ${target} at ${wrapper}"
  local args=()
  local filter_file="${SCRIPT_DIR}/android-gtest-filter.txt"
  # A caller-supplied filter replaces the emulator list. The runner treats
  # --gtest-filter and --gtest-filter-file as mutually exclusive.
  case " ${EXTRA_ARGS} " in
    *--gtest-filter*|*--gtest_filter*|*--test-filter*|*--gtest-filter-file*|*--test-launcher-filter-file*)
      ;;
    *)
      [[ -f "$filter_file" ]] || die "missing ${filter_file}"
      args+=(--gtest-filter-file "$filter_file")
      ;;
  esac
  # shellcheck disable=SC2086
  if [[ -n "$EXTRA_ARGS" ]]; then
    # shellcheck disable=SC2206
    args+=($EXTRA_ARGS)
  fi
  echo "running ${wrapper} ${args[*]}"
  vpython3 -vpython-spec "$vpython_spec" "$wrapper" "${args[@]}"
}

ensure_device
# shellcheck disable=SC2086
for target in $TARGETS; do
  run_target "$target"
done
