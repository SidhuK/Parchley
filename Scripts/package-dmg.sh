#!/bin/zsh
set -euo pipefail

app="${1:?usage: package-dmg.sh /path/to/Parchley.app [output.dmg]}"
output="${2:-${app:h}/Parchley-unsigned.dmg}"
repo_root="${0:A:h:h}"
[[ -d "$app" ]] || { print -u2 "app bundle not found: $app"; exit 2; }
signing_identity="${PARCHLEY_SIGNING_IDENTITY:--}"
codesign_options=(--force --options runtime)
[[ "$signing_identity" == "-" ]] || codesign_options+=(--timestamp)

# Sign nested code first, then the app. Preserve the entitlements emitted by
# Xcode so the sandbox remains active in both local and distribution builds.
for runtime in "$app/Contents/Frameworks"/*.dylib; do
  [[ -f "$runtime" ]] && codesign "${codesign_options[@]}" --sign "$signing_identity" "$runtime"
done
codesign "${codesign_options[@]}" --preserve-metadata=entitlements,requirements,flags --sign "$signing_identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
"$repo_root/Scripts/verify-release.sh" "$app"
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/"
hdiutil create -volname Parchley -srcfolder "$stage" -format UDZO -ov "$output"
[[ "$signing_identity" == "-" ]] && print "created local ad-hoc DMG: $output" || print "created signed DMG: $output"
