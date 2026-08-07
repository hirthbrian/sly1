---
name: recover-struct
description: Reconstruct a struct's field layout from PS2 assembly in the sly1 decompilation — turn raw offsets like 0x310 into named, typed C fields. Use whenever the user asks what a struct looks like, what lives at some offset, what type a field is, or why a struct's fields seem shifted; when a function can't be matched because the type it operates on is unknown or half-known; when working on a header in include/ that still has field_0x-style placeholders; or when adding a new type for a module that doesn't have one yet. Also use when loads and stores in a .s file need to be turned into field accesses.
---

# Recovering a struct

Compiling erases every field name and type. What survives is arithmetic: a
`lw $v0, 0x310($s0)` says only "read four bytes, 784 into whatever `$s0` points
at." Recovering the struct means collecting every such access, sorting by
offset, and inferring types from the load widths.

The collection half is mechanical and worth automating — missing a single field
silently shifts every later field to the wrong offset and breaks every function
that touches the type. The naming half is judgement and stays yours.

## Gather the accesses

```bash
python3 .claude/skills/recover-struct/scripts/offsets.py P2/difficulty
```

Also accepts a directory, a single `.s` file, `--base a0` to restrict to one
base register, and `--min`/`--max` to narrow the offset range. It prints a table
of offset, width, read/write counts, inferred type, and which functions touch
each field — then a paste-able skeleton struct.

Stack accesses off `$sp`/`$29` are excluded; those are the frame, not fields.

## Infer the types

The instruction width is the strongest signal, and the coprocessor tells you
float from int for free:

| Instruction | Size | Type |
|---|---|---|
| `lb` / `sb` | 1 | `char` |
| `lbu` | 1 | `unsigned char`, often a byte flag |
| `lh` / `lhu` / `sh` | 2 | `short` / `unsigned short` |
| `lw` / `sw` | 4 | `int`, or a pointer |
| `lwc1` / `swc1` | 4 | `float` — coprocessor 1, so never an int |
| `ld` / `sd` | 8 | `long long` |
| `ldc1` / `sdc1` | 8 | `double` |
| `lq` / `sq` | 16 | 128-bit; off `$sp` it's the prologue save, not a field |

Distinguishing `int` from a pointer takes context: if the loaded value is
immediately used as a base for another load, it's a pointer. If it feeds a
comparison against a small constant, it's more likely an int or enum.

Read `docs/mips_ps2_cheatsheet.md` §7 for the worked version of this, and §0C
for the alignment rules that explain gaps — an 8-byte field can't start at a
4-byte-aligned offset, so padding appears whether or not a field is there.

## Interpreting gaps and collisions

A gap means nothing in the scanned scope touched those bytes. It could be
padding, or a field only used by a module you didn't scan. Widen the scan before
declaring it padding — scanning a single function almost always underreports.

An overlap (the script flags these) means one of three things: a union, a nested
sub-struct, or a wrong width guess. Check whether the smaller access is reading
one byte out of a word-sized flags field — that pattern is common.

## Inheritance comes first

The engine's object hierarchy is `SW` → `LO` → `ALO` → `SO`, implemented as
plain field stacking: an `ALO` is an `LO`'s fields followed by its own. So a
large offset like `0x310` usually sits past several hundred bytes of inherited
base-class header, and the field you're recovering may belong to the *base*
type, not the one you're looking at.

Before inventing a new struct, check `include/` — the type may already be
declared with better names, and the offset you're chasing may already have one.
Cross-check the total size against how the type is allocated.

## Landing the result

Structs and their Doxygen comments live in the header, not the `.c`. Keep
placeholder fields for offsets you've confirmed but can't name yet, following
the convention already in the tree (`field17_0x3c`, `unk_lm_0x8`) — these record
real knowledge about width and position, and dropping them would shift
everything after. Name what you can, prefer official names from the May 2002
prototype where known, and mark invented names with `@note`.

Changing a struct changes codegen for every file that includes it, so re-run
`./scripts/checks.sh --report` afterwards and compare against a saved report to
confirm no previously-matching function regressed. Remember that ninja will not
rebuild on a header-only change by itself — see the `verify-build` skill.
