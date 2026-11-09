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
CHUNK_BYTES=$((512 * 1024 * 1024))
CHUNK_TYPE="application/vnd.getstream.webrtc.git-cache.chunk.v1"

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

# oras retries dial timeouts and 5xx responses only. A mid-body HTTP/2
# PROTOCOL_ERROR is not one of those, on pull or push. Start the transfer
# again. HTTP/1.1 avoids the stream reset. oras does not resume a partial
# blob, so each attempt begins at byte 0.
retry_oras() {
  local attempts=5
  local n=1
  local delay=20
  local status
  while true; do
    set +e
    GODEBUG=http2client=0 "$@"
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
      return 0
    fi
    if [[ "$n" -ge "$attempts" ]]; then
      echo "oras failed after ${attempts} attempts" >&2
      return "$status"
    fi
    echo "oras failed (attempt ${n}/${attempts}, exit ${status}); retrying in ${delay}s" >&2
    sleep "$delay"
    n=$((n + 1))
    if [[ "$delay" -lt 60 ]]; then
      delay=$((delay * 2))
    fi
  done
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
  local list="$work/layers.tsv"
  python3 - "$work/manifest" "$list" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1]))
with open(sys.argv[2], "w", encoding="utf-8") as out:
    for index, layer in enumerate(manifest.get("layers") or []):
        annotations = layer.get("annotations") or {}
        title = annotations.get("org.opencontainers.image.title") or f"layer-{index:05d}"
        out.write(
            f"{layer['digest']}\t{layer['size']}\t{layer.get('mediaType', '')}\t{title}\n"
        )
PY
  if [[ ! -s "$list" ]]; then
    echo "manifest has no layers" >&2
    return 2
  fi
  local blobdir="$work/blobs"
  mkdir -p "$blobdir"
  local digest size media title
  local max="${PULL_CONCURRENCY:-3}"
  local running=0
  local failfile="$work/fetch-fail"
  rm -f "$failfile"
  while IFS=$'\t' read -r digest size media title; do
    if [[ -e "$failfile" ]]; then
      break
    fi
    (
      echo "fetch ${title} (${size} bytes)"
      if ! retry_oras oras blob fetch "${CACHE_IMAGE}@${digest}" --output "${blobdir}/${title}"; then
        echo "blob download failed: ${title}" >&2
        touch "$failfile"
        exit 1
      fi
    ) &
    running=$((running + 1))
    if [[ "$running" -ge "$max" ]]; then
      wait -n || true
      running=$((running - 1))
    fi
  done <"$list"
  wait || true
  if [[ -e "$failfile" ]]; then
    echo "blob download failed" >&2
    return 2
  fi
  local first
  first="$(cut -f4 "$list" | head -n 1)"
  # The archive bytes stay on stdin. The program text must not be a heredoc,
  # or Python reads the script instead of the decompressed cache.
  report_extract() {
    python3 -u -c '
import sys
import time

label = sys.argv[1]
read = 0
last = time.time()
while True:
    buf = sys.stdin.buffer.read(8 * 1024 * 1024)
    if not buf:
        break
    sys.stdout.buffer.write(buf)
    sys.stdout.buffer.flush()
    read += len(buf)
    now = time.time()
    if now - last >= 15:
        print(f"{label} {read / (1024 ** 3):.1f} GiB", file=sys.stderr, flush=True)
        last = now
if read == 0:
    print(f"{label} read nothing", file=sys.stderr, flush=True)
    sys.exit(1)
print(f"{label} done {read / (1024 ** 3):.1f} GiB", file=sys.stderr, flush=True)
' "$1"
  }
  if [[ "$first" == chunk-* ]] || grep -q 'git-cache.chunk' "$list"; then
    local files=("$blobdir"/chunk-*)
    local total="${#files[@]}"
    local i=0
    echo "stitching ${total} blobs" >&2
    if ! {
      for f in "${files[@]}"; do
        i=$((i + 1))
        echo "stitch ${i}/${total} $(basename "$f")" >&2
        cat "$f"
      done | zstd -d -c | report_extract "extract" | tar -C "$root" -xf -
    }; then
      echo "extract failed" >&2
      return 2
    fi
  else
    echo "extracting ${first}" >&2
    if ! zstd -d -c "${blobdir}/${first}" | report_extract "extract" | tar -C "$root" -xf -; then
      echo "extract failed" >&2
      return 2
    fi
  fi
  if [[ -z "$(ls -A "${root}/.gclient-git-cache" 2>/dev/null || true)" ]]; then
    echo "extract produced an empty git cache" >&2
    return 2
  fi
  echo "restored git cache from ${CACHE_IMAGE}:${tag}"
  du -sh "${root}/.gclient-git-cache" || true
}

