# Release measurements

Measured on 2026-09-06 on a MacBookPro17,1 with Apple M1 and 16 GB RAM, running macOS 26.6.2 (build 25G83), from the signed arm64 Release artifact:

- App bundle: 59 MB (`/tmp/parchley-release-artifact/Build/Products/Release/Parchley.app`)
- Compressed local ad-hoc DMG: 21 MB (`/tmp/Parchley-local-adhoc.dmg`)

The artifact uses the Parchley Rust engine with PDFium native-v7988 and ONNX Runtime 1.27.0. The optional PP-OCRv6 Small model is installed separately and is not included in the app or DMG size above.

Future release measurements should also capture installed model size, OCR cold and warm time per page, peak resident memory, idle memory, and draft preview time. Record macOS, chip, RAM, engine version, runtime revisions, model revision, and fixture hashes with each run.
