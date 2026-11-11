#!/usr/bin/env bash
# Runs inside the Android build container. The source tree is the host's.
set -euo pipefail

[[ -n "${DEPS_ROOT:-}" && -n "${WEBRTC_SRC:-}" ]] || {
  echo "error: DEPS_ROOT and WEBRTC_SRC are required inside the Android container" >&2
  exit 1
}

export STREAM_ANDROID_IN_DOCKER=1
export DEPOT_TOOLS_UPDATE=0
export HOME="${DEPS_ROOT}/.android-docker-home"
export CIPD_CACHE_DIR="${DEPS_ROOT}/.cipd-cache"
export VPYTHON_VIRTUALENV_ROOT="${DEPS_ROOT}/.vpython"
# Sibling of DEPS_ROOT. gclient rejects a cache inside the gclient root.
export GIT_CACHE_PATH="${GIT_CACHE_PATH:-$(dirname "$DEPS_ROOT")/.android-git-cache/.gclient-git-cache}"
mkdir -p "$HOME" "$CIPD_CACHE_DIR" "$VPYTHON_VIRTUALENV_ROOT" "$GIT_CACHE_PATH"

if [[ ! -x "${DEPS_ROOT}/.depot_tools/gclient" ]]; then
  echo "cloning depot_tools into ${DEPS_ROOT}/.depot_tools"
  rm -rf "${DEPS_ROOT}/.depot_tools"
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git \
    "${DEPS_ROOT}/.depot_tools"
fi
export PATH="${DEPS_ROOT}/.depot_tools:${PATH}"

# virtiofs reports mode bits that do not match the index. A cloned repo
# stores core.filemode=true locally, which overrides the global value, so
# gclient refuses the dependency as dirty. These override every git config.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=core.filemode
export GIT_CONFIG_VALUE_0=false
git config --global --add safe.directory "${WEBRTC_SRC}" || true
git config --global --add safe.directory "${DEPS_ROOT}" || true
git config --global --add safe.directory "${HOST_CHECKOUT}" || true

# gclient requires a real directory named src inside the deps root. The
# worktree keeps its own name, so it is bind-mounted there. virtiofs still
# rejects rename across that bind; android-docker-bin/cipd avoids it.
if ! grep -qs " ${WEBRTC_SRC} " /proc/mounts; then
  mkdir -p "${WEBRTC_SRC}"
  sudo mount --bind "${HOST_CHECKOUT}" "${WEBRTC_SRC}"
fi

pipeline="${WEBRTC_SRC}/stream_build"
# Ahead of depot_tools so `cipd ensure` hits the same-mount wrapper.
export PATH="${pipeline}/scripts/android-docker-bin:${PATH}"
deps_script="${WEBRTC_SRC}/build/install-build-deps.sh"
# Stamp lives in the container, not on the host mount. A new container
# installs packages again; the same container does not.
stamp="/var/tmp/install-build-deps.stamp"
if [[ ! -x "$deps_script" ]]; then
  echo "fetching Android deps so install-build-deps.sh exists"
  make -C "$pipeline" deps TARGET_OS=android,unix
fi
if [[ ! -f "$stamp" || "$deps_script" -nt "$stamp" ]]; then
  echo "installing Chromium host packages (once per container)"
  sudo "$deps_script" --android --no-prompt --no-chromeos-fonts
  touch "$stamp"
fi

exec make -C "$pipeline" "$@"
