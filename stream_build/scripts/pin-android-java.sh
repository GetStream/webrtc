#!/usr/bin/env bash
# Chromium M156 hardcodes javac --release 25, so the Android AAR contains
# class version 69. stream_video stays on JDK 17 until its next major, and
# the WebRTC Java sources still compile at 17. Pin the two copies before
# ninja. This edits the gclient checkout of src/build, not the webrtc tree.
set -euo pipefail

SRC=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC="$2"; shift 2 ;;
    *) echo "pin-android-java.sh: unknown flag $1" >&2; exit 1 ;;
  esac
done

[[ -n "$SRC" ]] || { echo "pin-android-java.sh requires --src" >&2; exit 1; }

python3 - "$SRC" <<'PY'
import pathlib
import re
import sys

src = pathlib.Path(sys.argv[1])
pins = [
    (
        src / "build/android/gyp/compile_java.py",
        re.compile(
            r"(# Keep consistent with javac_cmd in //build/android/gyp/turbine\.py\.\n"
            r"        # LINT\.IfChange\n"
            r"        ')(\d+)(',)"
        ),
    ),
    (
        src / "build/android/gyp/turbine.py",
        re.compile(r"(javac_cmd = \['--release', ')(\d+)('\])"),
    ),
]

for path, pattern in pins:
    if not path.is_file():
        sys.exit(f"pin-android-java.sh: missing {path}")
    text = path.read_text()
    match = pattern.search(text)
    if match is None:
        sys.exit(f"pin-android-java.sh: Java release pin not found in {path}")
    if match.group(2) == "17":
        continue
    path.write_text(pattern.sub(r"\g<1>17\g<3>", text, count=1))
    print(f"pinned {path} to Java 17")
PY
