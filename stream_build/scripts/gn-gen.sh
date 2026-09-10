#!/usr/bin/env bash
# Write args.gn and run gn gen. Also prints composed args or a slice ninja target.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: gn-gen.sh --src DIR --out DIR [options]
       gn-gen.sh --print [options]
       gn-gen.sh --ninja-target SLICE

options:
  --config release|debug   default: release
  --slice NAME             lookup gn/slices.tsv
  --overlay NAME           gn/NAME.args (repeatable)
  --extra "k=v k2=v2"      extra GN args
  --flat                   with --print, emit key=value tokens
EOF
}

SRC=""
OUT_DIR=""
CONFIG="release"
SLICE=""
EXTRA=""
PRINT=0
FLAT=0
NINJA_ONLY=""
OVERLAYS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --slice) SLICE="$2"; shift 2 ;;
    --overlay) OVERLAYS+=("$2"); shift 2 ;;
    --extra) EXTRA="${2:-}"; shift 2 ;;
    --print) PRINT=1; shift ;;
    --flat) FLAT=1; shift ;;
    --ninja-target) NINJA_ONLY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "gn-gen.sh: unknown flag $1" ;;
  esac
done

if [[ -n "$NINJA_ONLY" ]]; then
  slice_ninja_target "$NINJA_ONLY"
  exit 0
fi

compose_flags=(--config "$CONFIG")
[[ -n "$SLICE" ]] && compose_flags+=(--slice "$SLICE")
[[ -n "$EXTRA" ]] && compose_flags+=(--extra "$EXTRA")
for overlay in "${OVERLAYS[@]+"${OVERLAYS[@]}"}"; do
  compose_flags+=(--overlay "$overlay")
done

args_text="$(compose_gn_args "${compose_flags[@]}")"

if [[ "$PRINT" -eq 1 ]]; then
  if [[ "$FLAT" -eq 1 ]]; then
    printf '%s\n' "$args_text" | flatten_gn_args
  else
    printf '%s\n' "$args_text"
  fi
  exit 0
fi

[[ -n "$SRC" && -n "$OUT_DIR" ]] || die "gn-gen.sh requires --src and --out (or --print)"
require_webrtc_src "$SRC"

mkdir -p "$OUT_DIR"
printf '%s\n' "$args_text" >"${OUT_DIR}/args.gn"

gn_bin="$(resolve_gn "$SRC")"
[[ -n "$gn_bin" ]] || die "gn not found"
echo "gn gen ${OUT_DIR}"
(
  cd "$SRC"
  "$gn_bin" gen "$OUT_DIR"
)
