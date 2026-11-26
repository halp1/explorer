#!/bin/bash
# Packages build/Explorer.app into a styled drag-to-Applications disk image at build/Explorer.dmg.
set -euo pipefail

root=$(cd -P "$(dirname "$0")/.." && pwd)
app="$root/build/Explorer.app"
work="$root/build/dmg"
out="$root/build/Explorer.dmg"

[[ -d "$app" ]] || { echo "Missing $app, run make release first" >&2; exit 1; }
rm -rf "${work:?}" "$out"
mkdir -p "$work"

python3 -m venv "$work/venv"
"$work/venv/bin/pip" install --quiet --disable-pip-version-check 'dmgbuild==2.0.0'

swift "$root/scripts/make-dmg-background.swift" "$work"
tiffutil -cathidpicheck "$work/background.png" "$work/background@2x.png" -out "$work/background.tiff"

"$work/venv/bin/dmgbuild" -s "$root/scripts/dmg-settings.py" \
    -D app="$app" -D background="$work/background.tiff" \
    Explorer "$out"
hdiutil verify "$out"
echo "Built $out"
