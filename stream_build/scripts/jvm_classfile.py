"""Minimal .class and ELF readers for the Android packaging checks.

Shared by verify-android-jar.sh and verify-android-natives.sh. Standard
library only, so it runs on CI runners and macOS without a JDK or binutils.
"""
import struct

ACC_NATIVE = 0x0100
_METHOD_REFS = (10, 11)  # CONSTANT_Methodref, CONSTANT_InterfaceMethodref


def _modified_utf8(raw):
    # Class files use modified UTF-8: NUL is C0 80, and supplementary
    # characters are two 3-byte surrogates. surrogatepass keeps each
    # surrogate as its own code point, which is what JNI mangling escapes.
    return raw.replace(b"\xc0\x80", b"\x00").decode("utf-8", "surrogatepass")


class ClassFile:
    """name, methods [(access, name, descriptor)], and method_refs
    [(class, name, descriptor)] for every method the class references."""

    def __init__(self, data):
        if data[:4] != b"\xca\xfe\xba\xbe":
            raise ValueError("not a class file")
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
                pool[i] = _modified_utf8(data[off:off + length])
                off += length
            elif tag in (7, 8, 16, 19, 20):
                pool[i] = (tag, struct.unpack_from(">H", data, off)[0])
                off += 2
            elif tag == 15:
                off += 3
            elif tag in (9, 10, 11, 12):
                pool[i] = (tag, *struct.unpack_from(">HH", data, off))
                off += 4
            elif tag in (3, 4, 17, 18):
                off += 4
            elif tag in (5, 6):
                off += 8
                i += 1
            else:
                raise ValueError(f"unknown constant pool tag {tag}")
            i += 1

        def class_name(index):
            return pool[pool[index][1]]

        self.method_refs = []
        for entry in pool:
            if isinstance(entry, tuple) and entry[0] in _METHOD_REFS:
                _, cls, nat = entry
                _, name, desc = pool[nat]
                self.method_refs.append((class_name(cls), pool[name], pool[desc]))

        _, this_class, _, interfaces = struct.unpack_from(">HHHH", data, off)
        off += 8 + 2 * interfaces
        self.name = class_name(this_class)
        self.methods = []
        for member in ("fields", "methods"):
            (count,) = struct.unpack_from(">H", data, off)
            off += 2
            for _ in range(count):
                access, name, desc, attrs = struct.unpack_from(">HHHH", data, off)
                off += 8
                for _ in range(attrs):
                    _, length = struct.unpack_from(">HI", data, off)
                    off += 6 + length
                if member == "methods":
                    self.methods.append((access, pool[name], pool[desc]))


def jni_mangle(text):
    """JNI short-name escaping; each UTF-16 code unit escapes separately."""
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
            units = ch.encode("utf-16-be", "surrogatepass")
            for k in range(0, len(units), 2):
                out.append("_0%04x" % int.from_bytes(units[k:k + 2], "big"))
    return "".join(out)


def jni_symbols(cls, method, descriptor):
    """The short and long JNI export names for a native method."""
    short = f"Java_{jni_mangle(cls)}_{jni_mangle(method)}"
    args = jni_mangle(descriptor[1:descriptor.index(")")])
    return short, f"{short}__{args}"


def dynamic_symbols(path):
    """Defined symbols in an ELF shared library's .dynsym."""
    with open(path, "rb") as f:
        elf = f.read()
    if elf[:4] != b"\x7fELF":
        raise SystemExit(f"{path} is not an ELF file")
    is64 = elf[4] == 2
    end = "<" if elf[5] == 1 else ">"
    if is64:
        (shoff,) = struct.unpack_from(end + "Q", elf, 0x28)
        shentsize, shnum = struct.unpack_from(end + "HH", elf, 0x3A)
        sh_fmt, sym_fmt, sym_size = "IIQQQQIIQQ", "IBBHQQ", 24
    else:
        (shoff,) = struct.unpack_from(end + "I", elf, 0x20)
        shentsize, shnum = struct.unpack_from(end + "HH", elf, 0x2E)
        sh_fmt, sym_fmt, sym_size = "IIIIIIIIII", "IIIBBH", 16
    if shoff == 0 or shnum == 0:
        raise SystemExit(f"{path} has no ELF section headers; check the "
                         "unstripped library instead")
    sections = [struct.unpack_from(end + sh_fmt, elf, shoff + k * shentsize)
                for k in range(shnum)]
    dynsyms = [sh for sh in sections if sh[1] == 11]  # SHT_DYNSYM
    if not dynsyms:
        raise SystemExit(f"{path} has no .dynsym section")
    names = set()
    for sh in dynsyms:
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
