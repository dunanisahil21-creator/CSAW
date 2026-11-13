#!/usr/bin/env bash
# One-click: build and run the full simulation pipeline.
set -e
cd "$(dirname "$0")"
echo "==================== NORMAL OPERATION ===================="
make --no-print-directory normal
echo; echo "==================== TROJAN EXPLOIT ======================"
make --no-print-directory exploit
echo; echo "Done. (Run 'make keyrecover' to reproduce the key search; ~minutes.)"
