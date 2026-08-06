#!/bin/bash
set -e

# macOS installs its dependencies with Homebrew rather than apt, so hand off to
# the platform-specific script and leave the Debian path below untouched.
if [ "$(uname -s)" = "Darwin" ]; then
	exec "$(dirname "$0")/quickstart_macos.sh" "$@"
fi

### Install Dependencies ###

PACKAGES="binutils-mips-linux-gnu ninja-build python3 python3-pip python3-venv"
ISO_ARG="$1"
PROJECT_DIR="$(dirname "$0")/.."
DISC_DIR="$PROJECT_DIR/disc"
TOOLS_DIR="$PROJECT_DIR/tools"
WIBO_URL="https://github.com/decompals/wibo/releases/download/1.0.0/wibo-i686"

# If no ISO specified, look for one in the disc directory
if [ -z "$ISO_ARG" ] && [ ! -f $PROJECT_DIR/disc/SCUS_971.98 ]; then
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
    PACKAGES="$PACKAGES libarchive-tools"
fi

# Download Wibo
WIBO_PATH="$TOOLS_DIR/wibo-i686"
echo "Downloading Wibo..."
mkdir -p "$TOOLS_DIR"
if wget -q -O "$WIBO_PATH" "$WIBO_URL"; then
	chmod +x "$WIBO_PATH"
else
	echo "Wibo download failed, adding wine32 to dependencies instead..."
	PACKAGES="$PACKAGES wine32"
fi

# Install missing dependencies
if ! sudo -n true 2>/dev/null; then
    echo "Root privileges are required to install dependencies. Please enter your password."
fi

if ! sudo -v; then
    echo "Error: Unable to obtain root privileges" >&2
    exit 1
fi

echo "Adding i386 architecture support..."
sudo dpkg --add-architecture i386

echo "Updating package lists..."
sudo apt-get update -qq > /dev/null

echo "Dependencies: $PACKAGES"
echo "Installing missing dependencies..."
sudo apt-get install -y -qq $PACKAGES > /dev/null

pushd $PROJECT_DIR > /dev/null
trap "popd > /dev/null" EXIT

# Set up Python virtual environment
echo "Setting up Python virtual environment..."
python3 -m venv env
source env/bin/activate
echo "Installing Python packages..."
pip install -q -U -r requirements.txt

### Download ProDG compilers and runtimes ###

echo "Starting ProDG setup script..."
./scripts/setup_prodg.sh

## Extract ELF ###

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
if [ ! -f $PROJECT_DIR/disc/SCUS_971.98 ]; then
    echo "Copy SCUS_971.98 from your copy of the game to the 'disc' directory of this project."
fi
echo "To build the project, run '$(dirname "$0")/build.sh'"
