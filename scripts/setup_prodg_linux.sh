#!/bin/bash
# Backwards-compatible alias for setup_prodg.sh, which is no longer Linux-only.
exec "$(dirname "$0")/setup_prodg.sh" "$@"
