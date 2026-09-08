#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
asset_root="${PARCHLEY_ASSET_DIR:-$repo_root/Vendor/Native/macos-arm64}"
mkdir -p "$asset_root"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for tool in curl lipo shasum stat tar; do
  command -v "$tool" >/dev/null || { print -u2 "required tool is missing: $tool"; exit 2; }
done

fetch() {
  local url="$1" name="$2" expected_bytes="$3" expected_sha="$4"
  curl -L --fail --silent --show-error --connect-timeout 20 -o "$tmp/$name" "$url"
  [[ "$(stat -f '%z' "$tmp/$name")" == "$expected_bytes" ]] || { print -u2 "size mismatch: $name"; exit 2; }
  [[ "$(shasum -a 256 "$tmp/$name" | cut -d ' ' -f1)" == "$expected_sha" ]] || { print -u2 "sha256 mismatch: $name"; exit 2; }
  print "verified $name"
}

fetch https://github.com/firecrawl/pdfium-rs/releases/download/native-v7988/firecrawl-pdfium-mac-arm64.tgz firecrawl-pdfium-mac-arm64.tgz 3460583 4168356c2e62ad5e79553e2e9162f5c99949759d90cb83876a50311f0c32b9b3
fetch https://github.com/microsoft/onnxruntime/releases/download/v1.27.0/onnxruntime-osx-arm64-1.27.0.tgz onnxruntime-osx-arm64-1.27.0.tgz 32485368 545e81c58152353acb0d1e8bd6ce4b62f830c0961f5b3acfedc790ffd76e477a

tar -xzf "$tmp/firecrawl-pdfium-mac-arm64.tgz" -C "$tmp"
tar -xzf "$tmp/onnxruntime-osx-arm64-1.27.0.tgz" -C "$tmp"
[[ -f "$tmp/lib/libpdfium.dylib" ]] || { print -u2 "PDFium archive has no libpdfium.dylib"; exit 2; }
[[ -f "$tmp/onnxruntime-osx-arm64-1.27.0/lib/libonnxruntime.dylib" ]] || { print -u2 "ONNX archive has no libonnxruntime.dylib"; exit 2; }
[[ "$(lipo -archs "$tmp/lib/libpdfium.dylib")" == *arm64* ]] || { print -u2 "downloaded PDFium is not arm64"; exit 2; }
[[ "$(lipo -archs "$tmp/onnxruntime-osx-arm64-1.27.0/lib/libonnxruntime.dylib")" == *arm64* ]] || { print -u2 "downloaded ONNX Runtime is not arm64"; exit 2; }
cp "$tmp/lib/libpdfium.dylib" "$asset_root/libpdfium.dylib"
cp "$tmp/onnxruntime-osx-arm64-1.27.0/lib/libonnxruntime.dylib" "$asset_root/libonnxruntime.dylib"
cp "$tmp/LICENSE" "$asset_root/PDFium-LICENSE"
cp "$tmp/onnxruntime-osx-arm64-1.27.0/LICENSE" "$asset_root/ONNXRuntime-LICENSE"
cp "$tmp/onnxruntime-osx-arm64-1.27.0/ThirdPartyNotices.txt" "$asset_root/ONNXRuntime-ThirdPartyNotices.txt"
print -r -- '{
  "schema_version": 1,
  "platform": "macos-arm64",
  "artifacts": [
    {
      "name": "libpdfium.dylib",
      "source_url": "https://github.com/firecrawl/pdfium-rs/releases/download/native-v7988/firecrawl-pdfium-mac-arm64.tgz",
      "archive_bytes": 3460583,
      "archive_sha256": "4168356c2e62ad5e79553e2e9162f5c99949759d90cb83876a50311f0c32b9b3"
    },
    {
      "name": "libonnxruntime.dylib",
      "source_url": "https://github.com/microsoft/onnxruntime/releases/download/v1.27.0/onnxruntime-osx-arm64-1.27.0.tgz",
      "archive_bytes": 32485368,
      "archive_sha256": "545e81c58152353acb0d1e8bd6ce4b62f830c0961f5b3acfedc790ffd76e477a"
    }
  ]
}' > "$asset_root/PROVENANCE.json"
print "installed verified OCR runtimes in $asset_root"
