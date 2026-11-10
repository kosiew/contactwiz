#!/bin/zsh
# Rebuilds ContactWiz and installs it, replacing any earlier copy.
# Usage: scripts/install_app.sh [destination-folder]   (default: /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

destination="${1:-/Applications}"
target="$destination/ContactWiz.app"

if [[ ! -d "$destination" || ! -w "$destination" ]]; then
  echo "Can't write to $destination." >&2
  exit 1
fi

scripts/build-app.sh

# Stop only the copy being replaced, not one running from another location.
pkill -f "^$target/Contents/MacOS/ContactWiz" || true

# Copy beside the target first, so a failed copy leaves the old install intact.
staging="$destination/.ContactWiz.app.installing"
rm -rf "$staging"
trap 'rm -rf "$staging"' EXIT
ditto build/ContactWiz.app "$staging"
rm -rf "$target"
mv "$staging" "$target"

echo "Installed $target"
