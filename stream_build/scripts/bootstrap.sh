#!/usr/bin/env bash
# Put this checkout at webrtc/src and write the parent .gclient.
# src is this worktree (no second clone). Refuses a symlink src.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

CONFIRM="${CONFIRM:-0}"

usage() {
  cat <<'EOF'
usage: bootstrap.sh [--check] [--gclient]

  make bootstrap            interactive wrap to webrtc/src
  make bootstrap CONFIRM=1  non-interactive (CI)

env:
  CONFIRM         1 to skip prompts
  BOOTSTRAP_SRC   git checkout to wrap (overrides WEBRTC_SRC)
  WEBRTC_SRC      git checkout (default: stream_build/..)
  DEPS_ROOT       gclient parent (default: parent of src)
  WEBRTC_REPO     written into .gclient
  TARGET_OS       written into .gclient
EOF
}

logical_pwd() {
  (cd "$1" && pwd)
}

ask() {
  local prompt="$1"
  if [[ "$CONFIRM" == "1" ]]; then
    echo "$prompt (CONFIRM=1: yes)"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "error: non-interactive bootstrap requires CONFIRM=1" >&2
    return 1
  fi
  local ans=""
  read -r -p "$prompt [y/N] " ans || true
  [[ "$ans" == "y" || "$ans" == "Y" || "$ans" == "yes" ]]
}

refuse_with_commands() {
  echo "error: refused. run:" >&2
  local cmd
  for cmd in "$@"; do
    echo "  $cmd" >&2
  done
  echo "then: make bootstrap" >&2
  exit 1
}

layout_fail() {
  echo "run: make bootstrap" >&2
  return 1
}

# 1-3 always: basename src, parent webrtc, src is a real directory.
# --gclient also requires DEPS_ROOT/.gclient (deps/build/test/package).
layout_check() {
  local src="$1"
  local deps_root="$2"
  local need_gclient="${3:-0}"
  if [[ ! -d "$src" || -L "$src" ]]; then
    layout_fail
    return 1
  fi
  if [[ "$(basename "$src")" != "src" ]]; then
    layout_fail
    return 1
  fi
  if [[ "$(basename "$deps_root")" != "webrtc" ]]; then
    layout_fail
    return 1
  fi
  if [[ ! -d "$deps_root/src" || -L "$deps_root/src" ]]; then
    layout_fail
    return 1
  fi
  local src_real deps_src_real
  src_real="$(cd "$src" && pwd -P)"
  deps_src_real="$(cd "$deps_root/src" && pwd -P)"
  if [[ "$src_real" != "$deps_src_real" ]]; then
    layout_fail
    return 1
  fi
  if [[ "$need_gclient" == "1" && ! -f "$deps_root/.gclient" ]]; then
    layout_fail
    return 1
  fi
  return 0
}

install_parent_makefile() {
  local dest="$1/Makefile"
  local tmpl="$SCRIPT_DIR/../webrtc.mk"
  if [[ -e "$dest" ]]; then
    echo "keeping $dest"
    return 0
  fi
  [[ -f "$tmpl" ]] || die "missing template $tmpl"
  cp "$tmpl" "$dest"
  echo "wrote $dest"
}

finish_layout() {
  local src="$1"
  local deps_root="$2"
  local git_cache="${GIT_CACHE_PATH:-$deps_root/.gclient-git-cache}"
  mkdir -p "$git_cache"
  write_gclient "$deps_root"
  install_parent_makefile "$deps_root"
  rewrite_git_cache_alternates "$src" "$git_cache"
  echo "gclient root: $deps_root"
  echo "src:          $src"
  echo "git-cache:    $git_cache"
  echo "out:          $deps_root/out"
}

cmd_check() {
  local src deps_root need_gclient=0 arg
  for arg in "$@"; do
    case "$arg" in
      --gclient) need_gclient=1 ;;
    esac
  done
  src="${BOOTSTRAP_SRC:-${WEBRTC_SRC:-$(logical_pwd "$SCRIPT_DIR/..")}}"
  deps_root="${DEPS_ROOT:-$(logical_pwd "$src/..")}"
  layout_check "$src" "$deps_root" "$need_gclient" || exit 1
}

cmd_bootstrap() {
  local src
  src="${BOOTSTRAP_SRC:-${WEBRTC_SRC:-$(logical_pwd "$SCRIPT_DIR/..")}}"
  [[ -d "$src" ]] || die "checkout not found: $src"
  if [[ -L "$src" ]]; then
    die "bootstrap refuses symlink src ($src -> $(readlink "$src"))"
  fi
  src="$(logical_pwd "$src")"
  [[ -f "$src/DEPS" ]] || die "no DEPS at $src"

  if [[ "$(basename "$src")" != "src" ]]; then
    local parent rename_dest
    parent="$(dirname "$src")"
    rename_dest="$parent/src"
    echo "checkout is named '$(basename "$src")'; gclient requires 'src'."
    echo "plan:"
    echo "  mv $src $rename_dest"
    if [[ -e "$rename_dest" ]]; then
      die "refusing to overwrite $rename_dest"
    fi
    if ! ask "rename to src?"; then
      refuse_with_commands "mv $src $rename_dest"
    fi
    echo "mv $src $rename_dest"
    mv "$src" "$rename_dest"
    src="$rename_dest"
  fi

  local parent deps_root
  parent="$(dirname "$src")"
  if [[ "$(basename "$parent")" != "webrtc" ]]; then
    deps_root="$parent/webrtc"
    echo "parent is named '$(basename "$parent")'; gclient root must be named webrtc."
    echo "plan:"
    echo "  mkdir $deps_root"
    echo "  mv $src $deps_root/src"
    echo "result: $deps_root/src"
    if [[ -e "$deps_root" ]]; then
      die "refusing to overwrite $deps_root"
    fi
    if ! ask "wrap as $deps_root/src?"; then
      refuse_with_commands "mkdir $deps_root" "mv $src $deps_root/src"
    fi
    mkdir "$deps_root"
    echo "mv $src $deps_root/src"
    mv "$src" "$deps_root/src"
    src="$deps_root/src"
    parent="$deps_root"
  fi

  deps_root="$(logical_pwd "$parent")"
  src="$(logical_pwd "$src")"
  if [[ -L "$src" || -L "$deps_root/src" ]]; then
    die "bootstrap refuses symlink src"
  fi

  finish_layout "$src" "$deps_root"
}

case "${1:-}" in
  --check)
    shift
    cmd_check "$@"
    ;;
  -h|--help|help) usage ;;
  "") cmd_bootstrap ;;
  *) usage >&2; exit 1 ;;
esac
