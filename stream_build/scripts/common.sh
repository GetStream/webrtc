#!/usr/bin/env bash
# Shared helpers for the WebRTC Makefile wrapper.
set -euo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GN_DIR="${PIPELINE_DIR}/gn"

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required tool '$1' not found in PATH"
}

host_uname() {
  uname -s
}

require_darwin() {
  [[ "$(host_uname)" == Darwin ]] || die "Apple targets require macOS"
}

require_linux() {
  [[ "$(host_uname)" == Linux ]] || die "Android AAR builds require Linux"
}

require_windows() {
  case "$(host_uname)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  [[ "${OS:-}" == Windows_NT ]] || die "Windows targets require Windows"
}

require_webrtc_src() {
  local src="${1:-}"
  [[ -n "$src" ]] || die "WEBRTC_SRC or WEBRTC_ROOT is required"
  [[ -f "$src/DEPS" ]] || die "No WebRTC checkout at $src (missing DEPS)"
}

quote_target_os() {
  local raw="$1"
  local os first=1
  printf '['
  # shellcheck disable=SC2086
  for os in ${raw//,/ }; do
    [[ -z "$os" ]] && continue
    if [[ $first -eq 1 ]]; then
      first=0
    else
      printf ', '
    fi
    printf '"%s"' "$os"
  done
  printf ']\n'
}

# Write Chromium .gclient at the gclient parent. managed: False, no revision.
write_gclient() {
  local dest="$1"
  local repo="${2:-${WEBRTC_REPO:-git@github.com:GetStream/webrtc.git}}"
  local target_os="${3:-${TARGET_OS:-ios}}"
  cat >"${dest}/.gclient" <<EOF
solutions = [
  {
    "name": "src",
    "url": "${repo}",
    "deps_file": "DEPS",
    "managed": False,
    "custom_deps": {},
  },
]
target_os = $(quote_target_os "$target_os")
EOF
}

# After git-cache moves off .gclient_deps/.gclient-git-cache, nested checkouts
# still point objects/info/alternates (and origin urls) at the old path.
# Rewrite those to GIT_CACHE_PATH. No-op if the cache itself is the old path.
rewrite_git_cache_alternates() {
  local src="$1"
  local git_cache="$2"
  [[ -d "$src" && -n "$git_cache" ]] || return 0
  python3 - "$src" "$git_cache" <<'PY'
import subprocess
import sys

src, new_cache = sys.argv[1], sys.argv[2].rstrip("/")
frag = ".gclient_deps/.gclient-git-cache"
if new_cache.endswith(frag):
    raise SystemExit(0)

cmd = [
    "find",
    src,
    "(",
    "-path",
    "*/.git/objects/info/alternates",
    "-o",
    "-path",
    "*/.git/objects/info/http-alternates",
    "-o",
    "-path",
    "*/.git/config",
    "-o",
    "-path",
    "*/.git/modules/*/objects/info/alternates",
    "-o",
    "-path",
    "*/.git/modules/*/objects/info/http-alternates",
    "-o",
    "-path",
    "*/.git/modules/*/config",
    ")",
    "-type",
    "f",
]
try:
    listing = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
except subprocess.CalledProcessError:
    raise SystemExit(0)

stops = frozenset(" \t\n=\"'")


def rewrite_line(line: str) -> str:
    idx = line.find(frag)
    if idx < 0:
        return line
    start = idx
    while start > 0 and line[start - 1] not in stops:
        start -= 1
    return line[:start] + new_cache + line[idx + len(frag) :]


repos = set()
for path in listing.splitlines():
    if not path:
        continue
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        continue
    if frag not in text:
        continue
    rewritten = "".join(rewrite_line(line) for line in text.splitlines(True))
    if rewritten == text:
        continue
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(rewritten)
    marker = "/.git/"
    i = path.find(marker)
    repos.add(path[:i] if i >= 0 else path)

if repos:
    print("rewrote git-cache paths in %d repos" % len(repos))
PY
}

abspath() {
  local path="$1"
  (cd "$(dirname "$path")" && printf '%s/%s\n' "$(pwd)" "$(basename "$path")")
}

resolve_gn() {
  local src="${1:-}"
  local os
  os="$(host_uname)"
  local candidate=""
  case "$os" in
    Darwin) candidate="$src/buildtools/mac/gn" ;;
    Linux) candidate="$src/buildtools/linux64/gn" ;;
    MINGW*|MSYS*|CYGWIN*) candidate="$src/buildtools/win/gn.exe" ;;
  esac
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return
  fi
  command -v gn
}

