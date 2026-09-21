#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
install_dir="$HOME/.local/bin"
mkdir -p "$install_dir"
cp "$bin_dir/desktop-use" "$install_dir/desktop-use"
python3 scripts/sign-local.py "$install_dir/desktop-use"

printf 'Installed %s\n' "$install_dir/desktop-use"
