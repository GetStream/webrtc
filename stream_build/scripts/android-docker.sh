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

short_hash() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1,1,12)}'
  else
    printf '%s' "$1" | sha256sum | awk '{print substr($1,1,12)}'
  fi
}

host_checkout() {
  if [[ -n "${WEBRTC_SRC:-}" ]]; then
    printf '%s\n' "$WEBRTC_SRC"
    return
  fi
  (cd "${SCRIPT_DIR}/../.." && pwd)
}

sysroot_volume_name() {
  printf 'stream-webrtc-sysroot-%s\n' "$(short_hash "$1")"
}

container_name_for() {
  local host_src="$1"
  local sysroot="$2"
  local uid="$3"
  printf 'stream-webrtc-android-%s\n' \
    "$(short_hash "${host_src}|${sysroot}|${uid}|layout-v3")"
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    die "Android builds on $(uname -s) run in Docker so the Linux toolchain can run. Install Docker Desktop, start it, and rerun the same make command."
  fi
  if ! docker info >/dev/null 2>&1; then
    die "Docker is installed but the daemon is not running. Start Docker Desktop and rerun the same make command."
  fi
}

ensure_image() {
  local tag="$1"
  local stamp="${WEBRTC_SRC}/.android-gclient/.android-docker-image-stamp"
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

# gclient requires the checkout to be a real directory named src whose parent
# is named webrtc. A worktree keeps its own folder name. Inside the container
# the worktree is mounted at this path, so the host directory does not move.
CONTAINER_ROOT="/webrtc"

launch_container() {
  local mount_sysroots="$1"
  local image_id container_image mounts
  image_id="$(docker image inspect -f '{{.Id}}' "$tag")"
  if docker container inspect "$name" >/dev/null 2>&1; then
    container_image="$(docker inspect -f '{{.Image}}' "$name")"
    mounts="$(docker inspect -f '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}' "$name")"
    if [[ "$container_image" != "$image_id" ]] \
      || grep -qx "${container_src}/build/linux" <<<"$mounts" \
      || { [[ "$mount_sysroots" == 1 ]] && ! grep -q 'debian_bullseye_amd64-sysroot' <<<"$mounts"; } \
      || { [[ "$mount_sysroots" == 0 ]] && grep -q 'debian_bullseye_amd64-sysroot' <<<"$mounts"; }; then
      docker rm -f "$name" >/dev/null
    fi
  fi
  if docker container inspect "$name" >/dev/null 2>&1; then
    if [[ "$(docker inspect -f '{{.State.Running}}' "$name")" != "true" ]]; then
      docker start "$name" >/dev/null
    fi
    return 0
  fi

  local -a run=(docker run -d --name "$name" --platform linux/amd64 --init
    --label "stream.webrtc.checkout=${host_src}"
    --label "stream.webrtc.git_common=${git_common}"
    --user "${uid}:${gid}"
    --add-host host.docker.internal:host-gateway
    -v "${state}:${CONTAINER_ROOT}"
    -v "${host_src}:${container_src}"
    -v "${host_src}/out:${container_out}"
    -v "${host_src}/products:${container_products}"
    -v "${host_src}:${host_src}"
    -e "DEPS_ROOT=${CONTAINER_ROOT}"
    -e "WEBRTC_SRC=${container_src}"
    -e "OUT=${container_out}")
  if [[ "$mount_sysroots" == 1 ]]; then
    local arch vol dest
    for arch in amd64 i386; do
      vol="${sysroot_volume}-${arch}"
      dest="${container_src}/build/linux/debian_bullseye_${arch}-sysroot"
      if ! docker volume inspect "$vol" >/dev/null 2>&1; then
        docker volume create \
          --label "stream.webrtc.checkout=${host_src}" \
          --label "stream.webrtc.git_common=${git_common}" \
          "$vol" >/dev/null
      fi
      run+=(-v "${vol}:${dest}")
    done
  fi
  if ! path_is_under "$git_dir" "$host_src"; then
    run+=(-v "${git_dir}:${git_dir}")
  fi
  if [[ "$git_common" != "$git_dir" ]] && ! path_is_under "$git_common" "$host_src"; then
    run+=(-v "${git_common}:${git_common}")
  fi
  if [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK}" ]]; then
    run+=(-v "${SSH_AUTH_SOCK}:${SSH_AUTH_SOCK}" -e "SSH_AUTH_SOCK=${SSH_AUTH_SOCK}")
  fi
  run+=("$tag" sleep infinity)
  "${run[@]}" >/dev/null
}

main() {
  local goal="${1:-}"
  local platform="${2:-}"
  [[ "$goal" == build || "$goal" == test || "$goal" == package ]] || die "android-docker.sh: expected build|test|package, got '${goal}'"
  [[ "$platform" == android ]] || die "android-docker.sh: expected android, got '${platform}'"
  if [[ -z "${WEBRTC_SRC:-}" ]]; then
    WEBRTC_SRC="$(cd "${SCRIPT_DIR}/../.." && pwd)"
  fi
  [[ -f "${WEBRTC_SRC}/DEPS" ]] || die "No WebRTC checkout at ${WEBRTC_SRC} (missing DEPS)"

  require_docker

  local host_src="$WEBRTC_SRC"
  local state="${host_src}/.android-gclient"
  local container_src="${CONTAINER_ROOT}/src"
  local container_out="${CONTAINER_ROOT}/out"
  local container_products="${CONTAINER_ROOT}/products"
  local git_dir git_common
  git_dir="$(absolute_git_path --git-dir)"
  git_common="$(absolute_git_path --git-common-dir)"

  # src/build/linux is part of the Chromium build checkout. The case-sensitive
  # archive is only the extracted debian_*_sysroot directories, mounted later.
  local sysroot_volume=""
  if ! filesystem_is_case_sensitive "$host_src"; then
    sysroot_volume="$(sysroot_volume_name "$host_src")"
  fi

  mkdir -p \
    "$state" \
    "${state}/.depot_tools" \
    "${state}/.cipd-cache" \
    "${state}/.vpython" \
    "${state}/.android-docker-home" \
    "${state}/.gclient-git-cache" \
    "${host_src}/out" \
    "${host_src}/products"
  write_gclient "$state" "${WEBRTC_REPO:-git@github.com:GetStream/webrtc.git}" "android,unix"
  # A previous run mounted a disk on build/linux and git could not check out
  # that directory. Drop the incomplete checkout so sync can clone it.
  if [[ -d "${host_src}/build/.git" && ! -f "${host_src}/build/linux/sysroot_scripts/install-sysroot.py" ]]; then
    echo "removing incomplete src/build left by a failed sync"
    rm -rf "${host_src}/build" "${state}/_bad_scm"
  fi

  local uid gid tag
  uid="$(id -u)"
  gid="$(id -g)"
  tag="${IMAGE_NAME}:u${uid}"
  ensure_image "$tag"

  local name
  name="$(container_name_for "$host_src" "$sysroot_volume" "$uid")"

  launch_container 0
  if [[ -n "$sysroot_volume" && ! -f "${host_src}/build/linux/sysroot_scripts/install-sysroot.py" ]]; then
    echo "fetching src/build before mounting the Debian sysroot"
    docker exec --user "${uid}:${gid}" \
      -e "DEPS_ROOT=${CONTAINER_ROOT}" \
      -e "WEBRTC_SRC=${container_src}" \
      -e "GIT_CACHE_PATH=${CONTAINER_ROOT}/.gclient-git-cache" \
      "$name" \
      "${container_src}/stream_build/scripts/android-docker-entry.sh" \
      sync-nohooks
    docker rm -f "$name" >/dev/null
    launch_container 1
  elif [[ -n "$sysroot_volume" ]]; then
    local mounts
    mounts="$(docker inspect -f '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}' "$name")"
    if ! grep -q 'debian_bullseye_amd64-sysroot' <<<"$mounts"; then
      docker rm -f "$name" >/dev/null
      launch_container 1
    fi
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
    -e "DEPS_ROOT=${CONTAINER_ROOT}"
    -e "WEBRTC_SRC=${container_src}"
    -e "OUT=${container_out}"
    -e "PRODUCTS=${container_products}"
    -e "GIT_CACHE_PATH=${CONTAINER_ROOT}/.gclient-git-cache"
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
    "${container_src}/stream_build/scripts/android-docker-entry.sh"
    "$goal" "$platform")
  echo "android: linux via docker (${tag}), sources on ${host_src}"
  exec "${exec_cmd[@]}"
}

