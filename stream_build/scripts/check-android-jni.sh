#!/usr/bin/env bash
# Static jni_zero checks for sdk/android that need no gclient sync or build.
#
# 1. Every .cc that includes a generated <Class>_jni.h for a Java class with
#    native methods invokes DEFINE_JNI(<Class>). Without it jni_zero emits no
#    Java_* entry points, the build still passes, and the AAR throws
#    UnsatisfiedLinkError on first call.
# 2. The generate_jni targets reachable from dist_jar("libwebrtc") match the
#    ones linked into libjingle_peerconnection_so. jni_zero's generate-final
#    rejects a mismatch, and a Java proxy with no linked native crashes at
#    runtime.
#
# The BUILD.gn walk is textual: it follows deps, public_deps, and java_targets
# lists inside each target and ignores conditions. Treat a report as a lead to
# confirm in BUILD.gn, not as proof.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_cmd python3

SRC=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC="$2"; shift 2 ;;
    *) die "check-android-jni.sh: unknown flag $1" ;;
  esac
done
[[ -n "$SRC" ]] || die "check-android-jni.sh requires --src"
[[ -f "$SRC/sdk/android/BUILD.gn" ]] || die "missing $SRC/sdk/android/BUILD.gn"

python3 - "$SRC" <<'PY'
import os
import re
import sys

root = sys.argv[1]
JAR = "sdk/android:libwebrtc"
SO = "sdk/android:libjingle_peerconnection_so"
SCANNED = ("sdk/android", "extensions/android")
targets = {}
parsed = set()


def label(raw, base):
    raw = raw.split("(")[0]
    if raw.startswith(":"):
        return f"{base}:{raw[1:]}"
    path, _, name = raw.partition(":")
    path = path[2:] if path.startswith("//") else os.path.normpath(
        os.path.join(base, path))
    return f"{path}:{name or os.path.basename(path)}"


def parse(rel):
    if rel in parsed:
        return
    parsed.add(rel)
    path = os.path.join(root, rel, "BUILD.gn")
    if not os.path.exists(path):
        return
    text = open(path).read()
    for m in re.finditer(r'^\s*([a-z_]+)\("([^"]+)"\)\s*\{', text, re.M):
        depth, i = 1, m.end()
        while depth and i < len(text):
            depth += {"{": 1, "}": -1}.get(text[i], 0)
            i += 1
        body = text[m.end():i]
        deps = [label(d, rel)
                for lst in re.finditer(
                    r'\b(?:deps|public_deps|java_targets)\s*\+?=\s*\[(.*?)\]',
                    body, re.S)
                for d in re.findall(r'"([^"]+)"', lst.group(1))]
        targets[f"{rel}:{m.group(2)}"] = {
            "type": m.group(1),
            "deps": deps,
            "java": re.findall(r'"([^"]+\.java)"', body),
        }


def closure(start):
    seen, todo = set(), [start]
    while todo:
        t = todo.pop()
        if t in seen:
            continue
        seen.add(t)
        if t.startswith(("third_party/", "build/")):
            continue
        parse(t.split(":")[0])
        todo += targets.get(t, {}).get("deps", [])
    return seen


def is_generate_jni(t):
    return targets.get(t, {}).get("type") == "generate_jni"


failed = False

native_side = {t for t in closure(SO) if is_generate_jni(t)}
java_side = {t[:-len("_java")] for t in closure(JAR)
             if t.endswith("_java") and is_generate_jni(t[:-len("_java")])}
for t in sorted(java_side - native_side):
    failed = True
    print(f"{t}: libwebrtc packs its Java, but {SO} does not link its "
          "native side.", file=sys.stderr)
for t in sorted(native_side - java_side):
    failed = True
    print(f"{t}: {SO} links its native side, but libwebrtc does not pack "
          "its Java.", file=sys.stderr)

for rel in SCANNED:
    for dirpath, _, files in os.walk(os.path.join(root, rel)):
        for f in files:
            if f.endswith(".gn"):
                parse(os.path.relpath(dirpath, root))

java_with_natives = set()
for t, info in targets.items():
    if info["type"] != "generate_jni":
        continue
    base = t.split(":")[0]
    for src in info["java"]:
        path = os.path.join(root, base, src)
        if os.path.exists(path) and re.search(
                r"@NativeMethods|\bnative\s+[\w<>\[\], .]+\s+\w+\s*\(",
                open(path).read()):
            java_with_natives.add(os.path.basename(src)[:-len(".java")])

include = re.compile(r'#include\s+"[^"]*/([A-Za-z0-9_$]+)_jni\.h"')
for rel in SCANNED:
    for dirpath, _, files in os.walk(os.path.join(root, rel)):
        for f in files:
            if not f.endswith(".cc"):
                continue
            path = os.path.join(dirpath, f)
            text = open(path).read()
            for cls in include.findall(text):
                if cls in java_with_natives and \
                        f"DEFINE_JNI({cls})" not in text:
                    failed = True
                    print(f"{os.path.relpath(path, root)}: includes "
                          f"{cls}_jni.h but never invokes DEFINE_JNI({cls}).",
                          file=sys.stderr)

if failed:
    sys.exit(1)
print(f"jni ok: {len(java_side)} generate_jni targets match")
PY
