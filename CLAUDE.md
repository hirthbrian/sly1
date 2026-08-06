# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this project is

A **matching decompilation** of _Sly Cooper and the Thievius Raccoonus_ (PS2, NTSC-U, `SCUS_971.98`, SHA1 `57dc305d…`). The goal is C/C++ source that compiles to **byte-identical** assembly. The build ends in a `sha1sum` check against `config/checksum.sha1`; if that fails, the change is wrong, not the checksum.

No original game code or assets live in this repo. The original ELF must be supplied by the user at `disc/SCUS_971.98` (gitignored) before anything can be built.

## Build environment (important)

- **Linux, macOS, or WSL** — not native Windows (the assembler doesn't work there). The compiler is ProDG `ee-gcc.exe` 2.95.2, a 32-bit **Windows** binary, run through a Win32 shim: `tools/wibo-i686` or `wine32` on Linux, `tools/wibo-macos` on macOS. Add `binutils-mips-linux-gnu` (Homebrew: `mips-linux-gnu-binutils`) and `ninja`.
- **On macOS the compiler runs under Rosetta 2**, which is how an x86*64 wibo executes 32-bit PE code. Apple Silicon Macs need `softwareupdate --install-rosetta`. Note this works only because \_macOS* Rosetta 2 supports 32-bit code segments — Docker's Rosetta-for-Linux does not (`invalid gdt selector index`), so containerized builds on Apple Silicon do not work.
- `configure.py` picks the toolchain by `sys.platform`; override with `CROSS` (binutils prefix), `WIBO` (Win32 shim command), or `CPP` (assembly preprocessor — macOS needs `cc -E -x assembler-with-cpp` because Apple's `cpp` rejects `#` line comments).
- Python deps come from `requirements.txt` into a venv at `env/`; the scripts `source env/bin/activate` themselves when `$VIRTUAL_ENV` is unset.
- `quickstart.sh` only knows apt and Homebrew. On Fedora/Arch/openSUSE the supported route is a Debian container via Distrobox (`distrobox create --name sly1-dev --init --image debian:latest`), which shares `$HOME` so the checkout is the same files — see [docs/DISTROBOX.md](docs/DISTROBOX.md). One catch: `run.sh` inside the container can't see a host-installed PCSX2.

## Commands

```bash
./scripts/quickstart.sh          # one-time setup (Debian/Ubuntu or macOS): deps, venv, compiler
./scripts/build.sh               # clean reconfigure + ninja + checksum verify
./scripts/checks.sh              # what CI runs; must pass before a PR merges
./scripts/diff.sh FuncName [Obj] # objdiff a single function against the original
./scripts/run.sh [game.iso]      # boot the built ELF in PCSX2
```

Underneath, `python3 configure.py` runs splat (splits the ELF into `asm/`, `assets/`) and writes `build.ninja`; `ninja` then builds. Useful flags:

- `--clean` / `--clean-only` — remove `asm/ assets/ obj/ out/ build.ninja` etc.
- `--skip-checksum` — for intentional non-matching changes (the ELF may not boot).
- `--objects` — build `obj/target` and `obj/current` (the latter with `-DSKIP_ASM`) and emit `objdiff.json` for objdiff.

## The matching workflow

Every not-yet-matched function is a placeholder in a `.c` file:

```c
INCLUDE_ASM("asm/nonmatchings/P2/difficulty", OnDifficultyWorldPreLoad);
```

`INCLUDE_ASM` (see [include_asm.h](include/include_asm.h)) inlines the split `.s` file — unless `SKIP_ASM`, `M2CTX`, or `PERMUTER` is defined, in which case it expands to nothing. So in-progress C is written **below** the macro inside `#ifdef SKIP_ASM … #endif`: the normal build keeps using the assembly, while `obj/current` compiles the C for diffing.

To work a function:

1. Put the candidate C under the `INCLUDE_ASM` in an `#ifdef SKIP_ASM` block.
2. `./scripts/diff.sh <mangled_name> [P2/file]` and iterate until 100%.
3. When it matches, delete the `INCLUDE_ASM` line and the `#ifdef`/`#endif` wrapper.
4. Ensure the **mangled** name and address are in `config/symbol_addrs.txt` (grouped by file, sorted by address within a file).

Names in `symbol_addrs.txt` and in `diff.sh` arguments are **mangled** (`OnDifficultyGameLoad__FP10DIFFICULTY`); source code uses the plain name. Sources compile with `-x c++` even for `.c` files, so C++ mangling applies everywhere.

**Never create a new `.c` file by hand.** New translation units are made by changing a split in `config/sly1.yaml` from `asm` to `c` and re-running `configure.py`, which generates the file with its `INCLUDE_ASM` stubs. `config/readme.md` explains the split format.

Common failures: `undefined reference` → wrong/missing `symbol_addrs.txt` entry or signature mismatch; `checksum failed` → the change does not match; `ninja: no work to do` from `diff.sh` → wrong function name.

[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) also documents **decomp.me** as the alternative to objdiff, used mainly to collaborate or ask for help: preset `PS2 > Sly Cooper and the Thievius Raccoonus`, "Diff label" = the mangled name (must match the `glabel` in the `.s`), "Target assembly" = the raw `.s` contents, "Context" = the structs/typedefs/prototypes the function needs, and `-g3` under Options → Debug information to see source line numbers. A function that matches on decomp.me but fails locally is a toolchain discrepancy — report it rather than reshaping the C around it.

## Reading the assembly

[docs/mips_ps2_cheatsheet.md](docs/mips_ps2_cheatsheet.md) is the reference for EE assembly, name mangling, and the engine's vocabulary. Consult it rather than reasoning from generic MIPS knowledge; the PS2-specific parts are what usually bite:

- **Delay slot** — the instruction after any jump or branch executes _before_ the jump. Read it as if it came first (§5).
- **Calling convention** (§13) — up to 8 integer/pointer args in `$a0–$a7` (`$4–$7`, `$8–$11`; the `$a4–$a7` extension is EE-specific), floats in `$f12–$f15`. Float and integer args have **separate** slots, so a float does not consume an `$a` register — getting this wrong is the usual cause of "shifted register" diffs.
- **`lq`/`sq` on `$s` registers** is just the 128-bit save/restore in the prologue/epilogue, not vector code; real VU access is `LQC2`/`SQC2` (§15).
- **Mangling** (§6) — `Fv`/`Fi`/`Ff` for arg types, `P` for pointer, `10CLOCK`-style length-prefixed struct names, `T<n>` to repeat the n-th type. `c++filt` decodes them.
- **Struct recovery** (§7) — each `lw`/`lwc1`/`lbu` offset is a field; sort by offset, take the type from the load width, and remember base-class fields come first.
- **§16 is an engine lexicon**: each P2 module mapped to its central type and key functions (`SW`/`LO`/`ALO`/`SO` object hierarchy, the `AC*` animation curves, `JT` for Sly's physics, the `splice/` `CRef`/`CPair`/`CFrame` runtime, and so on). Useful for orienting in an unfamiliar file, but it is a hand-maintained summary — verify layouts against `include/` before relying on them.
- Modules present in the May 2002 prototype but cut from the release (`cycle.c`, `hg.c`, `stepski.c`, `rope.c`, `sc.c`, `mouthgame.c`, debug menu) show up in Ghidra with no `.s` in this repo — don't go looking for them.

## Layout

- `src/P2/` — engine sources (`.c`, ~160 files); `src/P2/splice/` — the game's scripting engine (`.cpp`), tracked as its own progress category.
- `include/` — engine headers, with `sce/`, `sdk/`, `gcc/`, `lib/`, `splice/` subdirs. Include paths are `-Iinclude -isystem include/sdk/ee -isystem include/gcc`.
- `config/` — splat config (`sly1.yaml`), `symbol_addrs.txt`, `checksum.sha1`.
- `scripts/`, `tools/` (objdiff CLI, CodeMatcher — note the CodeMatcher workflow is commented out of the contributing guide and is not the current path).
- `docs/` — [CONTRIBUTING.md](docs/CONTRIBUTING.md) (find a function → match it → integrate it → PR), [STYLEGUIDE.md](docs/STYLEGUIDE.md) (naming, formatting, Doxygen), [mips_ps2_cheatsheet.md](docs/mips_ps2_cheatsheet.md) (EE asm, mangling, engine lexicon), [DISTROBOX.md](docs/DISTROBOX.md) (non-Debian Linux setup), [BEGINNERSGUIDE.md](docs/BEGINNERSGUIDE.md) (plain git walkthrough for newcomers).
- `reference/` — hand-written, **non-building** sources kept only as a starting point for unmatched files. Never wire these into the build; treat their struct layouts as unverified.
- Generated (gitignored): `asm/`, `assets/`, `obj/`, `out/`, `build.ninja`, `objdiff.json`, `env/`, `tools/cc/`.

## Code conventions

Full rules in [docs/STYLEGUIDE.md](docs/STYLEGUIDE.md); the essentials:

- Indent 4 spaces (never tabs), braces on their own line, no trailing whitespace, file ends in one blank line, lines 80–100 chars at most.
- Hungarian-style naming matching the original symbols. Type prefixes: `p` pointer, `n` int, `c` count, `f` flag, `l` long, `d` float, `ch` char, `b` byte, `u` unsigned, `z` zero-terminated string, `C` class. Scope prefixes: `g_` global, `m_` class member, `s_` static member. They combine — `g_pgsCur`, `m_cbBulkData`, `chzBuffer`.
- `ALLCAPS` structs/enums, `UpperCamelCase` functions/classes/enum values, `lowerCamelCase` locals/params/members.
- Prefer the official symbol names from the [May 19 2002 prototype](<https://hiddenpalace.org/Sly_Cooper_and_the_Thievius_Raccoonus_(May_19,_2002_prototype)>) when known; otherwise pick a clear descriptive name in the same style. That prototype's debug symbols are also where mangled names for `symbol_addrs.txt` come from.
- Doxygen comments (`@file`, `@brief`, `@details`, `@param`, `@return`/`@retval`, `@todo`, `@note`) — function/struct docs go in the **header**, file comment at the top of each file before the includes. Document every param and return value even when obvious. Use `@note` to flag names that aren't official. These feed the docs site at [theonlyzac.github.io/sly1](https://theonlyzac.github.io/sly1).
- The style guide's counter-example is decompiler output left as-is — `param_1`/`local_3c` names, commented-out pseudo-C, a stray `return;` closing a void function, a one-line comment where a Doxygen block belongs. Clean all of that up before the code lands.

## Gotchas

- `configure.py` contains a `PROBLEMATIC_FUNCS` set and rewrites branch instructions to raw `.word` opcodes in those `.s` files to dodge an assembler short-loop bug. Add to that set if a newly split function hits the same issue; disable with `-noloop` when debugging it.
- Matching is sensitive to compiler flags (`-O2 -G0 -ffast-math`); don't add per-file flags or reorder includes casually — either can change codegen.
- Register allocation off by one across the whole diff usually means the argument list is wrong (see the float/int slot rule above), not that the body is wrong. Shifted registers _within_ a body are typically local declaration order.
- The two things review actually gates on are that it compiles cleanly and that the ELF matches; reviewers fix small typos and style themselves. It's a volunteer project — questions go to the [Discord](https://discord.gg/2GSXcEzPJA) (`#sly-research`) or a GitHub issue.
