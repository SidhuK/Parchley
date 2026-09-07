#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
app="${1:?usage: verify-release.sh /path/to/Parchley.app}"
frameworks="$app/Contents/Frameworks"
resources="$app/Contents/Resources"

[[ -d "$app/Contents/MacOS" ]] || { print -u2 "invalid app bundle: $app"; exit 2; }
for file in libparchley_ffi.dylib libpdfium.dylib libonnxruntime.dylib; do
  [[ -f "$frameworks/$file" ]] || { print -u2 "missing bundled runtime: $file"; exit 2; }
  [[ "$(lipo -archs "$frameworks/$file")" == *arm64* ]] || { print -u2 "runtime is not arm64: $file"; exit 2; }
  codesign --verify --strict "$frameworks/$file" || { print -u2 "unsigned or invalid runtime: $file"; exit 2; }
done
otool -L "$frameworks/libparchley_ffi.dylib" | rg -q '@rpath/libparchley_ffi.dylib' || { print -u2 "bridge install name is not @rpath"; exit 2; }
otool -L "$frameworks/libpdfium.dylib" | rg -q 'libpdfium.dylib' || { print -u2 "PDFium load metadata is missing"; exit 2; }
otool -L "$frameworks/libonnxruntime.dylib" | rg -q 'libonnxruntime.dylib' || { print -u2 "ONNX Runtime load metadata is missing"; exit 2; }

manifest="$repo_root/Vendor/Manifests/pp-ocrv6-small.json"
[[ -f "$manifest" ]] || { print -u2 "missing model manifest"; exit 2; }
command -v jq >/dev/null || { print -u2 "jq is required to verify the model manifest"; exit 2; }
while IFS=$'\t' read -r name bytes sha; do
  [[ -n "$name" && "$bytes" -gt 0 && ${#sha} -eq 64 ]] || { print -u2 "invalid model manifest entry: $name"; exit 2; }
done < <(jq -r '.artifacts[] | [.name, .bytes, .sha256] | @tsv' "$manifest")
codesign --verify --deep --strict "$app"
print "verified arm64 OCR release bundle: $app"