cmd_pull() {
  local root="${CACHE_ROOT:?CACHE_ROOT is required}"
  local requested="${CACHE_TAG:-latest}"
  local work err rc
  work="$(mktemp -d)"
  err="$work/err"
  # shellcheck disable=SC2064
  trap "rm -rf '${work}'" RETURN
  mkdir -p "${root}/.gclient-git-cache"
  set +e
  pull_tag "$root" "$requested" "$work" "$err"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    note_restored "$requested"
    return 0
  fi
  if [[ "$rc" -ne 1 || "$requested" != "latest" ]]; then
    if [[ "$rc" -eq 1 ]]; then
      echo "no ${CACHE_IMAGE}:${requested}; starting from an empty git cache"
      note_restored empty
      return 0
    fi
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
  # One blob is one long GET, which GHCR's signed CDN URL cuts off.
  # 512MiB chunks are separate blobs. A failed transfer retries that blob.
  split -b "$CHUNK_BYTES" -d -a 5 "$archive" "$work/chunk-"
  rm -f "$archive"
  echo "split cache into $(find "$work" -maxdepth 1 -name 'chunk-*' | wc -l | tr -d ' ') blobs"
  (
    cd "$work"
    printf '{}' > config.json
    retry_oras oras blob push "${CACHE_IMAGE}" config.json \
      --media-type application/vnd.oci.empty.v1+json \
      --descriptor > config.desc
    for chunk in chunk-*; do
      echo "push ${chunk}"
      retry_oras oras blob push "${CACHE_IMAGE}" "$chunk" \
        --media-type "$CHUNK_TYPE" \
        --descriptor > "${chunk}.desc"
    done
    python3 - "$tag" "$revision" "$IMAGE_SOURCE" "$ARTIFACT_TYPE" <<'PY'
import json
import pathlib
import sys

tag, revision, source, artifact_type = sys.argv[1:]
root = pathlib.Path(".")

def load_desc(path):
    text = path.read_text()
    return json.loads(text[text.find("{") : text.rfind("}") + 1])

config = load_desc(root / "config.desc")
layers = []
for desc_path in sorted(root.glob("chunk-*.desc")):
    name = desc_path.name[: -len(".desc")]
    desc = load_desc(desc_path)
    desc["annotations"] = {"org.opencontainers.image.title": name}
    layers.append(desc)
manifest = {
    "schemaVersion": 2,
    "mediaType": "application/vnd.oci.image.manifest.v1+json",
    "artifactType": artifact_type,
    "config": config,
    "layers": layers,
    "annotations": {
        "org.opencontainers.image.source": source,
        "org.opencontainers.image.revision": revision,
        "org.opencontainers.image.version": tag,
    },
}
(root / "manifest.json").write_text(json.dumps(manifest))
PY
    retry_oras oras manifest push "${CACHE_IMAGE}:${tag}" manifest.json
  )
  echo "pushed ${CACHE_IMAGE}:${tag}"
  if [[ "$update" == "true" ]]; then
    retry_oras oras tag "${CACHE_IMAGE}:${tag}" latest
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