resolve_ninja() {
  local src="${1:-}"
  local bundled="$src/third_party/ninja/ninja"
  if [[ -x "$bundled" ]]; then
    printf '%s\n' "$bundled"
    return
  fi
  command -v ninja
}

is_apple_slice() {
  local name="$1"
  [[ "$name" == ios-* || "$name" == catalyst-* || "$name" == macos-* ]]
}

is_android_slice() {
  local name="$1"
  [[ "$name" == android-* ]]
}

is_windows_slice() {
  local name="$1"
  [[ "$name" == windows-* ]]
}

slice_line() {
  local name="$1"
  local line
  line="$(awk -F'\t' -v n="$name" '$1 == n { print; exit }' "${GN_DIR}/slices.tsv")"
  [[ -n "$line" ]] || die "unknown slice '$name' (see gn/slices.tsv)"
  printf '%s\n' "$line"
}

slice_ninja_target() {
  local name="$1"
  slice_line "$name" | awk -F'\t' '{ print $2 }'
}

slice_gn_args() {
  local name="$1"
  slice_line "$name" | awk -F'\t' '{ print $3 }'
}

# Convert "key=value" / "key = value" tokens into args.gn lines.
gn_tokens_to_lines() {
  local token key value
  for token in "$@"; do
    [[ -z "$token" ]] && continue
    key="${token%%=*}"
    value="${token#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    key="${key#"${key%%[![:space:]]*}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    printf '%s = %s\n' "$key" "$value"
  done
}

cat_gn_file() {
  local path="$1"
  [[ -f "$path" ]] || die "GN args file not found: $path"
  grep -v '^[[:space:]]*#' "$path" | grep -v '^[[:space:]]*$' || true
}

# Compose args.gn content. Reads env/flags via positional:
#   compose_gn_args --config release --slice NAME --overlay FILE --extra TOKENS
compose_gn_args() {
  local config="release"
  local slice=""
  local extra=""
  local overlays=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) config="$2"; shift 2 ;;
      --slice) slice="$2"; shift 2 ;;
      --overlay)
        overlays+=("$2")
        shift 2
        ;;
      --extra) extra="${2:-}"; shift 2 ;;
      *) die "compose_gn_args: unknown flag $1" ;;
    esac
  done

  cat_gn_file "${GN_DIR}/common.args"
  if [[ -n "$slice" ]] && is_apple_slice "$slice"; then
    cat_gn_file "${GN_DIR}/apple.args"
  fi
  if [[ -n "$slice" ]] && is_android_slice "$slice"; then
    cat_gn_file "${GN_DIR}/android.args"
  fi
  if [[ -n "$slice" ]] && is_windows_slice "$slice"; then
    cat_gn_file "${GN_DIR}/windows.args"
  fi
  local overlay
  for overlay in "${overlays[@]+"${overlays[@]}"}"; do
    [[ -z "$overlay" ]] && continue
    if [[ -f "$overlay" ]]; then
      cat_gn_file "$overlay"
    elif [[ -f "${GN_DIR}/${overlay}.args" ]]; then
      cat_gn_file "${GN_DIR}/${overlay}.args"
    else
      die "unknown GN overlay '$overlay'"
    fi
  done
  if [[ "$config" == debug ]]; then
    echo 'is_debug = true'
  else
    echo 'is_debug = false'
  fi
  if [[ -n "$slice" ]]; then
    # shellcheck disable=SC2086
    gn_tokens_to_lines $(slice_gn_args "$slice")
  fi
  if [[ -n "$extra" ]]; then
    # shellcheck disable=SC2086
    gn_tokens_to_lines $extra
  fi
}

flatten_gn_args() {
  awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      split(line, parts, " = ")
      if (length(parts) >= 2) {
        value = substr(line, index(line, " = ") + 3)
        printf "%s=%s\n", parts[1], value
      }
    }
  '
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    gn) resolve_gn "${1:-}" ;;
    ninja) resolve_ninja "${1:-}" ;;
    slice-ninja) slice_ninja_target "${1:-}" ;;
    *) die "usage: common.sh gn|ninja|slice-ninja ..." ;;
  esac
fi
