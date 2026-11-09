#!/usr/bin/env bash
# Publish the gclient git cache as an OCI artifact on GHCR.
# PRs do not run this. Update WebRTC Cache pulls :current, syncs on
# top, and pushes a new tag. The daily workflow calls that workflow.
# :current moves only when asked.
set -euo pipefail

CACHE_IMAGE="${CACHE_IMAGE:-ghcr.io/getstream/webrtc-cache}"
IMAGE_SOURCE="${IMAGE_SOURCE:-https://github.com/GetStream/webrtc}"
ARTIFACT_TYPE="application/vnd.getstream.webrtc.git-cache.v1"
ARCHIVE_NAME="gclient-git-cache.tar.zst"

usage() {
  cat <<'EOF'
usage: webrtc-cache.sh resolve-tag|pull|push

resolve-tag <input> <run_id> <run_attempt> [yyyymmdd]
  Print the tag to push. input "automatic" or empty becomes
  <yyyymmdd>-<run_id>.<run_attempt>. "current" is rejected.

pull
  Extract :current into $CACHE_ROOT/.gclient-git-cache.
  A missing :current leaves an empty cache. Other errors fail.

push
  Pack $CACHE_ROOT/.gclient-git-cache and push $CACHE_IMAGE:$CACHE_TAG.
  UPDATE_CURRENT=true also points :current at that tag.
  GIT_REVISION is stored on the manifest.
EOF
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

cmd_resolve_tag() {
  local input run_id run_attempt day
  input="$(trim "${1:-}")"
  run_id="${2:?run_id required}"
  run_attempt="${3:?run_attempt required}"
  day="${4:-}"
  if [[ -z "$input" || "$input" == "automatic" ]]; then
    if [[ -z "$day" ]]; then
      day="$(date -u +%Y%m%d)"
    fi
    if [[ ! "$day" =~ ^[0-9]{8}$ ]]; then
      echo "automatic tag date must be YYYYMMDD" >&2
      return 1
    fi
    if [[ ! "$run_id" =~ ^[0-9]+$ || ! "$run_attempt" =~ ^[0-9]+$ ]]; then
      echo "run_id and run_attempt must be numbers" >&2
      return 1
    fi
    printf '%s-%s.%s\n' "$day" "$run_id" "$run_attempt"
    return 0
  fi
  if [[ "$input" == "current" ]]; then
    echo "tag must not be current; set update_current to move that tag" >&2
    return 1
  fi
  if [[ ! "$input" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]]; then
    echo "invalid tag: ${input}" >&2
    return 1
  fi
  printf '%s\n' "$input"
}

missing_current() {
  local err="$1"
  grep -qiE 'not found|404|name unknown|manifest unknown|NAME_UNKNOWN|MANIFEST_UNKNOWN' "$err"
}

cmd_pull() {
  local root="${CACHE_ROOT:?CACHE_ROOT is required}"
  local work err
  work="$(mktemp -d)"
  err="$work/err"
  # shellcheck disable=SC2064
  trap "rm -rf '${work}'" RETURN
  mkdir -p "${root}/.gclient-git-cache"
  if ! oras manifest fetch "${CACHE_IMAGE}:current" >"$work/manifest" 2>"$err"; then
    if missing_current "$err"; then
      echo "no ${CACHE_IMAGE}:current; starting from an empty git cache"
      return 0
    fi
    echo "failed to read ${CACHE_IMAGE}:current" >&2
    cat "$err" >&2
    return 1
  fi
  oras pull "${CACHE_IMAGE}:current" --concurrency 4 -o "$work/blob"
  if [[ ! -f "$work/blob/${ARCHIVE_NAME}" ]]; then
    echo "pulled package has no ${ARCHIVE_NAME}" >&2
    return 1
  fi
  zstd -d -c "$work/blob/${ARCHIVE_NAME}" | tar -C "$root" -xf -
  if [[ ! -d "${root}/.gclient-git-cache" ]]; then
    echo "archive missing .gclient-git-cache" >&2
    return 1
  fi
  echo "restored git cache from ${CACHE_IMAGE}:current"
  du -sh "${root}/.gclient-git-cache" || true
}

cmd_push() {
  local root="${CACHE_ROOT:?CACHE_ROOT is required}"
  local tag="${CACHE_TAG:?CACHE_TAG is required}"
  local update="${UPDATE_CURRENT:?UPDATE_CURRENT is required}"
  local revision="${GIT_REVISION:?GIT_REVISION is required}"
  local cache="${root}/.gclient-git-cache"
  local work archive
  case "$update" in
    true|false) ;;
    *)
      echo "UPDATE_CURRENT must be true or false" >&2
      return 1
      ;;
  esac
  if [[ "$tag" == "current" ]]; then
    echo "tag must not be current; set update_current to move that tag" >&2
    return 1
  fi
  if [[ ! -d "$cache" ]] || [[ -z "$(ls -A "$cache")" ]]; then
    echo "git cache is missing or empty: ${cache}" >&2
    return 1
  fi
  work="$(mktemp -d)"
  archive="${work}/${ARCHIVE_NAME}"
  # shellcheck disable=SC2064
  trap "rm -rf '${work}'" RETURN
  echo "packing ${cache}"
  tar -C "$root" -cf - .gclient-git-cache | zstd -T0 -3 -o "$archive"
  du -sh "$archive" || true
  # oras rejects an absolute path. Push the archive by its basename.
  (
    cd "$work"
    oras push "${CACHE_IMAGE}:${tag}" \
      --artifact-type "$ARTIFACT_TYPE" \
      --annotation "org.opencontainers.image.source=${IMAGE_SOURCE}" \
      --annotation "org.opencontainers.image.revision=${revision}" \
      --annotation "org.opencontainers.image.version=${tag}" \
      "${ARCHIVE_NAME}:application/zstd"
  )
  echo "pushed ${CACHE_IMAGE}:${tag}"
  if [[ "$update" == "true" ]]; then
    oras tag "${CACHE_IMAGE}:${tag}" current
    echo "moved ${CACHE_IMAGE}:current to ${tag}"
  else
    echo "left ${CACHE_IMAGE}:current unchanged"
  fi
}

case "${1:-}" in
  resolve-tag) shift; cmd_resolve_tag "$@" ;;
  pull) cmd_pull ;;
  push) cmd_push ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 1 ;;
esac
