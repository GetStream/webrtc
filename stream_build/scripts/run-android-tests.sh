#!/usr/bin/env bash
# Run Android gtests on an adb device.
# ADB_SERVER (host:port) uses an emulator already on that server.
# With no server, this environment boots an API 34 google_apis image
# for ARCH (x64 or arm64). The image is stored in the WebRTC SDK tree.
# No /dev/kvm starts that emulator with -accel off.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

BUILD_DIR=""
TARGETS=""
EXTRA_ARGS="${EXTRA_ARGS:-}"
ARCH_ARG="x64"
ADB_SERVER_ARG=""
CHECK_ARGS=0
CHECK_DEVICE=0
EMU_PID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir) BUILD_DIR="$2"; shift 2 ;;
    --targets) TARGETS="$2"; shift 2 ;;
    --extra) EXTRA_ARGS="${2:-}"; shift 2 ;;
    --arch) ARCH_ARG="$2"; shift 2 ;;
    --adb-server) ADB_SERVER_ARG="$2"; shift 2 ;;
    --check-args) CHECK_ARGS=1; shift ;;
    --check-device) CHECK_DEVICE=1; shift ;;
    *) die "run-android-tests.sh: unknown flag $1" ;;
  esac
done

case "$ARCH_ARG" in
  x64|arm64) ;;
  *)
    die "ARCH must be x64 or arm64 (got '${ARCH_ARG}'). x64 matches the Linux CI emulator. arm64 matches an arm64-v8a emulator."
    ;;
esac
if [[ -n "$ADB_SERVER_ARG" && ! "$ADB_SERVER_ARG" =~ ^[A-Za-z0-9._-]+:[0-9]+$ ]]; then
  die "ADB_SERVER must be host:port, for example 127.0.0.1:5037 (got '${ADB_SERVER_ARG}')."
fi
if [[ "$CHECK_ARGS" == 1 ]]; then
  exit 0
fi
# Device probe does not compile. With no ADB_SERVER the emulator is booted
# after the build, so there is nothing to check yet.
if [[ "$CHECK_DEVICE" == 1 && -z "$ADB_SERVER_ARG" ]]; then
  exit 0
fi
# --check-device only queries adb. It must run on the Mac before Docker
# starts, so it cannot require Linux or a built test tree.
if [[ "$CHECK_DEVICE" != 1 ]]; then
  require_linux
  require_cmd python3
  require_cmd vpython3

  # Generated wrappers are `#!/usr/bin/env vpython3` and probe upward for
  # .vpython3. out/ is a sibling of src/, so point vpython at the spec.
  vpython_spec="${WEBRTC_SRC:-$(cd "${PIPELINE_DIR}/.." && pwd)}/.vpython3"
  [[ -f "$vpython_spec" ]] || die "missing vpython spec: ${vpython_spec}"

  case "$ARCH_ARG" in
    x64)
      IMAGE="system-images;android-34;google_apis;x86_64"
      IMAGE_DIR_ABI="x86_64"
      ;;
    arm64)
      IMAGE="system-images;android-34;google_apis;arm64-v8a"
      IMAGE_DIR_ABI="arm64-v8a"
      ;;
  esac
  AVD_NAME="webrtc-test-${ARCH_ARG}"

  [[ -n "$BUILD_DIR" && -n "$TARGETS" ]] || die "run-android-tests.sh requires --build-dir and --targets"

  webrtc_src="${WEBRTC_SRC:-$(cd "${PIPELINE_DIR}/.." && pwd)}"
  webrtc_sdk="${webrtc_src}/third_party/android_sdk/public"
  [[ -d "$webrtc_sdk" ]] || die "Android SDK missing at ${webrtc_sdk} (make deps with an android target_os)"
fi

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
  echo "installing ${IMAGE} into ${webrtc_sdk} (kept on the host; the next run reuses it)"
  yes | "$sdkmanager" --sdk_root="$webrtc_sdk" --licenses >/dev/null || true
  "$sdkmanager" --sdk_root="$webrtc_sdk" \
    "cmdline-tools;latest" "platform-tools" "emulator" "$IMAGE"
}

arch_for_abi() {
  case "$1" in
    arm64-v8a) printf 'arm64\n' ;;
    x86_64) printf 'x64\n' ;;
    *) printf '\n' ;;
  esac
}

