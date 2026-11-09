#!/usr/bin/env bash
# Publish the gclient git cache as an OCI artifact on GHCR.
# PRs do not run this. Update WebRTC Cache pulls :latest, syncs on
# top, and pushes a new tag. The daily workflow calls that workflow.
# :latest moves only when asked. A missing :latest restores :current
# once, so the cache already published under that name is kept.
set -euo pipefail

CACHE_IMAGE="${CACHE_IMAGE:-ghcr.io/getstream/webrtc-cache}"
IMAGE_SOURCE="${IMAGE_SOURCE:-https://github.com/GetStream/webrtc}"
ARTIFACT_TYPE="application/vnd.getstream.webrtc.git-cache.v1"
ARCHIVE_NAME="gclient-git-cache.tar.zst"

usage() {
  cat <<'EOF'
usage: webrtc-cache.sh resolve-tag|pull|fingerprint|push

resolve-tag <input> <run_id> <run_attempt> [yyyymmdd]
  Print the tag to push. input "automatic" or empty becomes
  <yyyymmdd>-<run_id>.<run_attempt>. "latest" and "current" are rejected.

pull
  Extract :latest into $CACHE_ROOT/.gclient-git-cache.
  A missing :latest restores :current when that tag exists, otherwise
  leaves an empty cache. Other errors fail. Prints restored_from=.

fingerprint
  Print a sha256 of file sizes and paths in the git cache.

push
  Pack $CACHE_ROOT/.gclient-git-cache and push $CACHE_IMAGE:$CACHE_TAG.
  UPDATE_LATEST=true also points :latest at that tag.
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
  if [[ "$input" == "latest" || "$input" == "current" ]]; then
    echo "tag must not be latest; that name is the moving tag" >&2
    return 1
  fi
  if [[ ! "$input" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]]; then
    echo "invalid tag: ${input}" >&2
    return 1
  fi
  printf '%s\n' "$input"
}

missing_tag() {
  local err="$1"
  grep -qiE 'not found|404|name unknown|manifest unknown|NAME_UNKNOWN|MANIFEST_UNKNOWN' "$err"
}

note_restored() {
  local from="$1"
  echo "restored_from=${from}"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "restored_from=${from}" >> "$GITHUB_OUTPUT"
  fi
}

# 0 restored, 1 tag missing, 2 hard failure.
pull_tag() {
  local root="$1"
  local tag="$2"
  local work="$3"
  local err="$4"
  if ! oras manifest fetch "${CACHE_IMAGE}:${tag}" >"$work/manifest" 2>"$err"; then
    if missing_tag "$err"; then
      return 1
    fi
    echo "failed to read ${CACHE_IMAGE}:${tag}" >&2
    cat "$err" >&2
    return 2
  fi
  rm -rf "$work/blob"
  oras pull "${CACHE_IMAGE}:${tag}" --concurrency 4 -o "$work/blob"
  if [[ ! -f "$work/blob/${ARCHIVE_NAME}" ]]; then
    echo "pulled package has no ${ARCHIVE_NAME}" >&2
    return 2
  fi
  zstd -d -c "$work/blob/${ARCHIVE_NAME}" | tar -C "$root" -xf -
  if [[ ! -d "${root}/.gclient-git-cache" ]]; then
    echo "archive missing .gclient-git-cache" >&2
    return 2
  fi
  echo "restored git cache from ${CACHE_IMAGE}:${tag}"
  du -sh "${root}/.gclient-git-cache" || true
}

cmd_pull() {
  local root="${CACHE_ROOT:?CACHE_ROOT is required}"
  local work err rc
  work="$(mktemp -d)"
  err="$work/err"
  # shellcheck disable=SC2064
  trap "rm -rf '${work}'" RETURN
  mkdir -p "${root}/.gclient-git-cache"
  set +e
  pull_tag "$root" latest "$work" "$err"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    note_restored latest
    return 0
  fi
  if [[ "$rc" -ne 1 ]]; then
    return 1
  fi
  set +e
  pull_tag "$root" current "$work" "$err"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "no ${CACHE_IMAGE}:latest; restored ${CACHE_IMAGE}:current"
    note_restored current
    return 0
  fi
  if [[ "$rc" -ne 1 ]]; then
    return 1
  fi
  echo "no ${CACHE_IMAGE}:latest; starting from an empty git cache"
  note_restored empty
}

cmd_fingerprint() {
  local root="${CACHE_ROOT:?CACHE_ROOT is required}"
  local cache="${root}/.gclient-git-cache"
  mkdir -p "$cache"
  python3 - "$cache" <<'PY'
import hashlib
import os
import sys

root = sys.argv[1]
digest = hashlib.sha256()
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for name in sorted(filenames):
        path = os.path.join(dirpath, name)
        if not os.path.isfile(path) or os.path.islink(path):
            continue
        rel = os.path.relpath(path, root)
        digest.update(f"{os.path.getsize(path)} {rel}\n".encode())
sys.stdout.write(digest.hexdigest() + "\n")
PY
}

cmd_push() {
  local root="${CACHE_ROOT:?CACHE_ROOT is required}"
  local tag="${CACHE_TAG:?CACHE_TAG is required}"
  local update="${UPDATE_LATEST:?UPDATE_LATEST is required}"
  local revision="${GIT_REVISION:?GIT_REVISION is required}"
  local cache="${root}/.gclient-git-cache"
  local work archive
  case "$update" in
    true|false) ;;
    *)
      echo "UPDATE_LATEST must be true or false" >&2
      return 1
      ;;
  esac
  if [[ "$tag" == "latest" || "$tag" == "current" ]]; then
    echo "tag must not be latest; that name is the moving tag" >&2
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
    oras tag "${CACHE_IMAGE}:${tag}" latest
    echo "moved ${CACHE_IMAGE}:latest to ${tag}"
  else
    echo "left ${CACHE_IMAGE}:latest unchanged"
  fi
}

case "${1:-}" in
  resolve-tag) shift; cmd_resolve_tag "$@" ;;
  pull) cmd_pull ;;
  fingerprint) cmd_fingerprint ;;
  push) cmd_push ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 1 ;;
esac
