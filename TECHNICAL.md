# Technical guide

This guide covers the toolchain, project layout, local builds, tests, and release checks for Parchley.

## Requirements

- macOS 26 or later
- Apple silicon
- Xcode with the macOS 26 SDK
- The Rust toolchain pinned in `Rust/rust-toolchain.toml`
- `cargo`, `curl`, `jq`, `lipo`, and the macOS command-line tools

## How the app is put together

The interface is written in SwiftUI. Three local Swift packages hold the document models, Markdown rendering, and the bridge to the conversion engine. The conversion engine is written in Rust and uses PDFium for PDF parsing and ONNX Runtime for local OCR.

The app includes the pinned PP-OCRv6 Small model. Build scripts verify downloaded native libraries and model files against the byte counts and SHA-256 digests in `Vendor/Manifests` before packaging them.

| Path | Contents |
| --- | --- |
| `Parchley/` | SwiftUI app, commands, settings, and services |
| `Packages/ParchleyDomain/` | Shared document and conversion types |
| `Packages/ParchleyMarkdown/` | Markdown rendering support |
| `Packages/ParchleyEngine/` | Swift bridge to the Rust engine |
| `Rust/` | PDF conversion core and C FFI bridge |
| `Scripts/` | Native dependency, build, packaging, and release scripts |
| `Vendor/Manifests/` | Pinned runtime and OCR metadata |
| `Tests/Fixtures/` | Small redistributable PDF fixtures |

## Build from source

Fetch and verify the native inputs, build the Rust library, package it, then build the app:

```sh
Scripts/fetch-ocr-assets.sh
Scripts/build-rust.sh
PARCHLEY_NATIVE_OUTPUT_DIR="$PWD/Vendor/Native/macos-arm64" Scripts/package-native.sh
xcodebuild -project Parchley.xcodeproj \
  -scheme Parchley \
  -configuration Debug \
  -sdk macosx \
  CODE_SIGNING_ALLOWED=NO \
  build
```

A complete app bundle contains these files in `Contents/Frameworks`:

- `libparchley_ffi.dylib`
- `libpdfium.dylib`
- `libonnxruntime.dylib`

## Run tests

Run the Swift package and Rust tests:

```sh
swift test --package-path Packages/ParchleyDomain
swift test --package-path Packages/ParchleyMarkdown
swift test --package-path Packages/ParchleyEngine
cargo test --manifest-path Rust/Cargo.toml --locked
cargo test --manifest-path Rust/Cargo.toml --locked --features parchley-core/ocr
```

Run the macOS target tests:

```sh
xcodebuild test \
  -project Parchley.xcodeproj \
  -scheme Parchley \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

## Validate a release

Build with a Developer ID identity, then check the finished app bundle:

```sh
xcodebuild -project Parchley.xcodeproj -scheme Parchley -configuration Release -sdk macosx build
Scripts/verify-release.sh /path/to/Parchley.app
codesign --verify --deep --strict /path/to/Parchley.app
```

Distribution builds still need notarization, stapling, and Gatekeeper validation. `Scripts/package-dmg.sh` creates an ad-hoc disk image for local smoke testing. It does not create a distribution-ready release.

## Related files

- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Privacy policy](PRIVACY.md)
- [Third-party licenses](LICENSES/README.md)
