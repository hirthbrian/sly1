---
name: match-function
description: Match a single function in the sly1 matching decompilation — write C that compiles byte-identically to the original PS2 assembly. Use this whenever the user wants to decompile, match, port, or "work on" a named function; asks why their C isn't matching or why registers are shifted; wants to know what an unmatched function does; asks to pick up a new function to work on; or mentions INCLUDE_ASM, objdiff, a mangled name, or a .s file in asm/nonmatchings. Also use when starting a new translation unit by flipping a split in config/sly1.yaml. Prefer this over ad-hoc building and diffing, because the obvious commands (scripts/diff.sh) fail silently in non-interactive sessions and the two object trees spell symbols differently.
---

# Matching a function

The goal is not C that behaves like the original. It is C that this exact
compiler — ProDG `ee-gcc` 2.95.2 at `-O2 -G0 -ffast-math` — turns back into the
*identical* instruction stream. Semantically correct C that produces different
registers is not progress. The `sha1sum` at the end of `./scripts/build.sh` is
the only authority; everything else is a faster proxy for it.

## Orientation

Read the target assembly first, before writing any C:

```bash
cat asm/nonmatchings/P2/<module>/<MangledName>.s
```

`docs/mips_ps2_cheatsheet.md` is the reference — consult it rather than reasoning
from generic MIPS knowledge. The PS2-specific parts are what bite:

- **§5 delay slot** — the instruction after a jump or branch runs *before* the
  jump. Read it as if it came first, or you will misread every branch.
- **§13 calling convention** — 8 integer/pointer args in `$a0–$a7`, floats in
  `$f12–$f15`, and the two sets are **independent**. A float does not consume an
  `$a` register. Getting this wrong shifts every register in the diff, which
  reads like a broken body but is really a wrong signature.
- **§15** — `lq`/`sq` on `$s` registers is just the 128-bit prologue/epilogue
  save, not vector code.
- **§7** — each `lw`/`lwc1`/`lbu` offset is a struct field. If the function
  works on a type whose layout isn't known yet, use the `recover-struct` skill
  before trying to write the body.

## The loop

1. Put candidate C **below** the `INCLUDE_ASM` line, wrapped in
   `#ifdef SKIP_ASM … #endif`. The normal build keeps using the assembly while
   `obj/current` compiles your C, so a half-finished attempt never breaks the
   build.

2. Diff it:

   ```bash
   .claude/skills/match-function/scripts/fndiff.sh <Name>
   ```

   Add `--touch` if you edited anything under `include/` — `configure.py` emits
   no depfiles, so ninja will not rebuild the object for a header-only change
   and you will diff a stale object while your fix sits there working.
   Add `--no-build` to re-read the last build without recompiling.

   Do **not** use `./scripts/diff.sh` unless you have a real terminal. It drives
   objdiff's TUI and dies with `Device not configured (os error 6)` otherwise.

3. Iterate until the script prints `MATCH`.

4. Delete the `INCLUDE_ASM` line and the `#ifdef SKIP_ASM` / `#endif` wrapper so
   the real build uses your C.

5. Make sure the **mangled** name and address are in `config/symbol_addrs.txt`,
   grouped by file and sorted by address within a file. `fndiff.sh` tells you
   the mangled spelling when it differs from what's currently recorded.

6. `./scripts/build.sh` — the sha1 gate has the final word.

## Reading the diff

The script prints the target on the left and your C's output on the right, with
the address column stripped so an unrelated size change upstream doesn't mask
real differences. Relocations are shown, so a wrong callee appears as a changed
`R_MIPS_26` line rather than hiding behind an identical `jal 0`.

Interpretation, in the order worth checking:

- **Every register shifted by one, body otherwise identical** — the argument
  list is wrong. Re-check the float/int slot rule above before touching the body.
- **Registers shifted within the body only** — usually local declaration order.
  Reordering declarations is cheap to try and often the whole fix.
- **Right instructions, wrong order** — the compiler scheduled differently.
  Restructuring the expression (splitting a compound statement, introducing or
  removing a temporary) is the usual lever.
- **Extra or missing instructions around memory access** — a type width is wrong
  (`int` vs `short`, signed vs unsigned), or a struct field offset is off.

Resist reshaping the C into something unnatural to chase the last instruction.
If it matches on decomp.me but not locally, that's a toolchain discrepancy —
report it rather than contorting the source around it.

## Two failure modes that look like bugs but aren't

**`NOT STARTED` with a non-empty target.** `obj/current` compiles with
`-DSKIP_ASM`, so `INCLUDE_ASM` expands to nothing. If no C exists under the
stub yet, the function is simply absent from that object. Expected before you
start; suspicious after.

**A function with no `INCLUDE_ASM` stub always reports `MATCH`.** Once the stub
is deleted, both object trees compile the same C, so the comparison is vacuous.
It is not evidence of anything. Use `./scripts/build.sh` to confirm an already
integrated function still matches.

## Starting a new translation unit

Never create a `.c` by hand. Change the split in `config/sly1.yaml` from `asm`
to `c` and re-run `configure.py`, which generates the file with its
`INCLUDE_ASM` stubs. `config/readme.md` documents the split format.

## Code that lands

`docs/STYLEGUIDE.md` is authoritative. The essentials: 4-space indent, braces on
their own line, Hungarian-style names matching the original symbols (`p` pointer,
`n` int, `c` count, `f` flag, `d` float, `g_` global, `m_` member), `ALLCAPS`
structs and enums, `UpperCamelCase` functions, `lowerCamelCase` locals.

Doxygen comments go in the **header**, not the `.c`. Prefer the official symbol
names from the May 2002 prototype where known, and flag invented names with
`@note`.

Decompiler leftovers — `param_1`, `local_3c`, commented-out pseudo-C, a stray
`return;` closing a void function — are what the style guide holds up as the
counter-example. Clean them up before the code lands.