use_host_adb_server() {
  local host="${ADB_SERVER_ARG%:*}"
  local port="${ADB_SERVER_ARG##*:}"
  export ADB_SERVER_SOCKET="tcp:${host}:${port}"
  unset ANDROID_ADB_SERVER_PORT || true
  command -v adb >/dev/null 2>&1 || die "adb is not in ${webrtc_sdk}/platform-tools. Run make deps with TARGET_OS=android,unix so the Linux adb client is on the host tree."

  local listing
  listing="$(adb devices 2>&1 || true)"
  if grep -Eq 'failed to connect|cannot connect|Connection refused|No such file' <<<"$listing"; then
    cat >&2 <<EOF
error: cannot reach adb server at ${ADB_SERVER_ARG} from this environment ($(uname -s)).
${listing}
A server started as plain adb listens only on 127.0.0.1, so a container cannot use the host's localhost.
Restart it so it listens beyond localhost, then rerun the same command:
  adb -a -P ${port} nodaemon server
  make test android ARCH=${ARCH_ARG} ADB_SERVER=${ADB_SERVER_ARG}
EOF
    exit 1
  fi

  local serials=()
  while IFS= read -r serial; do
    [[ -n "$serial" ]] && serials+=("$serial")
  done < <(printf '%s\n' "$listing" | awk 'NR>1 && $2=="device" { print $1 }')

  if [[ "${#serials[@]}" -eq 0 ]]; then
    cat >&2 <<EOF
error: adb server ${ADB_SERVER_ARG} has no device in state device.
${listing}
Start one emulator on that server and rerun:
  make test android ARCH=${ARCH_ARG} ADB_SERVER=${ADB_SERVER_ARG}
Omit ADB_SERVER to boot an emulator in this environment instead.
EOF
    exit 1
  fi
  # Prefer the first emulator-* whose ABI matches ARCH. A phone or other
  # device is used only when no emulator matches, so extra devices can stay
  # attached to the same adb server.
  local serial abi want
  local -a emu_serial=() emu_abi=() other_serial=() other_abi=() seen=()
  for serial in "${serials[@]}"; do
    abi="$(adb -s "$serial" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')"
    seen+=("${serial} ${abi:-unknown}")
    want="$(arch_for_abi "$abi")"
    [[ "$want" == "$ARCH_ARG" ]] || continue
    if [[ "$serial" == emulator-* ]]; then
      emu_serial+=("$serial")
      emu_abi+=("$abi")
    else
      other_serial+=("$serial")
      other_abi+=("$abi")
    fi
  done
  if [[ "${#emu_serial[@]}" -gt 0 ]]; then
    serial="${emu_serial[0]}"
    abi="${emu_abi[0]}"
  elif [[ "${#other_serial[@]}" -gt 0 ]]; then
    serial="${other_serial[0]}"
    abi="${other_abi[0]}"
  else
    cat >&2 <<EOF
error: adb server ${ADB_SERVER_ARG} has no ${ARCH_ARG} device.
$(printf '  %s\n' "${seen[@]}")
ARCH=arm64 needs arm64-v8a. ARCH=x64 needs x86_64.
Rerun: make test android ARCH=${ARCH_ARG} ADB_SERVER=${ADB_SERVER_ARG}
EOF
    exit 1
  fi
  export ANDROID_SERIAL="$serial"
  echo "using ${serial} (${abi}) on adb server ${ADB_SERVER_ARG}"
}

