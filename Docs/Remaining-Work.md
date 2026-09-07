# Remaining work

This document records release gaps for the current MVP snapshot. The first-pass
implementation is now complete for the items that can be finished in source.

- Reconversion is implemented with an explicit Keep Draft / Replace draft decision. Keep Draft restores the saved Markdown on the new conversion revision; Replace draft discards it only after a successful replacement. Failed conversions retain the existing draft.
- Import and preparing-stage progress/cancellation is implemented. Import stages are persisted, conversion progress reports completed/total pages when available, and native cancellation remains visibly in a Stopping state until the Rust worker reaches a terminal state.
- Automated Rust and Swift package tests, OCR-feature compilation, and an Xcode Debug app build have been run. Full corpus accuracy, performance/memory profiling, accessibility review, UI-test execution on a clean machine, and a clean-machine validation pass remain release validation work.
- Developer ID signing, notarization, ticket stapling, and Gatekeeper validation require distribution credentials and a clean release environment.
- UniFFI bindings and a static arm64 XCFramework remain an optional migration. The synchronous C ABI is the current bridge after the UniFFI 0.29.5 prototype hit generated object symbol/type conflicts.
- OCR model installation now retries transient failures, verifies exact byte counts and SHA-256 hashes, and atomically publishes only verified files. A final networked release rehearsal—including retry and corrupt-download recovery—remains outstanding.
