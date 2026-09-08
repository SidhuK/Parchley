#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
app="${1:?usage: verify-release.sh /path/to/Parchley.app}"
frameworks="$app/Contents/Frameworks"
resources="$app/Contents/Resources"

for tool in codesign jq lipo otool plutil rg; do
  command -v "$tool" >/dev/null || { print -u2 "required release-check tool is missing: $tool"; exit 2; }
done

[[ -d "$app" && "$app" == *.app ]] || { print -u2 "invalid app bundle: $app"; exit 2; }
[[ -x "$app/Contents/MacOS/Parchley" ]] || { print -u2 "missing app executable"; exit 2; }
[[ -f "$app/Contents/Info.plist" ]] || { print -u2 "missing app Info.plist"; exit 2; }
plutil -lint "$app/Contents/Info.plist" >/dev/null || { print -u2 "invalid app Info.plist"; exit 2; }
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")" == "com.karatsidhu.Parchley" ]] || {
  print -u2 "unexpected bundle identifier"
  exit 2
}
[[ -d "$frameworks" ]] || { print -u2 "missing Frameworks directory"; exit 2; }
[[ -d "$resources" ]] || { print -u2 "missing Resources directory"; exit 2; }
for license in Parchley-acknowledgements.txt ACKNOWLEDGEMENTS.txt PDFium-LICENSE ONNXRuntime-LICENSE ONNXRuntime-ThirdPartyNotices.txt; do
  [[ -s "$resources/$license" ]] || { print -u2 "missing third-party notice: $license"; exit 2; }
done

for file in libparchley_ffi.dylib libpdfium.dylib libonnxruntime.dylib; do
  [[ -f "$frameworks/$file" ]] || { print -u2 "missing bundled runtime: $file"; exit 2; }
  [[ "$(lipo -archs "$frameworks/$file")" == *arm64* ]] || { print -u2 "runtime is not arm64: $file"; exit 2; }
  codesign --verify --strict "$frameworks/$file" || { print -u2 "unsigned or invalid runtime: $file"; exit 2; }
done
otool -L "$frameworks/libparchley_ffi.dylib" | rg -q '@rpath/libparchley_ffi.dylib' || { print -u2 "bridge install name is not @rpath"; exit 2; }
otool -L "$frameworks/libpdfium.dylib" | rg -q 'libpdfium.dylib' || { print -u2 "PDFium load metadata is missing"; exit 2; }
otool -L "$frameworks/libonnxruntime.dylib" | rg -q 'libonnxruntime.dylib' || { print -u2 "ONNX Runtime load metadata is missing"; exit 2; }

signature="$(codesign -dv --verbose=4 "$app" 2>&1)"
print -r -- "$signature" | rg -q 'flags=.*runtime' || { print -u2 "app is not signed with the hardened runtime"; exit 2; }

manifest="$repo_root/Vendor/Manifests/pp-ocrv6-small.json"
[[ -f "$manifest" ]] || { print -u2 "missing model manifest"; exit 2; }
runtime_manifest="$resources/macos-arm64-runtime.json"
provenance="$resources/NativeRuntime-PROVENANCE.json"
[[ -f "$runtime_manifest" ]] || { print -u2 "missing native runtime manifest"; exit 2; }
[[ -f "$provenance" ]] || { print -u2 "missing native runtime provenance"; exit 2; }
jq -e '
  .schema_version == 1 and
  .platform == "macos-arm64" and
  (.pdfium.bytes | type == "number" and . > 0) and
  (.onnx_runtime.bytes | type == "number" and . > 0) and
  (.pdfium.sha256 | test("^[0-9a-fA-F]{64}$")) and
  (.onnx_runtime.sha256 | test("^[0-9a-fA-F]{64}$"))
' "$runtime_manifest" >/dev/null || { print -u2 "invalid native runtime manifest"; exit 2; }
jq -e '
  .schema_version == 1 and
  .platform == "macos-arm64" and
  (.artifacts | length == 2) and
  all(.artifacts[]; (.name | IN("libpdfium.dylib", "libonnxruntime.dylib"))) and
  all(.artifacts[]; (.archive_bytes | type == "number" and . > 0)) and
  all(.artifacts[]; (.archive_sha256 | test("^[0-9a-fA-F]{64}$")))
' "$provenance" >/dev/null || { print -u2 "invalid native runtime provenance"; exit 2; }
jq -e '
  ([.artifacts[].name] | unique | length) == 2
' "$provenance" >/dev/null || { print -u2 "native runtime provenance contains duplicate names"; exit 2; }
for key in pdfium onnx_runtime; do
  name="$(jq -r --arg key "$key" 'if $key == "pdfium" then "libpdfium.dylib" else "libonnxruntime.dylib" end' <<< '{}')"
  jq -e --arg key "$key" --arg name "$name" --slurpfile provenance "$provenance" '
    .[$key] as $approved |
    ($provenance[0].artifacts[] | select(.name == $name)) as $actual |
    $actual.source_url == $approved.url and
    $actual.archive_bytes == $approved.bytes and
    ($actual.archive_sha256 | ascii_downcase) == ($approved.sha256 | ascii_downcase)
  ' "$runtime_manifest" >/dev/null || { print -u2 "runtime provenance does not match approved manifest: $name"; exit 2; }
done
jq -e '
  .schema_version == 1 and
  (.artifacts | length > 0) and
  all(.artifacts[]; (.name | type == "string" and length > 0 and (contains("/") | not))) and
  all(.artifacts[]; (.bytes | type == "number" and . > 0)) and
  all(.artifacts[]; (.sha256 | test("^[0-9a-fA-F]{64}$")))
' "$manifest" >/dev/null || { print -u2 "invalid model manifest"; exit 2; }
while IFS=$'\t' read -r name bytes sha; do
  [[ -n "$name" && "$name" != */* && "$bytes" -gt 0 && ${#sha} -eq 64 ]] || { print -u2 "invalid model manifest entry: $name"; exit 2; }
done < <(jq -r '.artifacts[] | [.name, .bytes, .sha256] | @tsv' "$manifest")
codesign --verify --deep --strict "$app"
print "verified arm64 OCR release bundle: $app"
