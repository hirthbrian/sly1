#!/bin/bash
set -e

PROJECT_DIR="$(dirname "$0")/.."
ELF="$PROJECT_DIR/out/SCUS_971.98"

# Parse Arguments
if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [/path/to/game.iso]" >&2
    exit 1
fi

if [[ $# -eq 1 ]]; then
    ISO="$1"
else # Find any ISO in disc directory
    ISO=$(find "$PROJECT_DIR/disc" -maxdepth 1 -type f -iname "*.iso" -print -quit 2>/dev/null)
    if [[ -z "$ISO" ]]; then
        echo "Error: No ISO found in $PROJECT_DIR/disc" >&2
        exit 1
    fi
    echo "Using ISO: $(basename "$ISO")"
fi

# Verify Files
if [[ ! -f "$ISO" ]]; then
    echo "Error: ISO not found: $ISO" >&2
    exit 1
fi

if [[ ! -f "$ELF" ]]; then
    echo "Error: ELF not found: $ELF" >&2
    echo "Build the project first with: ./configure.py && ninja" >&2
    exit 1
fi

# Resolve full paths for sandboxed environments
ISO="$(realpath "$ISO")"
ELF="$(realpath "$ELF")"

find_pcsx2() {
    # Check system PATH
    if command -v pcsx2 &>/dev/null; then
        printf "pcsx2"
        return 0
    fi

    # Check macOS application bundles. Invoke the inner executable directly;
    # `open -a` would not pass the -elf/-nogui arguments through.
    if [[ "$(uname -s)" == "Darwin" ]]; then
        local app
        for app in "/Applications/PCSX2.app" "$HOME/Applications/PCSX2.app" \
                   "$PROJECT_DIR/tools/PCSX2.app"; do
            if [[ -x "$app/Contents/MacOS/PCSX2" ]]; then
                printf '%q' "$app/Contents/MacOS/PCSX2"
                return 0
            fi
        done
    fi

    # Check flatpak
    if command -v flatpak &>/dev/null && flatpak list --app 2>/dev/null | grep -q "net.pcsx2.PCSX2"; then
        printf "flatpak run net.pcsx2.PCSX2"
        return 0
    fi

    # Check for AppImage in tools directory
    local appimage=$(find "$PROJECT_DIR/tools" -maxdepth 1 -type f -iname "*pcsx2*.appimage" -executable -print -quit 2>/dev/null)
    if [[ -n "$appimage" ]]; then
        printf '%q' "$appimage"
        return 0
    fi

    # Check XDG Desktop entries
    local desktop_file=$(find ~/.local/share/applications /usr/share/applications /usr/local/share/applications \
        -maxdepth 1 -type f -iname "*pcsx2*.desktop" -print -quit 2>/dev/null)
    if [[ -n "$desktop_file" ]]; then
        # Extract executable path, stripping env vars and desktop file arguments
        local exec_line=$(grep -m1 "^Exec=" "$desktop_file" | \
            sed 's/^Exec=//' | \
            sed 's/^env //' | \
            sed 's/[A-Z_][A-Z0-9_]*=[^ ]* *//g' | \
            sed 's/ %.*//' | \
            awk '{print $1}')
        printf '%q' "$exec_line"
        return 0
    fi

    return 1
}

PCSX2=$(find_pcsx2)

if [[ -z "$PCSX2" ]]; then
    echo "Error: PCSX2 not found. Install it via:" >&2
    echo "  - System package manager (pcsx2)" >&2
    echo "  - macOS: install PCSX2.app to /Applications" >&2
    echo "  - Flatpak: flatpak install net.pcsx2.PCSX2" >&2
    echo "  - Download AppImage to $PROJECT_DIR/tools/" >&2
    exit 1
fi

run_verbose() {
    ( PS4=''; set -x; "$@" )
}

# Grant Flatpak Permissions
if [[ "$PCSX2" == "flatpak run"* ]]; then
    run_verbose flatpak override --user net.pcsx2.PCSX2 \
        --filesystem="$ISO":ro \
        --filesystem="$ELF":ro
fi

# Launch PCSX2
run_verbose $PCSX2 -elf "$ELF" -fastboot -nogui -- "$ISO"
