#!/usr/bin/env bash
# Fail when libwebrtc.jar packs classes outside the WebRTC namespaces, or
# lacks the generated jni_zero proxy classes the native library calls into.
#
# Runs before packaging so a third-party jar reached through
# direct_deps_only = false fails CI here instead of reaching the SDK. Fix a
# failure by excluding the package in extensions/android/stream_android_jar.gni;
# widen ALLOWED_PREFIXES only for namespaces Stream ships on purpose.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_cmd python3

JAR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jar) JAR="$2"; shift 2 ;;
    *) die "verify-android-jar.sh: unknown flag $1" ;;
  esac
done
[[ -n "$JAR" ]] || die "verify-android-jar.sh requires --jar"
[[ -f "$JAR" ]] || die "missing jar $JAR"

python3 - "$JAR" <<'PY'
import sys
import zipfile

ALLOWED_PREFIXES = (
    "org/webrtc/",
    "io/getstream/webrtc/",
    "org/jni_zero/",
)
ALLOWED_META_INF = (
    "META-INF/",
    "META-INF/MANIFEST.MF",
)

jar = sys.argv[1]
with zipfile.ZipFile(jar) as zf:
    names = zf.namelist()

unexpected = sorted(
    n for n in names
    if not n.endswith("/")
    and not n.startswith(ALLOWED_PREFIXES)
    and n not in ALLOWED_META_INF
)
if unexpected:
    def root(name):
        parts = name.split("/")
        depth = 2 if parts[0] in ("META-INF", "org", "io", "com") else 1
        return "/".join(parts[:depth]) if len(parts) > depth else name
    roots = sorted({root(n) for n in unexpected})
    print(f"{jar} packs {len(unexpected)} entries outside the allowlist:",
          file=sys.stderr)
    for root in roots:
        print(f"  {root}", file=sys.stderr)
    print("Exclude them in extensions/android/stream_android_jar.gni.",
          file=sys.stderr)
    sys.exit(1)

if not any(n.endswith("Jni.class") for n in names):
    print(f"{jar} has no generated *Jni.class proxies; "
          "check direct_deps_only on sdk/android:libwebrtc.", file=sys.stderr)
    sys.exit(1)

print(f"verified {jar}")
PY
