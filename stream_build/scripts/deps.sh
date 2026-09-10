#!/usr/bin/env bash
# gclient config + sync for GetStream/webrtc.
# DEPS_ROOT is the gclient parent. src there is a symlink to WEBRTC_SRC (the git root).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: deps.sh sync|runhooks

env:
  DEPS_ROOT         gclient parent (required). Default from make: <git>/.gclient_deps
  WEBRTC_SRC        git root that contains DEPS (required)
  TARGET_OS         comma/space list, default: ios
  JOBS              gclient -j, default: 8
  RUN_HOOKS         1 to run hooks during sync, 0 for --nohooks
  WEBRTC_REPO       default: git@github.com:GetStream/webrtc.git
  WEBRTC_REVISION   pin src SHA only when src is a real clone gclient owns
  WEBRTC_REF        resolve SHA via git ls-remote when REVISION is empty
                    (refused when src is a symlink to this git checkout)
EOF
}

DEPS_ROOT="${DEPS_ROOT:-${WEBRTC_ROOT:-}}"
WEBRTC_SRC="${WEBRTC_SRC:-}"
TARGET_OS="${TARGET_OS:-ios}"
JOBS="${JOBS:-8}"
RUN_HOOKS="${RUN_HOOKS:-1}"
WEBRTC_REPO="${WEBRTC_REPO:-git@github.com:GetStream/webrtc.git}"
WEBRTC_REVISION="${WEBRTC_REVISION:-}"
WEBRTC_REF="${WEBRTC_REF:-}"

git_sha() {
  [[ "$1" =~ ^[0-9a-fA-F]{7,40}$ ]]
}

resolve_revision() {
  if [[ -n "$WEBRTC_REVISION" ]]; then
    printf '%s\n' "$WEBRTC_REVISION"
    return
  fi
  if [[ -n "$WEBRTC_REF" ]]; then
    if git_sha "$WEBRTC_REF"; then
      printf '%s\n' "$WEBRTC_REF"
      return
    fi
    local sha=""
    local pattern
    for pattern in "$WEBRTC_REF" "refs/heads/${WEBRTC_REF}" "refs/tags/${WEBRTC_REF}"; do
      sha="$(git ls-remote --exit-code "$WEBRTC_REPO" "$pattern" 2>/dev/null | awk '{ print $1; exit }' || true)"
      if [[ -n "$sha" ]]; then
        printf '%s\n' "$sha"
        return
      fi
    done
    die "unable to resolve WEBRTC_REF='$WEBRTC_REF' from $WEBRTC_REPO"
  fi
  if [[ -n "$WEBRTC_SRC" && -d "$WEBRTC_SRC/.git" ]]; then
    git -C "$WEBRTC_SRC" rev-parse HEAD
    return
  fi
  printf '\n'
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

write_gclient() {
  local dest="$1"
  local revision="$2"
  local revision_line=""
  if [[ -n "$revision" ]]; then
    revision_line=$'\n    "revision": "'"${revision}"'",'
  fi
  cat >"${dest}/.gclient" <<EOF
solutions = [
  {
    "name": "src",
    "url": "${WEBRTC_REPO}",
    "deps_file": "DEPS",
    "managed": False,
    "custom_deps": {},${revision_line}
  },
]
target_os = $(quote_target_os "$TARGET_OS")
EOF
}

# Relative ".." when DEPS_ROOT is <git>/.gclient_deps; otherwise an absolute path.
src_link_target() {
  local deps_abs src_abs
  deps_abs="$(cd "$DEPS_ROOT" && pwd)"
  src_abs="$(cd "$WEBRTC_SRC" && pwd)"
  if [[ "$(cd "$DEPS_ROOT/.." && pwd)" == "$src_abs" && "$(basename "$DEPS_ROOT")" == ".gclient_deps" ]]; then
    printf '..\n'
  else
    printf '%s\n' "$src_abs"
  fi
}

ensure_src_symlink() {
  [[ -n "$DEPS_ROOT" ]] || die "DEPS_ROOT is required"
  [[ -n "$WEBRTC_SRC" ]] || die "WEBRTC_SRC is required"
  [[ -f "$WEBRTC_SRC/DEPS" ]] || die "No WebRTC checkout at $WEBRTC_SRC (missing DEPS)"
  mkdir -p "$DEPS_ROOT"
  local link="$DEPS_ROOT/src"
  local target
  target="$(src_link_target)"
  if [[ -L "$link" ]]; then
    ln -sfn "$target" "$link"
  elif [[ -e "$link" ]]; then
    die "$link exists and is not a symlink (refusing a nested webrtc checkout)"
  else
    ln -sfn "$target" "$link"
  fi
  [[ -f "$link/DEPS" ]] || die "symlink $link does not point at a WebRTC tree"
}

# True when DEPS_ROOT/src is a symlink to this git checkout, not a clone
# gclient owns. gclient must not checkout/reset/clean that tree.
src_is_developer_symlink() {
  local link="${DEPS_ROOT}/src"
  [[ -L "$link" ]] || return 1
  [[ -n "$WEBRTC_SRC" ]] || return 0
  local link_abs src_abs
  link_abs="$(cd "$link" && pwd -P)"
  src_abs="$(cd "$WEBRTC_SRC" && pwd -P)"
  [[ "$link_abs" == "$src_abs" ]]
}

cmd_sync() {
  require_cmd gclient
  require_cmd git
  require_cmd python3
  ensure_src_symlink

  local revision=""
  if src_is_developer_symlink; then
    if [[ -n "$WEBRTC_REVISION" || -n "$WEBRTC_REF" ]]; then
      die "src is your git checkout; will not reset it"
    fi
    echo "src is a symlink to the git checkout; will not reset it"
  else
    revision="$(resolve_revision)"
    if [[ -n "$revision" ]]; then
      echo "pinning gclient src revision: $revision"
    fi
  fi
  # DEPS checkouts use this cache as their git alternate/origin. Unsetting
  # it makes gclient retarget them from the cache URL to googlesource.
  if [[ -d "$DEPS_ROOT/.gclient-git-cache" ]]; then
    export GIT_CACHE_PATH="$DEPS_ROOT/.gclient-git-cache"
  fi
  write_gclient "$DEPS_ROOT" "$revision"

  (
    cd "$DEPS_ROOT"
    gclient root >/dev/null || true
    local sync=(gclient sync -j"${JOBS}")
    if [[ -n "$revision" ]]; then
      sync+=(--revision "src@${revision}")
    fi
    if [[ "$RUN_HOOKS" == "0" || "$RUN_HOOKS" == "false" ]]; then
      sync+=(--nohooks)
    fi
    echo "running: ${sync[*]}"
    "${sync[@]}"
  )
}

cmd_runhooks() {
  require_cmd gclient
  ensure_src_symlink
  [[ -f "$DEPS_ROOT/.gclient" ]] || die "gclient config not found at $DEPS_ROOT/.gclient"
  (
    cd "$DEPS_ROOT"
    echo "running: gclient runhooks"
    gclient runhooks
  )
}

case "${1:-}" in
  sync) cmd_sync ;;
  runhooks) cmd_runhooks ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 1 ;;
esac