cmd_cleanup() {
  if [[ -z "${WEBRTC_SRC:-}" ]]; then
    WEBRTC_SRC="$(host_checkout)"
  fi
  [[ -f "${WEBRTC_SRC}/DEPS" ]] || die "No WebRTC checkout at ${WEBRTC_SRC} (missing DEPS)"
  require_docker

  local host_src git_common sysroot name uid removed
  host_src="$WEBRTC_SRC"
  git_common="$(absolute_git_path --git-common-dir)"
  sysroot="$(sysroot_volume_name "$host_src")"
  uid="$(id -u)"
  name="$(container_name_for "$host_src" "$sysroot" "$uid")"
  removed=0

  local id
  if docker container inspect "$name" >/dev/null 2>&1; then
    docker rm -f "$name" >/dev/null
    echo "removed container ${name}"
    removed=1
  fi
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    local cname
    cname="$(docker inspect -f '{{.Name}}' "$id")"
    cname="${cname#/}"
    [[ "$cname" == "$name" ]] && continue
    docker rm -f "$id" >/dev/null
    echo "removed container ${cname}"
    removed=1
  done < <(docker ps -aq --filter "label=stream.webrtc.git_common=${git_common}")

  local vol
  for vol in "$sysroot" "${sysroot}-amd64" "${sysroot}-i386"; do
    if docker volume inspect "$vol" >/dev/null 2>&1; then
      docker volume rm "$vol" >/dev/null
      echo "removed sysroot ${vol}"
      removed=1
    fi
  done
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    [[ "$id" == "$sysroot" ]] && continue
    docker volume rm "$id" >/dev/null
    echo "removed sysroot ${id}"
    removed=1
  done < <(docker volume ls -q --filter "label=stream.webrtc.git_common=${git_common}")

  if [[ "$removed" -eq 0 ]]; then
    echo "no Android containers or sysroot disks for ${git_common}"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "${1:-}" == cleanup ]]; then
    cmd_cleanup
  else
    main "$@"
  fi
fi
