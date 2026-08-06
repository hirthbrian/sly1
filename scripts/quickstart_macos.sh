#!/bin/bash
# macOS equivalent of quickstart.sh. Invoked automatically by that script on
# Darwin hosts; you can also run it directly.
set -e

ISO_ARG="$1"
PROJECT_DIR="$(dirname "$0")/.."
DISC_DIR="$PROJECT_DIR/disc"
TOOLS_DIR="$PROJECT_DIR/tools"
WIBO_URL="https://github.com/decompals/wibo/releases/download/1.0.0/wibo-macos"

### Check Prerequisites ###

if ! command -v brew &>/dev/null; then
	echo "Error: Homebrew is required. Install it from https://brew.sh" >&2
	exit 1
fi

# The compiler is a 32-bit Windows binary. wibo runs it through Rosetta 2,
# which is not installed by default on Apple Silicon.
if [ "$(uname -m)" = "arm64" ] && ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
	echo "Error: Rosetta 2 is required to run the compiler." >&2
	echo "Install it with: softwareupdate --install-rosetta --agree-to-license" >&2
	exit 1
fi

# If no ISO specified, look for one in the disc directory
if [ -z "$ISO_ARG" ] && [ ! -f "$PROJECT_DIR/disc/SCUS_971.98" ]; then
	echo "No ISO file specified, looking in disc directory..."
	ISO_FILES=("$DISC_DIR"/*.iso)
	if [ -f "${ISO_FILES[0]}" ]; then
		ISO_ARG="${ISO_FILES[0]}"
		echo "Found ISO: $(basename "$ISO_ARG")"
	else
		echo "No ISO found in disc directory. Skipping executable extraction."
	fi
fi

# If ISO is specified, validate it
if [ -n "$ISO_ARG" ]; then
	if [ ! -f "$ISO_ARG" ]; then
		echo "Error: ISO file not found: $ISO_ARG" >&2
		exit 1
	fi
	ISO_ARG="$(realpath "$ISO_ARG")"
fi

### Install Dependencies ###

# bsdtar ships with macOS, so libarchive is not needed for ISO extraction.
echo "Installing dependencies..."
brew install -q ninja mips-linux-gnu-binutils

### Download Wibo ###

WIBO_PATH="$TOOLS_DIR/wibo-macos"
echo "Downloading Wibo..."
mkdir -p "$TOOLS_DIR"
if curl -fsSL -o "$WIBO_PATH" "$WIBO_URL"; then
	chmod +x "$WIBO_PATH"
	# Clear the quarantine flag in case it was set by a browser download.
	xattr -d com.apple.quarantine "$WIBO_PATH" 2>/dev/null || true
else
	echo "Error: Wibo download failed. It is required to run the compiler." >&2
	exit 1
fi

pushd $PROJECT_DIR > /dev/null
trap "popd > /dev/null" EXIT

### Set up Python virtual environment ###

echo "Setting up Python virtual environment..."
python3 -m venv env
source env/bin/activate
echo "Installing Python packages..."
pip install -q -U -r requirements.txt

### Download ProDG compilers and runtimes ###

echo "Starting ProDG setup script..."
./scripts/setup_prodg.sh

### Extract ELF ###

if [ -n "$ISO_ARG" ]; then
	echo "Extracting executable from ISO..."
	./scripts/extract_elf.sh "$ISO_ARG"
fi

popd > /dev/null
trap - EXIT

### Final Instructions ###

echo ""
echo "Quickstart complete!"
echo ""
if [ ! -f "$PROJECT_DIR/disc/SCUS_971.98" ]; then
	echo "Copy SCUS_971.98 from your copy of the game to the 'disc' directory of this project."
fi
echo "To build the project, run '$(dirname "$0")/build.sh'"
