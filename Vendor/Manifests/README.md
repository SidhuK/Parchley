# Parchley runtime manifests

The OCR build consumes the pinned `pdf-inspector` 1.17.0 vision contracts. PDFium
and ONNX Runtime binaries must be checked into the release packaging pipeline
from their upstream arm64 macOS archives after checksum and signature review.
They are intentionally not fabricated here. A release build must fail closed if
an artifact is absent or its digest does not match the manifest used by the
packager.
