#!/usr/bin/env python3
"""Aggregate struct field accesses out of split assembly.

Every `lw $v0, 0x310($s0)` in the disassembly is one field read: offset 0x310,
four bytes wide. Collecting every such access across a module and sorting by
offset reconstructs the shape of the struct the module works on — which is the
mechanical half of struct recovery. Deciding what the fields *mean* is still
yours; this just makes sure you never miss one, and missing one silently
shifts every later field to the wrong offset.

Usage:
    offsets.py P2/difficulty                 # whole module
    offsets.py P2/difficulty --base a0       # only accesses off register $a0
    offsets.py P2/lo --min 0x300 --max 0x400 # narrow to a range
    offsets.py asm/nonmatchings/P2/sw/InitSw.s   # a single function

Output is a table of offset, widths seen, read/write counts, and the guessed
C type, plus a skeleton struct you can paste into a header and refine.
"""
import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

# mnemonic -> (size in bytes, candidate C type)
LOADS = {
    "lb":   (1, "char"),          "lbu":  (1, "unsigned char / byte"),
    "lh":   (2, "short"),         "lhu":  (2, "unsigned short"),
    "lw":   (4, "int / pointer"), "lwu":  (4, "unsigned int"),
    "ld":   (8, "long long"),     "lq":   (16, "128-bit (save/restore?)"),
    "lwc1": (4, "float"),         "ldc1": (8, "double"),
}
STORES = {
    "sb":   (1, "char"),          "sh":   (2, "short"),
    "sw":   (4, "int / pointer"), "sd":   (8, "long long"),
    "sq":   (16, "128-bit (save/restore?)"),
    "swc1": (4, "float"),         "sdc1": (8, "double"),
}
ALL = {**LOADS, **STORES}

# e.g.  lw         $2, 0x310($16)
INSN = re.compile(
    r"^\s*(?:/\*.*?\*/)?\s*"
    r"(?P<op>[a-z0-9]+)\s+"
    r"\$(?P<rt>[a-z0-9]+),\s*"
    r"(?P<off>-?(?:0x)?[0-9a-fA-F]+)\((?P<base>\$?[a-z0-9]+)\)"
)

# $29/$sp and $31/$ra accesses are the stack frame, not a struct field.
STACK_REGS = {"29", "sp", "$29", "$sp"}


def collect(paths, base_filter=None):
    hits = defaultdict(lambda: {"ops": defaultdict(int), "files": set()})
    for p in paths:
        try:
            text = p.read_text(errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            m = INSN.match(line)
            if not m:
                continue
            op = m.group("op")
            if op not in ALL:
                continue
            base = m.group("base").lstrip("$")
            if base in STACK_REGS:
                continue
            if base_filter and base != base_filter.lstrip("$"):
                continue
            off = m.group("off")
            try:
                val = int(off, 16) if off.startswith(("0x", "-0x")) else int(off)
            except ValueError:
                continue
            if val < 0:
                continue
            e = hits[val]
            e["ops"][op] += 1
            e["files"].add(p.stem)
    return hits


def resolve(target):
    p = Path(target)
    if p.is_file():
        return [p]
    if p.is_dir():
        return sorted(p.rglob("*.s"))
    guess = Path("asm/nonmatchings") / target
    if guess.is_dir():
        return sorted(guess.rglob("*.s"))
    return []


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("target", help="module (P2/difficulty), directory, or a single .s file")
    ap.add_argument("--base", help="only accesses off this register, e.g. a0 or 16")
    ap.add_argument("--min", dest="lo", default="0", help="lowest offset (hex ok)")
    ap.add_argument("--max", dest="hi", default=None, help="highest offset (hex ok)")
    args = ap.parse_args()

    paths = resolve(args.target)
    if not paths:
        print(f"no .s files for '{args.target}'.", file=sys.stderr)
        print("asm/ is generated — run ./scripts/checks.sh --report if it's missing.",
              file=sys.stderr)
        return 1

    lo = int(args.lo, 0)
    hi = int(args.hi, 0) if args.hi else None
    hits = collect(paths, args.base)
    offs = sorted(o for o in hits if o >= lo and (hi is None or o <= hi))

    if not offs:
        print(f"no struct-like accesses found in {len(paths)} file(s).")
        return 0

    print(f"# {args.target} — {len(paths)} function(s), {len(offs)} distinct offsets")
    if args.base:
        print(f"# filtered to base register ${args.base.lstrip('$')}")
    print()
    print(f"{'offset':>8}  {'dec':>6}  {'size':>4}  {'r/w':>7}  {'type':<24}  seen in")
    print("-" * 92)
    for off in offs:
        e = hits[off]
        sizes = {ALL[o][0] for o in e["ops"]}
        types = {ALL[o][1] for o in e["ops"]}
        reads = sum(c for o, c in e["ops"].items() if o in LOADS)
        writes = sum(c for o, c in e["ops"].items() if o in STORES)
        size = str(max(sizes)) if len(sizes) == 1 else "!" + "/".join(map(str, sorted(sizes)))
        typ = "/".join(sorted(types))
        who = ", ".join(sorted(e["files"])[:3])
        if len(e["files"]) > 3:
            who += f" (+{len(e['files']) - 3})"
        print(f"{hex(off):>8}  {off:>6}  {size:>4}  {reads:>3}r{writes:>3}w  {typ:<24}  {who}")

    print()
    print("# skeleton — field names are yours to work out; gaps mean unobserved")
    print("# padding or fields no function in this module touches.")
    print("struct UNKNOWN\n{")
    prev_end = 0
    for off in offs:
        e = hits[off]
        sizes = {ALL[o][0] for o in e["ops"]}
        size = max(sizes)
        if off < prev_end:
            print(f"    // NOTE 0x{off:x} overlaps the previous field — union, "
                  f"sub-struct, or a wrong width guess")
            continue
        if off > prev_end:
            print(f"    char pad_0x{prev_end:x}[0x{off - prev_end:x}];")
        ctype = {1: "char", 2: "short", 4: "int", 8: "long long", 16: "u_long128"}[size]
        if any(o in ("lwc1", "swc1") for o in e["ops"]):
            ctype = "float"
        elif any(o in ("ldc1", "sdc1") for o in e["ops"]):
            ctype = "double"
        print(f"    {ctype} field_0x{off:x};")
        prev_end = off + size
    print("};")
    print()
    print("# Reminders: base-class fields come first, so large offsets usually sit")
    print("# past an inherited LO/ALO/SO header. Check include/ before inventing a")
    print("# new struct — the type may already be declared with better names.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
