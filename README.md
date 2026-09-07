# Parchley

Parchley is a native macOS app that converts PDFs into editable Markdown. It keeps document processing on the Mac, lets you review the PDF beside the generated source through a tabbed workspace, and exports plain UTF-8 Markdown.

OCR is optional. When enabled, Parchley downloads a pinned PP-OCRv6 Small model, verifies its size and SHA-256 digest, and runs it locally. The app does not require an account or upload PDF contents.

## Features

- Import multiple PDFs through the file picker, Finder, or drag and drop.
- Queue conversions with per-document progress, cancellation, retry, and ordering.
- Review the original PDF, edit Markdown, and preview the rendered result in separate tabs.
- Keep drafts and completed results across relaunches.
- Copy one result or export one or all results as `.md` files.
- Inspect page methods and warnings when a conversion needs review.
- Use standard macOS menus, keyboard shortcuts, Settings, sidebar search, and context menus.

## Requirements

- macOS 26 or later.
- Apple Silicon for the current release build.
- Xcode with the macOS 26 SDK.
- The pinned Rust toolchain in `Rust/rust-toolchain.toml`.
- `cargo`, `curl`, `jq`, `lipo`, and the standard macOS command-line tools.

## Build from a checkout

The repository intentionally does not include downloaded native runtimes or OCR model files. Fetch the pinned runtimes, build the Rust bridge, package the native inputs, and then build the app:

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

The fetch script verifies the exact byte count and SHA-256 digest recorded in `Vendor/Manifests`. A release bundle must contain `libparchley_ffi.dylib`, `libpdfium.dylib`, and `libonnxruntime.dylib` in `Contents/Frameworks`.

## Tests

Run the package tests:

```sh
swift test --package-path Packages/ParchleyDomain
swift test --package-path Packages/ParchleyMarkdown
swift test --package-path Packages/ParchleyEngine
cargo test --manifest-path Rust/Cargo.toml --locked
cargo test --manifest-path Rust/Cargo.toml --locked --features parchley-core/ocr
```

Run the macOS target tests with Xcode:

```sh
xcodebuild test \
  -project Parchley.xcodeproj \
  -scheme Parchley \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

## Release validation

Build with a Developer ID identity, then validate the complete bundle before distributing it:

```sh
xcodebuild -project Parchley.xcodeproj -scheme Parchley -configuration Release -sdk macosx build
Scripts/verify-release.sh /path/to/Parchley.app
codesign --verify --deep --strict /path/to/Parchley.app
```

Developer ID signing, notarization, stapling, and Gatekeeper validation need to happen in the release environment. `Scripts/package-dmg.sh` creates a local ad-hoc smoke-test DMG. It is not a distribution artifact.

See [Docs/Release.md](Docs/Release.md) for the release checklist and [Docs/Privacy.md](Docs/Privacy.md) for data handling.

## Repository layout

| Path | Purpose |
| --- | --- |
| `Parchley/` | SwiftUI app, commands, previews, settings, and services |
| `Packages/` | Swift packages shared by the app and tests |
| `Rust/` | PDF conversion core and C FFI bridge |
| `Scripts/` | Asset fetching, Rust builds, packaging, and release checks |
| `Vendor/Manifests/` | Pinned runtime and OCR metadata |
| `Docs/` | Architecture, privacy, support, and release notes |
| `Tests/Fixtures/` | Small redistributable PDF fixtures |

## License

Parchley is private, proprietary software. See [LICENSE](LICENSE). Third-party notices and licenses are kept in [`LICENSES/`](LICENSES/).