boot_local_emulator() {
  unset ADB_SERVER_SOCKET || true
  unset ANDROID_ADB_SERVER_PORT || true
  unset ANDROID_ADB_SERVER_ADDRESS || true
  unset ANDROID_SERIAL || true

  local emulator_bin image_dir accel wait_iters
  emulator_bin="${webrtc_sdk}/emulator/emulator"
  image_dir="${webrtc_sdk}/system-images/android-34/google_apis/${IMAGE_DIR_ABI}"
  if [[ ! -x "$emulator_bin" || ! -d "$image_dir" ]]; then
    install_emulator
  fi
  [[ -x "$emulator_bin" && -d "$image_dir" ]] || die "emulator or ${IMAGE} still missing under ${webrtc_sdk}. sdkmanager writes that tree on the host; rerun make test android ARCH=${ARCH_ARG}."
  command -v adb >/dev/null 2>&1 || die "adb missing after emulator install under ${webrtc_sdk}/platform-tools"

  if [[ -c /dev/kvm && ! -w /dev/kvm ]]; then
    sudo chmod 666 /dev/kvm || die "/dev/kvm exists but is not writable, so the emulator cannot use hardware acceleration."
  fi
  if [[ -w /dev/kvm ]]; then
    accel="on"
    wait_iters=150
  else
    accel="off"
    wait_iters=450
    echo "No /dev/kvm in this environment. Starting the emulator with -accel off (software CPU). Boot is much slower than Linux CI."
  fi

  local avdmanager
  avdmanager="$(find_sdk_bin avdmanager "$webrtc_sdk" "${RUNNER_SDK_ROOTS[@]+"${RUNNER_SDK_ROOTS[@]}"}" || true)"
  [[ -n "$avdmanager" ]] || die "avdmanager not found under ${webrtc_sdk}. cmdline-tools are installed with the system image; rerun make deps with TARGET_OS=android,unix."

  export ANDROID_AVD_HOME="${BUILD_DIR}/avd"
  export ANDROID_EMULATOR_HOME="${BUILD_DIR}/emulator-home"
  mkdir -p "$ANDROID_AVD_HOME" "$ANDROID_EMULATOR_HOME"
  "$avdmanager" create avd --force -n "$AVD_NAME" -k "$IMAGE" >/dev/null <<EOF
no
EOF

  echo "starting emulator ${AVD_NAME} (-accel ${accel})"
  "$emulator_bin" -avd "$AVD_NAME" -no-window -no-audio -no-boot-anim \
    -gpu swiftshader_indirect -no-snapshot -accel "$accel" \
    >"${BUILD_DIR}/emulator.log" 2>&1 &
  EMU_PID=$!

  adb wait-for-device &
  local wait_pid=$! _ boot
  for _ in $(seq 1 "$wait_iters"); do
    if ! kill -0 "$EMU_PID" 2>/dev/null; then
      kill "$wait_pid" 2>/dev/null || true
      wait "$wait_pid" 2>/dev/null || true
      die "emulator exited early (-accel ${accel}); see ${BUILD_DIR}/emulator.log"
    fi
    if ! kill -0 "$wait_pid" 2>/dev/null; then
      break
    fi
    sleep 2
  done
  if kill -0 "$wait_pid" 2>/dev/null; then
    kill "$wait_pid" 2>/dev/null || true
    wait "$wait_pid" 2>/dev/null || true
    die "emulator did not open an adb port within $((wait_iters * 2))s (-accel ${accel}); see ${BUILD_DIR}/emulator.log"
  fi
  for _ in $(seq 1 "$wait_iters"); do
    boot="$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    if [[ "$boot" == "1" ]]; then
      echo "emulator booted"
      return 0
    fi
    if ! kill -0 "$EMU_PID" 2>/dev/null; then
      die "emulator exited early (-accel ${accel}); see ${BUILD_DIR}/emulator.log"
    fi
    sleep 2
  done
  die "emulator did not finish booting within $((wait_iters * 2))s (-accel ${accel}); see ${BUILD_DIR}/emulator.log"
}

ensure_device() {
  export ANDROID_SDK_ROOT="$webrtc_sdk"
  export ANDROID_HOME="$webrtc_sdk"
  export PATH="${webrtc_sdk}/platform-tools:${PATH}"

  if [[ -n "$ADB_SERVER_ARG" ]]; then
    use_host_adb_server
    return 0
  fi
  unset ADB_SERVER_SOCKET || true
  unset ANDROID_ADB_SERVER_PORT || true
  unset ANDROID_ADB_SERVER_ADDRESS || true
  if device_ready; then
    echo "using connected adb device"
    return 0
  fi
  boot_local_emulator
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

if [[ "$CHECK_DEVICE" == 1 ]]; then
  webrtc_src="${WEBRTC_SRC:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
  webrtc_sdk="${webrtc_src}/third_party/android_sdk/public"
  if [[ -x "${webrtc_sdk}/platform-tools/adb" ]] \
    && "${webrtc_sdk}/platform-tools/adb" version >/dev/null 2>&1; then
    export PATH="${webrtc_sdk}/platform-tools:${PATH}"
  fi
  use_host_adb_server
  exit 0
fi

ensure_device
# shellcheck disable=SC2086
for target in $TARGETS; do
  run_target "$target"
done
