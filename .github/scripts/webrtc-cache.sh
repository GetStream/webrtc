#!/usr/bin/env bash
# Publish the gclient git cache as an OCI artifact on GHCR.
# PRs do not run this. Update WebRTC Cache pulls :latest, syncs on
# top, and pushes a new tag. The daily workflow calls that workflow.
# :latest moves only when asked. A missing :latest restores :current
# once, so the cache already published under that name is kept.
set -euo pipefail

CACHE_IMAGE="${CACHE_IMAGE:-ghcr.io/getstream/webrtc-cache}"
IMAGE_SOURCE="${IMAGE_SOURCE:-https://github.com/GetStream/webrtc}"
ARTIFACT_TYPE="${ARTIFACT_TYPE:-application/vnd.getstream.webrtc.git-cache.v1}"
ARCHIVE_NAME="gclient-git-cache.tar.zst"
CHUNK_BYTES=$((512 * 1024 * 1024))
CHUNK_TYPE="${CHUNK_TYPE:-application/vnd.getstream.webrtc.git-cache.chunk.v1}"

usage() {
  cat <<'EOF'
usage: webrtc-cache.sh resolve-tag|pull|fingerprint|list-members|members-for|build-members-for|build-image-for|tools-status|push

resolve-tag <input> <run_id> <run_attempt> [yyyymmdd]
  Print the tag to push. input "automatic" or empty becomes
  <yyyymmdd>-<run_id>.<run_attempt>. "latest" and "current" are rejected.

pull
  Extract :latest into $CACHE_ROOT/.gclient-git-cache.
  A missing :latest restores :current when that tag exists, otherwise
  leaves an empty cache. Other errors fail. Prints restored_from=.
  ARCHIVE_MEMBERS packs those paths under ARCHIVE_ROOT instead, and a
  missing tag leaves them absent. There is no :current fallback.

fingerprint
  Print a sha256 of file sizes and paths in the git cache.

list-members
  Print the relative paths push will pack. The git cache is
  .gclient-git-cache. ARCHIVE_MEMBERS skips a path that is missing
  or empty, and fails when every path is skipped. A member may be a
  relative glob, such as src/build/linux/*-sysroot.

members-for <ios|macos|android>
  Print the ARCHIVE_MEMBERS for that platform. ios and macos pack
  .cipd and src/resources. android also packs Debian sysroots under
  src/build/linux.

build-members-for <ios|macos|android> [production|test]
  Print the ARCHIVE_MEMBERS for that build. production is the default.
  production packs the slice directories. test packs the debug test
  output directory.

build-image-for <ios|macos|android> <debug|release> <production|test>
  Print the GHCR image. production is
  webrtc-build-cache-<configuration>-<platform>.
  test is webrtc-test-cache-<platform>.
  Test caches are debug only. release combined with test is rejected.

tools-status
  Print "missing" when any webrtc-tools-<platform>:latest is absent,
  otherwise "present". Other registry errors fail.

push
  Pack the list-members paths and push $CACHE_IMAGE:$CACHE_TAG.
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

note_revision() {
  local revision="$1"
  echo "restored_revision=${revision}"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "restored_revision=${revision}" >> "$GITHUB_OUTPUT"
  fi
}

archive_root() {
  if [[ -n "${ARCHIVE_MEMBERS:-}" ]]; then
    printf '%s\n' "${ARCHIVE_ROOT:?ARCHIVE_ROOT is required}"
    return 0
  fi
  printf '%s\n' "${CACHE_ROOT:?CACHE_ROOT is required}"
}

directory_has_files() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  [[ -n "$(ls -A "$dir" 2>/dev/null || true)" ]]
}

cmd_tools_status() {
  local platform image err
  for platform in ios macos android; do
    image="ghcr.io/getstream/webrtc-tools-${platform}"
    err="$(mktemp)"
    if oras manifest fetch "${image}:latest" >/dev/null 2>"$err"; then
      rm -f "$err"
      continue
    fi
    if missing_tag "$err"; then
      rm -f "$err"
      echo "missing ${image}:latest" >&2
      printf '%s\n' missing
      return 0
    fi
    echo "failed to read ${image}:latest" >&2
    cat "$err" >&2
    rm -f "$err"
    return 1
  done
  printf '%s\n' present
}

cmd_members_for() {
  case "${1:-}" in
    ios|macos)
      printf '%s\n' ".cipd src/resources"
      ;;
    android)
      # The sysroot is a Linux hook output. Hetzner left src/build unpacked,
      # so Android jobs downloaded it on every run.
      printf '%s\n' ".cipd src/resources src/build/linux/*-sysroot"
      ;;
    *)
      echo "platform must be ios, macos, or android" >&2
      return 1
      ;;
  esac
}

cmd_build_members_for() {
  local platform="${1:-}"
  local kind="${2:-production}"
  case "$kind" in
    production)
      case "$platform" in
        ios) printf '%s\n' "out/ios-* out/catalyst-*" ;;
        macos) printf '%s\n' "out/macos-*" ;;
        android) printf '%s\n' "out/android-*" ;;
        *)
          echo "platform must be ios, macos, or android" >&2
          return 1
          ;;
      esac
      ;;
    test)
      case "$platform" in
        ios) printf '%s\n' "out/ios_tests" ;;
        macos) printf '%s\n' "out/webrtc_tests" ;;
        android) printf '%s\n' "src/out/android_tests" ;;
        *)
          echo "platform must be ios, macos, or android" >&2
          return 1
          ;;
      esac
      ;;
    *)
      echo "kind must be production or test" >&2
      return 1
      ;;
  esac
}

cmd_build_image_for() {
  local platform="${1:-}"
  local configuration="${2:-}"
  local kind="${3:-}"
  case "$platform" in
    ios|macos|android) ;;
    *)
      echo "platform must be ios, macos, or android" >&2
      return 1
      ;;
  esac
  case "$configuration" in
    debug|release) ;;
    *)
      echo "configuration must be debug or release" >&2
      return 1
      ;;
  esac
  case "$kind" in
    production|test) ;;
    *)
      echo "kind must be production or test" >&2
      return 1
      ;;
  esac
  if [[ "$kind" == test && "$configuration" != debug ]]; then
    echo "test caches are debug only" >&2
    return 1
  fi
  if [[ "$kind" == test ]]; then
    printf '%s\n' "ghcr.io/getstream/webrtc-test-cache-${platform}"
    return 0
  fi
  printf '%s\n' "ghcr.io/getstream/webrtc-build-cache-${configuration}-${platform}"
}

# Prints one relative path per line. Git-cache mode requires the cache.
# ARCHIVE_MEMBERS skips an empty path and fails when nothing remains.
# A member that contains * or ? is a glob relative to the archive root.
cmd_list_members() {
  local root path found=0 match rel
  local -a requested matches
  root="$(archive_root)"
  if [[ -z "${ARCHIVE_MEMBERS:-}" ]]; then
    if ! directory_has_files "${root}/.gclient-git-cache"; then
      echo "git cache is missing or empty: ${root}/.gclient-git-cache" >&2
      return 1
    fi
    printf '%s\n' .gclient-git-cache
    return 0
  fi
  set -f
  # shellcheck disable=SC2206
  requested=(${ARCHIVE_MEMBERS})
  set +f
  shopt -s nullglob
  for path in "${requested[@]}"; do
    if [[ "$path" == *'*'* || "$path" == *'?'* ]]; then
      # shellcheck disable=SC2206
      matches=("${root}/"${path})
      if [[ ${#matches[@]} -eq 0 ]]; then
        echo "skip ${path} (missing or empty)" >&2
        continue
      fi
      for match in "${matches[@]}"; do
        rel="${match#"${root}/"}"
        if directory_has_files "$match"; then
          printf '%s\n' "$rel"
          found=1
        else
          echo "skip ${rel} (missing or empty)" >&2
        fi
      done
      continue
    fi
    if directory_has_files "${root}/${path}"; then
      printf '%s\n' "$path"
      found=1
    else
      echo "skip ${path} (missing or empty)" >&2
    fi
  done
  shopt -u nullglob
  if [[ "$found" -eq 0 ]]; then
    echo "no archive members to pack under ${root}" >&2
    return 1
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
  local revision
  revision="$(python3 - "$work/manifest" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1]))
annotations = manifest.get("annotations") or {}
sys.stdout.write(annotations.get("org.opencontainers.image.revision", ""))
PY
)"
  local blobdir="$work/blobs"
  mkdir -p "$blobdir"
  local failfile="$work/fetch-fail"
  rm -f "$failfile"
  # Extract as soon as chunk 0 is complete. Later chunks are read in order
  # and the pipe waits when the next file has not been renamed into place.
  (
    set -o pipefail
    total="$(wc -l < "$list" | tr -d ' ')"
    echo "stitching ${total} blobs" >&2
    i=0
    while IFS=$'\t' read -r _digest _size _media title; do
      i=$((i + 1))
      ready="${blobdir}/${title}"
      while [[ ! -f "$ready" ]]; do
        if [[ -e "$failfile" ]]; then
          echo "extract aborted; ${title} was not downloaded" >&2
          exit 1
        fi
        sleep 0.2
      done
      echo "stitch ${i}/${total} ${title}" >&2
      cat "$ready"
    done < "$list" | zstd -d -T0 -c -v | tar -C "$root" -xf -
  ) &
  local extract_pid=$!
  (
    set +e
    digest="" size="" media="" title=""
    max="${PULL_CONCURRENCY:-3}"
    running=0
    while IFS=$'\t' read -r digest size media title; do
      if [[ -e "$failfile" ]]; then
        break
      fi
      (
        echo "fetch ${title} (${size} bytes)"
        tmp="${blobdir}/${title}.partial"
        if ! retry_oras oras blob fetch "${CACHE_IMAGE}@${digest}" --output "$tmp"; then
          echo "blob download failed: ${title}" >&2
          touch "$failfile"
          rm -f "$tmp"
          exit 1
        fi
        mv "$tmp" "${blobdir}/${title}"
      ) &
      running=$((running + 1))
      if [[ "$running" -ge "$max" ]]; then
        wait -n || true
        running=$((running - 1))
      fi
    done <"$list"
    wait || true
    if [[ -e "$failfile" ]]; then
      exit 1
    fi
  ) &
  local download_pid=$!
  local download_rc=0 extract_rc=0
  set +e
  wait "$download_pid"
  download_rc=$?
  wait "$extract_pid"
  extract_rc=$?
  set -e
  if [[ "$download_rc" -ne 0 || "$extract_rc" -ne 0 || -e "$failfile" ]]; then
    echo "extract failed" >&2
    return 2
  fi
  if [[ -z "${ARCHIVE_MEMBERS:-}" ]]; then
    if ! directory_has_files "${root}/.gclient-git-cache"; then
      echo "extract produced an empty git cache" >&2
      return 2
    fi
    echo "restored git cache from ${CACHE_IMAGE}:${tag}"
    du -sh "${root}/.gclient-git-cache" || true
    note_revision "$revision"
    return 0
  fi
  local restored path
  if ! restored="$(cmd_list_members)"; then
    echo "extract produced no tools files" >&2
    return 2
  fi
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    echo "restored ${path} from ${CACHE_IMAGE}:${tag}"
    du -sh "${root}/${path}" || true
  done <<< "$restored"
  note_revision "$revision"
}

cmd_pull() {
  local root requested work err rc
  root="$(archive_root)"
  requested="${CACHE_TAG:-latest}"
  work="$(mktemp -d)"
  err="$work/err"
  # shellcheck disable=SC2064
  trap "rm -rf '${work}'" RETURN
  if [[ -z "${ARCHIVE_MEMBERS:-}" ]]; then
    mkdir -p "${root}/.gclient-git-cache"
  fi
  set +e
  pull_tag "$root" "$requested" "$work" "$err"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    note_restored "$requested"
    return 0
  fi
  if [[ "$rc" -ne 1 ]]; then
    return 1
  fi
  # The git cache kept one publish under :current. Tools packages do not.
  if [[ -z "${ARCHIVE_MEMBERS:-}" && "$requested" == latest ]]; then
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
  fi
  echo "no ${CACHE_IMAGE}:${requested}; starting from an empty git cache"
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
  local root tag update revision work members_text line
  root="$(archive_root)"
  tag="${CACHE_TAG:?CACHE_TAG is required}"
  update="${UPDATE_LATEST:?UPDATE_LATEST is required}"
  revision="${GIT_REVISION:?GIT_REVISION is required}"
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
  members_text="$(cmd_list_members)"
  local members=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    members+=("$line")
  done <<< "$members_text"
  work="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${work}'" RETURN
  echo "packing ${root}/{${members[*]}}"
  # Compress on every core and publish each 512MiB chunk as soon as it
  # is closed, instead of waiting for the whole archive.
  (
    set -o pipefail
    tar -C "$root" -cf - "${members[@]}" \
      | zstd -T0 -3 -c -v \
      | python3 -u -c '
import os
import sys

chunk_bytes = int(sys.argv[1])
out_dir = sys.argv[2]
index = 0
remaining = chunk_bytes
path = os.path.join(out_dir, f"chunk-{index:05d}.partial")
handle = open(path, "wb")

def rotate():
    global handle, index, remaining, path
    handle.close()
    final = os.path.join(out_dir, f"chunk-{index:05d}")
    os.rename(path, final)
    print(f"compressed chunk-{index:05d}", file=sys.stderr, flush=True)
    index += 1
    remaining = chunk_bytes
    path = os.path.join(out_dir, f"chunk-{index:05d}.partial")
    handle = open(path, "wb")

while True:
    buf = sys.stdin.buffer.read(8 * 1024 * 1024)
    if not buf:
        break
    view = memoryview(buf)
    while len(view):
        take = min(len(view), remaining)
        handle.write(view[:take])
        view = view[take:]
        remaining -= take
        if remaining == 0:
            rotate()
handle.close()
if os.path.getsize(path) == 0:
    os.remove(path)
    count = index
else:
    final = os.path.join(out_dir, f"chunk-{index:05d}")
    os.rename(path, final)
    print(f"compressed chunk-{index:05d}", file=sys.stderr, flush=True)
    count = index + 1
with open(os.path.join(out_dir, "chunks-done"), "w", encoding="utf-8") as done:
    done.write(str(count) + "\n")
' "$CHUNK_BYTES" "$work"
  ) &
  local compress_pid=$!
  (
    set +e
    index=0
    max="${PUSH_CONCURRENCY:-3}"
    running=0
    while true; do
      if [[ -e "$work/compress-fail" ]]; then
        touch "$work/push-fail"
        exit 1
      fi
      name="$(printf 'chunk-%05d' "$index")"
      ready="$work/$name"
      if [[ -f "$ready" ]]; then
        (
          cd "$work"
          echo "push ${name}"
          if ! retry_oras oras blob push "${CACHE_IMAGE}" "$name" \
            --media-type "$CHUNK_TYPE" \
            --descriptor > "${name}.desc"; then
            echo "blob upload failed: ${name}" >&2
            touch "$work/push-fail"
            exit 1
          fi
        ) &
        running=$((running + 1))
        index=$((index + 1))
        if [[ "$running" -ge "$max" ]]; then
          wait -n || true
          running=$((running - 1))
        fi
        continue
      fi
      if [[ -f "$work/chunks-done" ]]; then
        break
      fi
      sleep 0.2
    done
    wait || true
    if [[ -e "$work/push-fail" ]]; then
      exit 1
    fi
  ) &
  local upload_pid=$!
  local compress_rc=0 upload_rc=0
  set +e
  wait "$compress_pid"
  compress_rc=$?
  if [[ "$compress_rc" -ne 0 ]]; then
    touch "$work/compress-fail"
  fi
  wait "$upload_pid"
  upload_rc=$?
  set -e
  if [[ "$compress_rc" -ne 0 || "$upload_rc" -ne 0 || -e "$work/push-fail" ]]; then
    echo "pack failed" >&2
    return 1
  fi
  echo "split cache into $(tr -d '[:space:]' < "$work/chunks-done") blobs"
  (
    cd "$work"
    printf '{}' > config.json
    retry_oras oras blob push "${CACHE_IMAGE}" config.json \
      --media-type application/vnd.oci.empty.v1+json \
      --descriptor > config.desc
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
  list-members) cmd_list_members ;;
  members-for) shift; cmd_members_for "$@" ;;
  build-members-for) shift; cmd_build_members_for "$@" ;;
  build-image-for) shift; cmd_build_image_for "$@" ;;
  tools-status) cmd_tools_status ;;
  push) cmd_push ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 1 ;;
esac
