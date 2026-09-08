# Synthetic fixture corpus

This directory contains redistributable PDFs used by offline integration tests. The corpus is deliberately small and contains no private documents. Keep expected Markdown beside each fixture when adding a parser regression.

Required cases are native text with headings and lists, a scanned page, a mixed page, Unicode filenames, an encrypted PDF, and malformed/truncated input. The release runner must report skipped OCR cases when the verified model set is unavailable rather than treating them as passing.
