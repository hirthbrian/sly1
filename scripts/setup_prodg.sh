#!/bin/bash
# Sets up the ProDG compilers + SCE Runtime Library to build the project.
# The payload is Windows binaries, so this works on any host that can run
# them through wibo or wine.
set -e

PROJECT_DIR="$(dirname "$0")/.."
TOOLS_DIR="$PROJECT_DIR/tools"
DOWNLOAD_URL="https://github.com/TheOnlyZac/compilers/releases/download/ee-gcc2.95.2-SN-v2.73a/ee-gcc2.95.2-SN-v2.73a.tar.gz"

echo "Downloading compiler..."
if command -v curl &>/dev/null; then
	curl -fsSL "$DOWNLOAD_URL" | tar -xz -C "$TOOLS_DIR"
elif command -v wget &>/dev/null; then
	wget -q -O - "$DOWNLOAD_URL" | tar -xz -C "$TOOLS_DIR"
else
	echo "Error: neither curl nor wget is available" >&2
	exit 1
fi
echo "ProDG setup complete!"
