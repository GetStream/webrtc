#!/usr/bin/env bash
# Fail when a native method in libwebrtc.jar has no Java_* export in a
# packaged libjingle_peerconnection_so. The JVM only resolves natives on
# first call, so a missing export otherwise ships and crashes at runtime with
# UnsatisfiedLinkError.
#
# Covers J.N's hashed jni_zero natives and legacy `native` methods alike. A
# legacy class usually fails because its .cc lacks DEFINE_JNI(<Class>); a
# hashed one because the native library does not link the class's *_jni
# target.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_cmd python3

JAR=""
SOS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jar) JAR="$2"; shift 2 ;;
    --so) SOS+=("$2"); shift 2 ;;
    *) die "verify-android-natives.sh: unknown flag $1" ;;
  esac
done
[[ -n "$JAR" ]] || die "verify-android-natives.sh requires --jar"
[[ -f "$JAR" ]] || die "missing jar $JAR"
((${#SOS[@]})) || die "verify-android-natives.sh requires at least one --so"
for so in "${SOS[@]}"; do
  [[ -f "$so" ]] || die "missing native library $so"
done

python3 - "$SCRIPT_DIR" "$JAR" "${SOS[@]}" <<'PY'
import sys
import zipfile

sys.path.insert(0, sys.argv[1])
from jvm_classfile import ACC_NATIVE, ClassFile, dynamic_symbols, jni_symbols

jar, *sos = sys.argv[2:]
natives = []
with zipfile.ZipFile(jar) as zf:
    for n in zf.namelist():
        if n.endswith(".class"):
            c = ClassFile(zf.read(n))
            natives += [(c.name, name, desc) for access, name, desc in c.methods
                        if access & ACC_NATIVE]

failed = False
for so in sos:
    exports = dynamic_symbols(so)
    missing = [f"{cls}.{method}{desc}" for cls, method, desc in natives
               if not exports.intersection(jni_symbols(cls, method, desc))]
    if missing:
        failed = True
        print(f"{so} exports no Java_* symbol for {len(missing)} native "
              "methods in the jar:", file=sys.stderr)
        for m in sorted(missing)[:40]:
            print(f"  {m}", file=sys.stderr)

if failed:
    sys.exit(1)
print(f"verified {len(natives)} native methods against {len(sos)} libraries")
PY
