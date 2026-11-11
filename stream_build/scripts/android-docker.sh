#!/usr/bin/env bash
# Re-exec an Android make goal inside a Linux amd64 container.
# Sources, deps, out, and products stay on the host via bind mounts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

IMAGE_NAME="stream-webrtc-android"
DOCKERFILE="${SCRIPT_DIR}/../docker/android/Dockerfile"

# Loopback on the Mac is not loopback inside the container. Docker Desktop
# publishes the host as host.docker.internal.
rewrite_adb_server_for_container() {
  local spec="$1"
  local host="${spec%:*}"
  local port="${spec##*:}"
  case "$host" in
    127.0.0.1|localhost|::1) host="host.docker.internal" ;;
  esac
  printf '%s:%s\n' "$host" "$port"
}

filesystem_is_case_sensitive() {
  local dir="$1"
  local lower="${dir}/.android-case-a"
  local upper="${dir}/.android-case-A"
  local value
  rm -f "$lower" "$upper"
  echo 1 >"$lower"
  echo 2 >"$upper"
  value="$(cat "$lower")"
  rm -f "$lower" "$upper"
  [[ "$value" == "1" ]]
}

absolute_git_path() {
  local flag="$1"
  local path
  path="$(git -C "$WEBRTC_SRC" rev-parse --path-format=absolute "$flag" 2>/dev/null || true)"
  if [[ -n "$path" ]]; then
    printf '%s\n' "$path"
    return
  fi
  path="$(git -C "$WEBRTC_SRC" rev-parse "$flag")"
  if [[ "$path" != /* ]]; then
    path="$(cd "${WEBRTC_SRC}/$(dirname "$path")" && pwd)/$(basename "$path")"
  fi
  printf '%s\n' "$path"
}

path_is_under() {
  local path="$1"
  local root="$2"
  [[ "$path" == "$root" || "$path" == "$root"/* ]]
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    die "Android builds on $(uname -s) run in Docker so the Linux toolchain can run. Install Docker Desktop, start it, and rerun the same make command."
  fi
  if ! docker info >/dev/null 2>&1; then
    die "Docker is installed but the daemon is not running. Start Docker Desktop and rerun the same make command."
  fi
}

prepare_case_volume() {
  local volume="$1"
  [[ -d "$volume" ]] || die "ANDROID_CASE_VOLUME=${volume} does not exist. Create a case-sensitive volume and rerun."
  if ! filesystem_is_case_sensitive "$volume"; then
    die "ANDROID_CASE_VOLUME=${volume} is case-insensitive. Android's Debian sysroot needs a case-sensitive volume."
  fi
  local name
  for name in build third_party buildtools tools testing src-out out; do
    mkdir -p "${volume}/${name}"
  done
}

case_volume_mounts() {
  local volume="$1"
  printf '%s\n' \
    "${volume}/build:${WEBRTC_SRC}/build" \
    "${volume}/third_party:${WEBRTC_SRC}/third_party" \
    "${volume}/buildtools:${WEBRTC_SRC}/buildtools" \
    "${volume}/tools:${WEBRTC_SRC}/tools" \
    "${volume}/testing:${WEBRTC_SRC}/testing" \
    "${volume}/src-out:${WEBRTC_SRC}/out" \
    "${volume}/out:${OUT}"
}

ensure_image() {
  local tag="$1"
  local stamp="${DEPS_ROOT}/.android-docker-image-stamp"
  if docker image inspect "$tag" >/dev/null 2>&1 \
    && [[ -f "$stamp" && "$stamp" -nt "$DOCKERFILE" ]]; then
    return 0
  fi
  echo "building ${tag} from ${DOCKERFILE}"
  docker build --platform linux/amd64 \
    --build-arg "UID=$(id -u)" \
    --build-arg "GID=$(id -g)" \
    -t "$tag" \
    -f "$DOCKERFILE" \
    "$(dirname "$DOCKERFILE")"
  touch "$stamp"
}

main() {
  local goal="${1:-}"
  local platform="${2:-}"
  [[ "$goal" == build || "$goal" == test || "$goal" == package ]] || die "android-docker.sh: expected build|test|package, got '${goal}'"
  [[ "$platform" == android ]] || die "android-docker.sh: expected android, got '${platform}'"
  [[ -n "${DEPS_ROOT:-}" && -n "${WEBRTC_SRC:-}" && -n "${OUT:-}" ]] || die "DEPS_ROOT, WEBRTC_SRC, and OUT are required"

  require_docker

  if filesystem_is_case_sensitive "$DEPS_ROOT"; then
    :
  elif [[ -z "${ANDROID_CASE_VOLUME:-}" ]]; then
    cat >&2 <<EOF
error: ${DEPS_ROOT} is on a case-insensitive filesystem.
gclient extracts a Debian sysroot under src/build/linux, and that tree contains paths that differ only by case, so the sync cannot be stored here.
Create a case-sensitive volume and pass it as ANDROID_CASE_VOLUME. gclient trees and out/ go there (still on this machine). products/ stays in ${PRODUCTS:-${DEPS_ROOT}/products}.
EOF
    exit 1
  else
    prepare_case_volume "$ANDROID_CASE_VOLUME"
  fi

  local git_dir git_common
  git_dir="$(absolute_git_path --git-dir)"
  git_common="$(absolute_git_path --git-common-dir)"

  mkdir -p \
    "${DEPS_ROOT}/.depot_tools" \
    "${DEPS_ROOT}/.cipd-cache" \
    "${DEPS_ROOT}/.vpython" \
    "${DEPS_ROOT}/.android-docker-home" \
    "${DEPS_ROOT}/.gclient-git-cache" \
    "$OUT" \
    "${WEBRTC_SRC}/out"

  local uid gid tag
  uid="$(id -u)"
  gid="$(id -g)"
  tag="${IMAGE_NAME}:u${uid}"
  ensure_image "$tag"

  local material name
  material="${DEPS_ROOT}|${ANDROID_CASE_VOLUME:-}|${uid}"
  if command -v shasum >/dev/null 2>&1; then
    name="stream-webrtc-android-$(printf '%s' "$material" | shasum -a 256 | awk '{print substr($1,1,12)}')"
  else
    name="stream-webrtc-android-$(printf '%s' "$material" | sha256sum | awk '{print substr($1,1,12)}')"
  fi

  local image_id container_image
  image_id="$(docker image inspect -f '{{.Id}}' "$tag")"
  container_image="$(docker container inspect -f '{{.Image}}' "$name" 2>/dev/null || true)"
  if [[ -n "$container_image" && "$container_image" != "$image_id" ]]; then
    docker rm -f "$name" >/dev/null
    container_image=""
  fi

  if [[ -z "$container_image" ]]; then
    local -a run=(docker run -d --name "$name" --platform linux/amd64 --init
      --user "${uid}:${gid}"
      --add-host host.docker.internal:host-gateway
      -v "${DEPS_ROOT}:${DEPS_ROOT}"
      -e "DEPS_ROOT=${DEPS_ROOT}"
      -e "WEBRTC_SRC=${WEBRTC_SRC}"
      -e "OUT=${OUT}")
    if [[ -n "${ANDROID_CASE_VOLUME:-}" ]] && ! filesystem_is_case_sensitive "$DEPS_ROOT"; then
      local mount
      while IFS= read -r mount; do
        run+=(-v "$mount")
      done < <(case_volume_mounts "$ANDROID_CASE_VOLUME")
    fi
    if ! path_is_under "$git_dir" "$DEPS_ROOT"; then
      run+=(-v "${git_dir}:${git_dir}")
    fi
    if [[ "$git_common" != "$git_dir" ]] && ! path_is_under "$git_common" "$DEPS_ROOT"; then
      run+=(-v "${git_common}:${git_common}")
    fi
    if [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK}" ]]; then
      run+=(-v "${SSH_AUTH_SOCK}:${SSH_AUTH_SOCK}" -e "SSH_AUTH_SOCK=${SSH_AUTH_SOCK}")
    fi
    run+=("$tag" sleep infinity)
    "${run[@]}" >/dev/null
  elif [[ "$(docker inspect -f '{{.State.Running}}' "$name")" != "true" ]]; then
    docker start "$name" >/dev/null
  fi

  local adb_server="${ADB_SERVER:-}"
  if [[ -n "$adb_server" ]]; then
    adb_server="$(rewrite_adb_server_for_container "$adb_server")"
  fi
  local target_os="${TARGET_OS:-}"
  case "$target_os" in
    *android*) ;;
    *) target_os="android,unix" ;;
  esac

  local -a exec_cmd=(docker exec
    --user "${uid}:${gid}"
    -e "DEPS_ROOT=${DEPS_ROOT}"
    -e "WEBRTC_SRC=${WEBRTC_SRC}"
    -e "OUT=${OUT}"
    -e "PRODUCTS=${PRODUCTS:-${DEPS_ROOT}/products}"
    -e "GIT_CACHE_PATH=${GIT_CACHE_PATH:-${DEPS_ROOT}/.gclient-git-cache}"
    -e "STREAM_ANDROID_IN_DOCKER=1"
    -e "TARGET_OS=${target_os}"
    -e "CONFIG=${CONFIG:-release}"
    -e "JOBS=${JOBS:-8}"
    -e "SHALLOW=${SHALLOW:-1}"
    -e "RUN_HOOKS=${RUN_HOOKS:-1}"
    -e "SKIP_DEPS=${SKIP_DEPS:-0}"
    -e "SKIP_LICENSES=${SKIP_LICENSES:-0}"
    -e "ARCH=${ARCH:-}"
    -e "ADB_SERVER=${adb_server}"
    -e "ARCHS=${ARCHS:-}"
    -e "ANDROID_NAMESPACE=${ANDROID_NAMESPACE:-org.webrtc}"
    -e "GN_ARGS=${GN_ARGS:-}"
    -e "EXTRA_GN_ARGS=${EXTRA_GN_ARGS:-}"
    -e "WEBRTC_REPO=${WEBRTC_REPO:-}"
    "$name"
    "${WEBRTC_SRC}/stream_build/scripts/android-docker-entry.sh"
    "$goal" "$platform")
  echo "android: linux via docker (${tag}), sources on ${DEPS_ROOT}"
  exec "${exec_cmd[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
