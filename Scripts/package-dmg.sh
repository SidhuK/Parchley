#!/bin/zsh
set -euo pipefail

app="${1:?usage: package-dmg.sh /path/to/Parchley.app [output.dmg]}"
output="${2:-${app:h}/Parchley-unsigned.dmg}"
repo_root="${0:A:h:h}"
[[ -d "$app" ]] || { print -u2 "app bundle not found: $app"; exit 2; }

# Ad-hoc signing makes a local smoke artifact. Distribution still requires a
# Developer ID identity, notarization, and ticket stapling outside this script.
# Sign nested code first, then the app. Preserve the entitlements emitted by
# Xcode so the sandbox remains active in the local smoke artifact.
for runtime in "$app/Contents/Frameworks"/*.dylib; do
  [[ -f "$runtime" ]] && codesign --force --options runtime --sign - "$runtime"
done
codesign --force --options runtime --preserve-metadata=entitlements,requirements,flags --sign - "$app"
codesign --verify --deep --strict "$app"
"$repo_root/Scripts/verify-release.sh" "$app"
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/"
hdiutil create -volname Parchley -srcfolder "$stage" -format UDZO -ov "$output"
print "created local ad-hoc DMG: $output"
