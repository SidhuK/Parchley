# Security policy

Parchley is a local-first macOS application. Imported PDFs, passwords, drafts,
conversion results, and OCR output stay on the Mac during normal use. The
optional OCR setup downloads only the pinned model artifacts described by the
manifests in `Vendor/Manifests/`.

## Supported versions

Only the current `main` branch and the latest private release are supported for
security fixes.

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub Private
Vulnerability Reporting or a private Security Advisory for this repository:

<https://github.com/SidhuK/Parchley/security/advisories/new>

If that page is unavailable, contact the repository owner through GitHub and
include "Parchley security report" in the subject.

Include the affected commit or release, macOS version, reproduction steps, and
the smallest safe proof of impact. Do not attach private PDFs, passwords,
tokens, signing keys, or other sensitive data. Redact logs before sharing them.

Reports are acknowledged when practical. Please allow time to reproduce the
issue, prepare a fix, and coordinate disclosure before publishing details.
