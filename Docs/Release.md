# Release checklist

Use a clean Apple Silicon macOS 26 environment for distribution validation.

## Build inputs

- Confirm the versions and SHA-256 values in `Vendor/Manifests/`.
- Run `Scripts/fetch-ocr-assets.sh` into the ignored native asset directory.
- Run `Scripts/build-rust.sh` with the pinned Rust toolchain.
- Run `Scripts/package-native.sh` and confirm the arm64 bridge and runtimes are
  present.

## Validation

- Run package tests, Rust tests, and the macOS Xcode test target.
- Build a Release app with the intended Developer ID identity.
- Run `Scripts/verify-release.sh /path/to/Parchley.app`.
- Run `codesign --verify --deep --strict /path/to/Parchley.app`.
- Test launch, PDF import, conversion, cancellation, retry, draft recovery,
  OCR installation, export, Settings, and the app menu on a clean machine.
- Test the signed bundle with Gatekeeper before publishing.

## Distribution

Notarize the signed app or DMG, staple the ticket, and repeat signature and
Gatekeeper checks. Keep the source repository private unless the license and
third-party distribution terms are reviewed first.
