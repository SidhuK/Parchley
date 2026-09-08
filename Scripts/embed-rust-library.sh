#!/bin/zsh
set -euo pipefail

repo_root="${SRCROOT}"
rust_root="$repo_root/Rust"
target_dir="${PARCHLEY_RUST_TARGET_DIR:-$rust_root/target}"
rust_target="${PARCHLEY_RUST_TARGET:-aarch64-apple-darwin}"

cd "$rust_root"
cargo build --release --locked --manifest-path "$rust_root/Cargo.toml" --target-dir "$target_dir" --target "$rust_target" -p parchley-ffi --features parchley-core/ocr
library="$target_dir/$rust_target/release/libparchley_ffi.dylib"
test -f "$library"
[[ "$(lipo -archs "$library")" == *arm64* ]] || { print -u2 "Rust bridge is not arm64: $library"; exit 2; }
mkdir -p "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
cp "$library" "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/"
install_name_tool -id "@rpath/libparchley_ffi.dylib" "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/libparchley_ffi.dylib"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "YES" ]]; then
  codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/libparchley_ffi.dylib"
fi

# OCR is enabled only when both verified native libraries are present. Release
# verification rejects a bundle without them; local native-only builds remain
# useful before the optional vendor download has completed.
runtime_root="$repo_root/Vendor/Native/macos-arm64"
require_ocr="${PARCHLEY_REQUIRE_OCR:-0}"
[[ "${CONFIGURATION:-}" == "Release" ]] && require_ocr=1
for runtime in libpdfium.dylib libonnxruntime.dylib; do
  if [[ -f "$runtime_root/$runtime" ]]; then
    [[ "$(lipo -archs "$runtime_root/$runtime")" == *arm64* ]] || {
      print -u2 "OCR runtime is not arm64: $runtime_root/$runtime"
      exit 2
    }
    cp "$runtime_root/$runtime" "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/"
    install_name_tool -id "@rpath/$runtime" "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/$runtime"
    if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "YES" ]]; then
      codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/$runtime"
    fi
  elif [[ "$require_ocr" == "1" ]]; then
    print -u2 "missing required OCR runtime: $runtime_root/$runtime"
    exit 2
  fi
done

resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$resources"
cp "$repo_root/Vendor/Manifests/macos-arm64-runtime.json" "$resources/"
cp "$runtime_root/PROVENANCE.json" "$resources/NativeRuntime-PROVENANCE.json"
