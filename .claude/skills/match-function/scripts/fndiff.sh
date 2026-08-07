#!/bin/bash
# Per-function assembly diff that works without a TTY.
#
# scripts/diff.sh drives objdiff-cli's TUI, which dies with
# "Device not configured (os error 6)" when there's no terminal. This does the
# same job with objdump: disassemble one function out of obj/target and
# obj/current and diff the two listings.
#
# Usage: fndiff.sh <MangledName> [--touch] [--no-build]
#   --touch     rebuild the unit even if ninja thinks it's current. Needed
#               after editing a header, because configure.py emits no depfiles
#               and ninja will otherwise diff a stale object.
#   --no-build  skip configure+ninja and diff whatever is already in obj/.
set -euo pipefail

FUNC="${1:-}"
if [ -z "$FUNC" ]; then
    echo "usage: $0 <MangledName> [--touch] [--no-build]" >&2
    echo "note: names are mangled, e.g. OnDifficultyGameLoad__FP10DIFFICULTY" >&2
    exit 1
fi
shift

TOUCH=0
BUILD=1
for arg in "$@"; do
    case "$arg" in
        --touch)    TOUCH=1 ;;
        --no-build) BUILD=0 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

cd "$(dirname "$0")/../../../.."
ROOT="$PWD"

OBJDUMP="${OBJDUMP:-${CROSS:-mips-linux-gnu-}objdump}"
command -v "$OBJDUMP" >/dev/null 2>&1 || {
    echo "error: $OBJDUMP not found. Set CROSS or OBJDUMP." >&2; exit 1; }

if [ -z "${VIRTUAL_ENV:-}" ] && [ -f env/bin/activate ]; then
    # shellcheck disable=SC1091
    source env/bin/activate
fi

TMP="$(mktemp -d)"
TMPLOG="$TMP/build.log"
trap 'rm -rf "$TMP"' EXIT

NM="${NM:-${CROSS:-mips-linux-gnu-}nm}"

# A C++ mangled name is <base>__F<argtypes>. Both halves of the diff may spell
# the same function differently: obj/target takes its name from the .s (which
# is only mangled if config/symbol_addrs.txt says so), while obj/current always
# gets the mangled name the C++ frontend emits. Compare on the base name.
basename_of() { echo "${1%%__F*}"; }

# List defined text symbols, dropping objdiff's .NON_MATCHING aliases.
syms() {
    "$NM" --defined-only "$1" 2>/dev/null \
        | awk '$2 == "T" || $2 == "t" { print $3 }' \
        | grep -v '\.NON_MATCHING$' || true
}

# Find the symbol in $1 whose base name equals $2. Prefers an exact hit.
resolve_sym() {
    local obj="$1" want="$2" s
    for s in $(syms "$obj"); do
        [ "$s" = "$want" ] && { echo "$s"; return 0; }
    done
    local wantbase; wantbase="$(basename_of "$want")"
    for s in $(syms "$obj"); do
        [ "$(basename_of "$s")" = "$wantbase" ] && { echo "$s"; return 0; }
    done
    return 1
}

