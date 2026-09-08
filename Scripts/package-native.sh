#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
rust_root="$repo_root/Rust"
target_dir="${PARCHLEY_RUST_TARGET_DIR:-$rust_root/target}"
rust_target="${PARCHLEY_RUST_TARGET:-aarch64-apple-darwin}"
out_root="${PARCHLEY_NATIVE_OUTPUT_DIR:-$repo_root/Vendor/Native/macos-arm64}"
pdfium="${PARCHLEY_PDFIUM_LIB:-$out_root/libpdfium.dylib}"
onnx="${PARCHLEY_ORT_LIB:-$out_root/libonnxruntime.dylib}"

[[ -f "$pdfium" ]] || { print -u2 "missing PDFium runtime: $pdfium"; exit 2; }
[[ -f "$onnx" ]] || { print -u2 "missing ONNX Runtime: $onnx"; exit 2; }
command -v lipo >/dev/null || { print -u2 "lipo is required to inspect native runtimes"; exit 2; }
[[ "$(lipo -archs "$pdfium")" == *arm64* ]] || { print -u2 "PDFium is not arm64: $pdfium"; exit 2; }
[[ "$(lipo -archs "$onnx")" == *arm64* ]] || { print -u2 "ONNX Runtime is not arm64: $onnx"; exit 2; }

mkdir -p "$out_root"
bridge="$target_dir/$rust_target/release/libparchley_ffi.a"
header="$rust_root/include/parchly.h"
[[ -f "$bridge" ]] || { print -u2 "missing Rust bridge for $rust_target: $bridge"; exit 2; }
[[ -s "$header" ]] || { print -u2 "missing Rust bridge header: $header"; exit 2; }
cp "$bridge" "$out_root/"
cp "$header" "$out_root/"

rm -f "$out_root/runtime.env"
print "Packaged native arm64 bridge and verified runtime architecture in $out_root"
