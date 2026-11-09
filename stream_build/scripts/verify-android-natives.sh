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

python3 - "$JAR" "${SOS[@]}" <<'PY'
import struct
import sys
import zipfile

ACC_NATIVE = 0x0100


def native_methods(data):
    """Yields (class, method, descriptor) for each native method."""
    off = 8
    (count,) = struct.unpack_from(">H", data, off)
    off += 2
    pool = [None] * count
    i = 1
    while i < count:
        tag = data[off]
        off += 1
        if tag == 1:
            (length,) = struct.unpack_from(">H", data, off)
            off += 2
            pool[i] = data[off:off + length].decode("utf-8", "replace")
            off += length
        elif tag == 7:
            pool[i] = struct.unpack_from(">H", data, off)[0]
            off += 2
        elif tag in (8, 16, 19, 20):
            off += 2
        elif tag == 15:
            off += 3
        elif tag in (3, 4, 9, 10, 11, 12, 17, 18):
            off += 4
        elif tag in (5, 6):
            off += 8
            i += 1
        else:
            raise ValueError(f"unknown constant pool tag {tag}")
        i += 1
    _, this_class, _, interfaces = struct.unpack_from(">HHHH", data, off)
    off += 8 + 2 * interfaces
    name = pool[pool[this_class]]
    for member in ("fields", "methods"):
        (count,) = struct.unpack_from(">H", data, off)
        off += 2
        for _ in range(count):
            access, name_i, desc_i, attrs = struct.unpack_from(">HHHH", data, off)
            off += 8
            for _ in range(attrs):
                _, length = struct.unpack_from(">HI", data, off)
                off += 6 + length
            if member == "methods" and access & ACC_NATIVE:
                yield name, pool[name_i], pool[desc_i]


def jni_mangle(text):
    out = []
    for ch in text:
        if ch == "/":
            out.append("_")
        elif ch == "_":
            out.append("_1")
        elif ch == ";":
            out.append("_2")
        elif ch == "[":
            out.append("_3")
        elif ch.isascii() and ch.isalnum():
            out.append(ch)
        else:
            out.append("_0%04x" % ord(ch))
    return "".join(out)


def dynamic_symbols(path):
    """Defined symbols in an ELF shared library's .dynsym."""
    with open(path, "rb") as f:
        elf = f.read()
    if elf[:4] != b"\x7fELF":
        raise SystemExit(f"{path} is not an ELF file")
    is64 = elf[4] == 2
    end = "<" if elf[5] == 1 else ">"
    if is64:
        shoff, = struct.unpack_from(end + "Q", elf, 0x28)
        shentsize, shnum = struct.unpack_from(end + "HH", elf, 0x3A)
        sh_fmt, sym_fmt, sym_size = "IIQQQQIIQQ", "IBBHQQ", 24
    else:
        shoff, = struct.unpack_from(end + "I", elf, 0x20)
        shentsize, shnum = struct.unpack_from(end + "HH", elf, 0x2E)
        sh_fmt, sym_fmt, sym_size = "IIIIIIIIII", "IIIBBH", 16
    sections = [struct.unpack_from(end + sh_fmt, elf, shoff + k * shentsize)
                for k in range(shnum)]
    names = set()
    for sh in sections:
        if sh[1] != 11:  # SHT_DYNSYM
            continue
        offset, size, link = sh[4], sh[5], sh[6]
        strtab = sections[link][4]
        for k in range(size // sym_size):
            sym = struct.unpack_from(end + sym_fmt, elf, offset + k * sym_size)
            st_name, st_shndx = sym[0], (sym[3] if is64 else sym[5])
            if st_shndx == 0:
                continue
            stop = elf.index(b"\0", strtab + st_name)
            names.add(elf[strtab + st_name:stop].decode())
    return names


jar, *sos = sys.argv[1:]
with zipfile.ZipFile(jar) as zf:
    natives = [m for n in zf.namelist() if n.endswith(".class")
               for m in native_methods(zf.read(n))]

failed = False
for so in sos:
    exports = dynamic_symbols(so)
    missing = []
    for cls, method, desc in natives:
        short = f"Java_{jni_mangle(cls)}_{jni_mangle(method)}"
        args = jni_mangle(desc[1:desc.index(")")])
        if short not in exports and f"{short}__{args}" not in exports:
            missing.append(f"{cls}.{method}{desc}")
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