# Locate the object holding this function. obj/ is flat, so the basename of the
# .o maps back to src/P2/<name>.c or src/P2/splice/<name>.cpp.
find_obj() {
    local o
    for o in obj/target/*.o; do
        resolve_sym "$o" "$FUNC" >/dev/null 2>&1 && { echo "$o"; return 0; }
    done
    return 1
}

if [ "$BUILD" -eq 1 ]; then
    if [ "$TOUCH" -eq 1 ]; then
        # Only touch the unit we're about to diff, not all of src/ — a full
        # rebuild is 285 units and we rarely need it.
        if TARGET_OBJ="$(find_obj 2>/dev/null)"; then
            base="$(basename "$TARGET_OBJ" .o)"
            for cand in "src/P2/$base.c" "src/P2/splice/$base.cpp"; do
                [ -f "$cand" ] && touch "$cand" && echo "touched $cand"
            done
        fi
    fi
    # The fast path: reuse splat's cache and let ninja rebuild only what changed.
    # It fails if asm/ is stale or incomplete, because splat's .splache makes a
    # bare --objects a no-op and ninja then can't find the .s files the C
    # INCLUDE_ASMs reference. Surface that rather than swallowing it.
    if ! python3 configure.py --objects > "$TMPLOG" 2>&1 || ! ninja >> "$TMPLOG" 2>&1; then
        tail -30 "$TMPLOG" >&2
        echo >&2
        if grep -q "Can't open asm/\|No such file or directory" "$TMPLOG"; then
            echo "The asm/ tree is stale — splat cached a split that no longer matches" >&2
            echo "the sources. Rebuild it once with a clean reconfigure, then retry:" >&2
            echo "    python3 configure.py --clean --objects && ninja" >&2
        fi
        exit 1
    fi
fi

TARGET_OBJ="$(find_obj)" || {
    echo "error: no symbol '$FUNC' in obj/target/*.o" >&2
    echo "  - names must be MANGLED (see config/symbol_addrs.txt)" >&2
    echo "  - if the function is still an INCLUDE_ASM stub, that's expected only" >&2
    echo "    when its file is an 'asm' split in config/sly1.yaml" >&2
    exit 1
}
BASE_OBJ="obj/current/$(basename "$TARGET_OBJ")"
[ -f "$BASE_OBJ" ] || { echo "error: missing $BASE_OBJ" >&2; exit 1; }

TARGET_SYM="$(resolve_sym "$TARGET_OBJ" "$FUNC")"
if ! BASE_SYM="$(resolve_sym "$BASE_OBJ" "$FUNC")"; then
    BASE_SYM=""
fi

# Strip the leading address column: it shifts whenever an earlier function in
# the same object changes size, which would otherwise mask every real diff.
dump() {
    local obj="$1" sym="$2"
    [ -z "$sym" ] && return 0
    "$OBJDUMP" -dr --disassemble="$sym" "$obj" 2>/dev/null \
        | sed -e '1,/^[0-9a-f]* <'"$sym"'>:/d' \
              -e 's/^[[:space:]]*[0-9a-f]*:[[:space:]]*[0-9a-f]\{8\}[[:space:]]*//' \
              -e 's/[[:space:]]*$//' \
        | sed '/^$/d'
}

dump "$TARGET_OBJ" "$TARGET_SYM" > "$TMP/target.asm"
dump "$BASE_OBJ"   "$BASE_SYM"   > "$TMP/current.asm"

if [ ! -s "$TMP/target.asm" ]; then
    echo "error: '$FUNC' disassembled to nothing in $TARGET_OBJ" >&2
    exit 1
fi

t_lines=$(wc -l < "$TMP/target.asm" | tr -d ' ')
c_lines=$(wc -l < "$TMP/current.asm" | tr -d ' ')

echo "function : $FUNC"
echo "unit     : $(basename "$TARGET_OBJ" .o)  ($TARGET_OBJ vs $BASE_OBJ)"
echo "symbols  : target '$TARGET_SYM'  current '${BASE_SYM:-<absent>}'"
echo "size     : target ${t_lines} insns, current ${c_lines} insns"
if [ -n "$BASE_SYM" ] && [ "$TARGET_SYM" != "$BASE_SYM" ]; then
    echo
    echo "NOTE: the two objects spell this function differently. obj/target takes its"
    echo "name from the .s, so '$TARGET_SYM' is what config/symbol_addrs.txt"
    echo "currently says. The C++ frontend emits '$BASE_SYM'."
    echo "Once this matches, symbol_addrs.txt should carry the mangled spelling."
fi
echo

if [ ! -s "$TMP/current.asm" ]; then
    echo "NOT STARTED — '$FUNC' is absent from obj/current."
    echo
    echo "obj/current compiles with -DSKIP_ASM, so INCLUDE_ASM expands to nothing."
    echo "An empty result means no candidate C exists yet. Add it below the"
    echo "INCLUDE_ASM line inside an '#ifdef SKIP_ASM ... #endif' block, then rerun."
    echo
    echo "Target disassembly (${t_lines} instructions):"
    cat "$TMP/target.asm"
    exit 1
fi

if diff -q "$TMP/target.asm" "$TMP/current.asm" >/dev/null; then
    echo "MATCH — identical instruction stream."
    echo
    echo "Next: delete the INCLUDE_ASM line and the #ifdef SKIP_ASM wrapper, confirm"
    echo "the mangled name is in config/symbol_addrs.txt, then run ./scripts/build.sh"
    echo "so the sha1 gate has the final word."
    exit 0
fi

same=$( { diff --unchanged-group-format='%=' --old-group-format='' \
              --new-group-format='' --changed-group-format='' \
              "$TMP/target.asm" "$TMP/current.asm" 2>/dev/null || true; } \
        | wc -l | tr -d ' ')
denom=$(( t_lines > c_lines ? t_lines : c_lines ))
[ "$denom" -eq 0 ] && denom=1
echo "MISMATCH — ${same}/${denom} instructions in common (~$(( same * 100 / denom ))%)"
echo
echo "--- target (original)      +++ current (your C)"
{ diff -u "$TMP/target.asm" "$TMP/current.asm" || true; } | tail -n +3
exit 1
