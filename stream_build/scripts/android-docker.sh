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
    "$(short_hash "${host_src}|${sysroot}|${uid}|layout-v4")"
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    die "Android builds on $(uname -s) run in Docker so the Linux toolchain can run. Install Docker Desktop, start it, and rerun the same make command."
  fi
  if ! docker info >/dev/null 2>&1; then
    die "Docker is installed but the daemon is not running. Start Docker Desktop and rerun the same make command."
  fi
}

# Colima registers Rosetta with binfmt's F flag, which pins the interpreter
# file descriptor. After the VM refreshes that mount the fd is stale and every
# new x86_64 exec returns ENOENT. Python reports that as "No such file or
# directory: 'git'" even though git is installed in the container.
refresh_colima_rosetta() {
  command -v colima >/dev/null 2>&1 || return 1
  colima ssh -- sudo sh -c 'if [ -f /proc/sys/fs/binfmt_misc/rosetta ]; then echo -1 > /proc/sys/fs/binfmt_misc/rosetta; fi; printf "%b\n" ":rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/mnt/lima-rosetta/rosetta:OCF" > /proc/sys/fs/binfmt_misc/register'
}

amd64_container_runs() {
  docker run --rm --platform linux/amd64 --entrypoint /bin/true debian:bookworm >/dev/null 2>&1
}

ensure_amd64_exec() {
  if amd64_container_runs; then
    return 0
  fi
  if refresh_colima_rosetta && amd64_container_runs; then
    echo "refreshed Colima Rosetta so x86_64 binaries can run again"
    return 0
  fi
  die "This Docker VM cannot run x86_64 binaries, so the Android build stops with 'No such file or directory: git' even though git is installed. On Colima, run: colima stop && colima start --vm-type vz --vz-rosetta Then rerun the same make command."
}

ensure_image() {
  local tag="$1"
  local stamp="${ANDROID_DOCKER_STATE:?}/.android-docker-image-stamp"
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
  local image_id container_image mounts
  image_id="$(docker image inspect -f '{{.Id}}' "$tag")"
  if docker container inspect "$name" >/dev/null 2>&1; then
    container_image="$(docker inspect -f '{{.Image}}' "$name")"
    mounts="$(docker inspect -f '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}' "$name")"
    # A mount anywhere under src/build stops gclient from replacing that
    # checkout. Drop containers left from that experiment.
    if [[ "$container_image" != "$image_id" ]] \
      || grep -q "${container_src}/build/" <<<"$mounts"; then
      docker rm -f "$name" >/dev/null
    fi
  fi
  if docker container inspect "$name" >/dev/null 2>&1; then
    if [[ "$(docker inspect -f '{{.State.Running}}' "$name")" != "true" ]]; then
      docker start "$name" >/dev/null
    fi
    return 0
  fi

  # One mount for the worktree and the gclient root. cipd still renames
  # across the checkout bind; android-docker-bin/cipd retargets ensure.
  local -a run=(docker run -d --name "$name" --platform linux/amd64 --init
    --privileged
    --label "stream.webrtc.checkout=${host_src}"
    --label "stream.webrtc.git_common=${git_common}"
    --user "${uid}:${gid}"
    --add-host host.docker.internal:host-gateway
    -v "${host_parent}:${host_parent}"
    -e "DEPS_ROOT=${state}"
    -e "WEBRTC_SRC=${container_src}"
    -e "OUT=${container_out}"
    -e "HOST_CHECKOUT=${host_src}")
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
  ensure_amd64_exec

  local host_src="$WEBRTC_SRC"
  local host_parent
  host_parent="$(dirname "$host_src")"
  # Sibling of the worktree, on the same filesystem, so cipd can rename
  # into the checkout. Not inside the worktree: binding the worktree onto
  # a directory inside itself loops.
  local state="${host_parent}/.android-gclient-$(short_hash "$host_src")"
  local container_src="${state}/src"
  local container_out="${container_src}/out"
  local container_products="${container_src}/products"
  ANDROID_DOCKER_STATE="$state"
  local git_dir git_common
  git_dir="$(absolute_git_path --git-dir)"
  git_common="$(absolute_git_path --git-common-dir)"

  mkdir -p \
    "$state" \
    "${state}/.cipd-cache" \
    "${state}/.vpython" \
    "${state}/.android-docker-home" \
    "${host_src}/out" \
    "${host_src}/products"
  # Reuse the cache and depot_tools already downloaded into this worktree.
  local previous="${host_src}/.android-gclient"
  if [[ -d "${previous}/.depot_tools" && ! -e "${state}/.depot_tools" ]]; then
    ln -s "${previous}/.depot_tools" "${state}/.depot_tools"
  else
    mkdir -p "${state}/.depot_tools"
  fi
  if [[ -d "${previous}/.gclient-git-cache" && ! -e "${state}/.gclient-git-cache" ]]; then
    ln -s "${previous}/.gclient-git-cache" "${state}/.gclient-git-cache"
  else
    mkdir -p "${state}/.gclient-git-cache"
  fi
  write_gclient "$state" "${WEBRTC_REPO:-git@github.com:GetStream/webrtc.git}" "android,unix"

  local uid gid tag
  uid="$(id -u)"
  gid="$(id -g)"
  tag="${IMAGE_NAME}:u${uid}"
  ensure_image "$tag"

  local name
  name="$(container_name_for "$host_src" "" "$uid")"
  # gclient deletes src/build when its HEAD does not resolve. A mount inside
  # that directory makes the delete fail with "Device or resource busy".
  if [[ -d "${host_src}/build/.git" ]] \
    && ! git -C "${host_src}/build" rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "removing src/build whose git HEAD does not resolve"
    docker rm -f "$name" >/dev/null 2>&1 || true
    local id
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      docker rm -f "$id" >/dev/null
    done < <(docker ps -aq --filter "label=stream.webrtc.git_common=${git_common}")
    rm -rf "${host_src}/build" "${state}/_bad_scm"
  fi

  launch_container

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
    -e "DEPS_ROOT=${state}"
    -e "WEBRTC_SRC=${container_src}"
    -e "OUT=${container_out}"
    -e "PRODUCTS=${container_products}"
    -e "GIT_CACHE_PATH=${state}/.gclient-git-cache"
    -e "HOST_CHECKOUT=${host_src}"
    -e "STREAM_ANDROID_IN_DOCKER=1"
    -e "GIT_CONFIG_COUNT=1"
    -e "GIT_CONFIG_KEY_0=core.filemode"
    -e "GIT_CONFIG_VALUE_0=false"
    -e "TARGET_OS=${target_os}"
    -e "CONFIG=${CONFIG:-release}"
    -e "JOBS=${JOBS:-8}"
    -e "SYNC_JOBS=${SYNC_JOBS:-4}"
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
    "${host_src}/stream_build/scripts/android-docker-entry.sh"
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
