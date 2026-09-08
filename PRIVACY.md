# Privacy

Parchley processes imported PDFs locally. It does not send document contents, passwords, Markdown, or diagnostics to a server. The optional OCR setup downloads model files from pinned release hosts and does not include the PDF in those requests.

Imported PDFs are copied into the app container and remain there while their document is retained. Completed Markdown follows the retention setting. Saved drafts remain until the document is removed. Clearing history removes completed documents without drafts, including their staged PDFs and results. If file cleanup fails, Parchley records the pending cleanup and retries it the next time the workspace opens.
