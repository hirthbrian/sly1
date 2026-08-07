---
name: verify-build
description: Build the sly1 decompilation and verify nothing regressed — run the checksum gate, measure match progress, and prove a change didn't break previously-matching functions. Use whenever the user asks to build, rebuild, run the checks, check progress or percentages, confirm the ELF still matches, prepare or sanity-check a PR, or asks "did I break anything". Also use when a build fails confusingly, when ninja reports "no work to do" after an edit, or when asm/ files appear to be missing. Prefer this over running configure.py and ninja ad hoc, because the caching behaviour produces silent false results.
---

# Building and verifying

Three questions, three different commands. Reaching for the wrong one is the
usual source of confusion.

| Question | Command |
|---|---|
| Does the ELF still match the original? | `./scripts/build.sh` |
| Did anything regress, and where do we stand? | `./scripts/checks.sh --report` |
| Is *this one function* matching yet? | the `match-function` skill's `fndiff.sh` |

`./scripts/checks.sh` is what CI runs and what a PR must pass.

## The two caching traps

Both produce a confident, wrong answer rather than an error, so they are worth
knowing before you trust any result.

**Ninja does not see header changes.** `configure.py` generates no depfiles, so
editing anything under `include/` leaves ninja reporting `ninja: no work to do`
while it happily diffs objects built from the old header. `touch` the affected
sources before building, or pass `--touch` to `fndiff.sh`, which does it for the
unit it is diffing.

**A bare `configure.py --objects` will not repair a stale `asm/` tree.** Splat
caches its split in `.splache` and reports something like `0 split, 161 cached`.
If the tree on disk is missing `.s` files that the sources still reference, the
build fails with `Can't open asm/nonmatchings/...` even though the symbols are
present in `config/symbol_addrs.txt`. The fix is a clean reconfigure, which is
why `checks.sh` always passes `--clean`:

```bash
python3 configure.py --clean --objects && ninja
```

This costs a full rebuild of all 285 units, so it isn't the inner-loop command —
but it is the right first move whenever the build fails in a way that doesn't
correspond to a change you made.

## Measuring progress

`checks.sh --report` writes a gitignored `report.json`. Summarise it with:

```bash
python3 scripts/check_progress.py
```

which prints perfect-match and fuzzy-match percentages for the Engine and Splice
categories along with matched-function counts.

**`report.json` is per-unit, not per-function.** Each entry carries a
`fuzzy_match_percent` for a whole translation unit and its sections; there is no
per-function breakdown, and `objdiff-cli report generate` has no flag to add one.
For a single function, disassemble it out of both object trees — that is what
`fndiff.sh` does.

## Proving no regression

The useful property of `report.json` is that it is cheap to regenerate and free
to diff. Before a risky change:

```bash
./scripts/checks.sh --report && cp report.json /tmp/report-before.json
```

After, regenerate and compare unit percentages. A unit that dropped is a
regression worth explaining; the aggregate percentage alone can hide one unit
falling while another rises.

The sha1 check in `./scripts/build.sh` remains the final word. It works fine
non-interactively and does not care about any of the caching subtleties above —
if it passes, the change is correct.

## When a match is intentionally not expected

`configure.py --skip-checksum` builds without the gate, for deliberately
non-matching work. The resulting ELF may not boot. Don't leave this on when
reporting whether something matches.

## Reporting results

State what actually happened. If the checksum failed, say so and show the
output; if a unit regressed, name it. A build that fails is information about
the change, not about the checksum — CLAUDE.md's rule is that if the sha1 check
fails, the change is wrong, not the checksum.
