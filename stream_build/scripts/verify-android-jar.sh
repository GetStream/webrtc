#!/usr/bin/env bash
# Fail when libwebrtc.jar packs classes outside the WebRTC namespaces, lacks
# the generated jni_zero *Jni proxies, or lacks a GEN_JNI (and J.N) that
# defines every proxy method those *Jni classes call.
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

python3 - "$SCRIPT_DIR" "$JAR" <<'PY'
import sys
import zipfile

sys.path.insert(0, sys.argv[1])
from jvm_classfile import ClassFile

ALLOWED_PREFIXES = (
    "org/webrtc/",
    "io/getstream/webrtc/",
    "org/jni_zero/",
)
ALLOWED_FILES = (
    "META-INF/",
    "META-INF/MANIFEST.MF",
    # jni_zero's hashed-name natives; GEN_JNI forwards to it.
    "J/N.class",
)
GEN_JNI = "org/jni_zero/GEN_JNI"
SHORT_GEN_JNI = "J/N"

jar = sys.argv[2]
with zipfile.ZipFile(jar) as zf:
    names = zf.namelist()
    jni_classes = [ClassFile(zf.read(n)) for n in names
                   if n.endswith("Jni.class")]
    gen_jni = (ClassFile(zf.read(GEN_JNI + ".class"))
               if GEN_JNI + ".class" in names else None)

unexpected = sorted(
    n for n in names
    if not n.endswith("/")
    and not n.startswith(ALLOWED_PREFIXES)
    and n not in ALLOWED_FILES
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

if not jni_classes:
    print(f"{jar} has no generated *Jni.class proxies; "
          "check direct_deps_only on sdk/android:libwebrtc.", file=sys.stderr)
    sys.exit(1)

if gen_jni is None:
    print(f"{jar} has no {GEN_JNI}.class; *Jni classes fail with "
          "NoClassDefFoundError. Check :libwebrtc_final_jni_java in "
          "sdk/android/BUILD.gn.", file=sys.stderr)
    sys.exit(1)

if (any(cls == SHORT_GEN_JNI for cls, _, _ in gen_jni.method_refs)
        and SHORT_GEN_JNI + ".class" not in names):
    print(f"{jar} has {GEN_JNI}.class forwarding to J.N but no "
          f"{SHORT_GEN_JNI}.class.", file=sys.stderr)
    sys.exit(1)

declared = {(name, desc) for _, name, desc in gen_jni.methods}
missing = sorted({
    (c.name, name + desc)
    for c in jni_classes
    for cls, name, desc in c.method_refs
    if cls == GEN_JNI and (name, desc) not in declared
})
if missing:
    print(f"{jar}: {GEN_JNI}.class lacks {len(missing)} proxy methods "
          "(name and descriptor); add their Java targets to "
          ":libwebrtc_java_targets in sdk/android/BUILD.gn:", file=sys.stderr)
    for cls, method in missing[:20]:
        print(f"  {cls}: {method}", file=sys.stderr)
    sys.exit(1)

print(f"verified {jar}")
PY
