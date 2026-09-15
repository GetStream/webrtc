#!/usr/bin/env bash
# gclient config + sync for GetStream/webrtc.
# DEPS_ROOT is the gclient parent (named webrtc). src there is this git
# checkout, not a second clone/worktree and not a symlink to the git root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: deps.sh sync|runhooks

env:
  DEPS_ROOT         gclient parent (required). Default from make: parent of src
  WEBRTC_SRC        this git checkout (DEPS_ROOT/src). Not cloned again.
  TARGET_OS         comma/space list, default: ios
  JOBS              gclient -j, default: 8
  SHALLOW           1 (default) adds --no-history --shallow; 0 for full history
  RUN_HOOKS         1 to run hooks during sync, 0 for --nohooks
  WEBRTC_REPO       default: git@github.com:GetStream/webrtc.git
  GIT_CACHE_PATH    default: DEPS_ROOT/.gclient-git-cache
  WEBRTC_REVISION   refused (src is this worktree; gclient must not reset it)
  WEBRTC_REF        refused (same as WEBRTC_REVISION)
EOF
}

DEPS_ROOT="${DEPS_ROOT:-${WEBRTC_ROOT:-}}"
WEBRTC_SRC="${WEBRTC_SRC:-}"
TARGET_OS="${TARGET_OS:-ios}"
JOBS="${JOBS:-8}"
SHALLOW="${SHALLOW:-1}"
RUN_HOOKS="${RUN_HOOKS:-1}"
WEBRTC_REPO="${WEBRTC_REPO:-git@github.com:GetStream/webrtc.git}"
WEBRTC_REVISION="${WEBRTC_REVISION:-}"
WEBRTC_REF="${WEBRTC_REF:-}"

ensure_src() {
  [[ -n "$DEPS_ROOT" ]] || die "DEPS_ROOT is required"
  local dest="${DEPS_ROOT}/src"
  if [[ -L "$dest" ]]; then
    die "src is a symlink ($dest). run: make bootstrap"
  fi
  if [[ -f "$dest/DEPS" ]] && git -C "$dest" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi
  die "$dest is not this git checkout. run: make bootstrap"
}

cmd_sync() {
  require_cmd gclient
  require_cmd git
  require_cmd python3
  ensure_src

  if [[ -n "$WEBRTC_REVISION" || -n "$WEBRTC_REF" ]]; then
    die "src is seeded from your git checkout; will not reset it"
  fi
  echo "src is already present; will not reset it"
  GIT_CACHE_PATH="${GIT_CACHE_PATH:-$DEPS_ROOT/.gclient-git-cache}"
  mkdir -p "$GIT_CACHE_PATH"
  export GIT_CACHE_PATH
  rewrite_git_cache_alternates "${WEBRTC_SRC:-$DEPS_ROOT/src}" "$GIT_CACHE_PATH"
  write_gclient "$DEPS_ROOT" "$WEBRTC_REPO" "$TARGET_OS"

  (
    cd "$DEPS_ROOT"
    gclient root >/dev/null || true
    local sync=(gclient sync -j"${JOBS}")
    if [[ "$SHALLOW" == "1" || "$SHALLOW" == "true" ]]; then
      sync+=(--no-history --shallow)
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
  ensure_src
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
