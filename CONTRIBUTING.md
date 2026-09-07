# Contributing to Parchley

Parchley is currently maintained as a private repository. Changes should keep
the app local-first, sandbox-friendly, and compatible with macOS 26 and Swift 6.

## Before opening a change

- Keep user-visible behavior and error messages clear and recoverable.
- Do not commit downloaded runtimes, OCR models, app bundles, credentials, or
  private documents.
- Keep SwiftUI state on the main actor and Rust conversion work off the UI
  actor. Preserve the narrow Swift-to-Rust boundary.
- Add or update tests for changes to queue state, storage, export, parsing, or
  model installation.

## Local checks

Run the relevant package tests and Rust tests. For app changes, also run an
Xcode build and the macOS test target. Release work must run
`Scripts/verify-release.sh` against the signed bundle.

## Review expectations

Keep commits focused and explain behavior changes in the commit message. Review
accessibility, keyboard use, dark mode, cancellation, interrupted work, and
error recovery when a change touches those paths.
