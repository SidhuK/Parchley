#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
rust_root="$repo_root/Rust"
target_dir="${PARCHLEY_RUST_TARGET_DIR:-$rust_root/target}"

cd "$rust_root"
cargo fmt --all -- --check
cargo build --release --locked --manifest-path "$rust_root/Cargo.toml" --target-dir "$target_dir" -p parchley-ffi --features parchley-core/ocr

echo "Built Parchley Rust engine with OCR support. Runtime paths are configured by the app from its bundled Frameworks directory."
