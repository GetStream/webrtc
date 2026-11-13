#!/usr/bin/env bash
# A fresh GitHub macOS runner spends the first iOS simulator boot in data
# migration. Chromium waits 120 seconds, then wipes the simulator and
# xcodebuild hangs. Raise that wait before the iOS tests. This edits the
# gclient checkout of src/ios, not the webrtc tree.
set -euo pipefail

SRC=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC="$2"; shift 2 ;;
    *) echo "pin-ios-simulator-boot.sh: unknown flag $1" >&2; exit 1 ;;
  esac
done

[[ -n "$SRC" ]] || { echo "pin-ios-simulator-boot.sh requires --src" >&2; exit 1; }

python3 - "$SRC" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1]) / "ios/build/bots/scripts/iossim_util.py"
if not path.is_file():
    sys.exit(f"pin-ios-simulator-boot.sh: missing {path}")

pattern = re.compile(
    r"(subprocess\.check_call\(cmd, timeout=)(\d+)(\)\n"
    r"      return True\n"
    r"    except subprocess\.TimeoutExpired as e:\n"
    r'      msg = f"Manually booting simulator timed out after )(\d+)( seconds\.")'
)
text = path.read_text()
match = pattern.search(text)
if match is None:
    sys.exit(
        "pin-ios-simulator-boot.sh: simulator boot timeout not found in "
        f"{path}"
    )
if match.group(2) == "240" and match.group(4) == "240":
    raise SystemExit(0)
path.write_text(
    pattern.sub(r"\g<1>240\g<3>240\g<5>", text, count=1)
)
print(f"pinned {path} simulator boot timeout to 240 seconds")
PY
