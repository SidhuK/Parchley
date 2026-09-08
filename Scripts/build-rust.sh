#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
rust_root="$repo_root/Rust"
target_dir="${PARCHLEY_RUST_TARGET_DIR:-$rust_root/target}"
rust_target="${PARCHLEY_RUST_TARGET:-aarch64-apple-darwin}"

cd "$rust_root"
cargo fmt --all -- --check
cargo build --release --locked --manifest-path "$rust_root/Cargo.toml" --target-dir "$target_dir" --target "$rust_target" -p parchley-ffi --features parchley-core/ocr

library="$target_dir/$rust_target/release/libparchley_ffi.dylib"
[[ -f "$library" ]] || { print -u2 "Rust bridge was not built for $rust_target: $library"; exit 2; }
[[ "$(lipo -archs "$library")" == *arm64* ]] || { print -u2 "Rust bridge is not arm64: $library"; exit 2; }

echo "Built Parchley Rust engine with OCR support for $rust_target. Runtime paths are configured by the app from its bundled Frameworks directory."
