# Privacy

Parchley processes imported PDFs locally. It does not send document contents, passwords, Markdown, or diagnostics to a server. The optional OCR setup downloads model files from the pinned release hosts and does not include the PDF in those requests.

Imported files are staged inside the app container while a job runs. Completed Markdown and drafts remain there according to the retention setting. Clearing history removes retained local results; unsaved drafts require explicit handling before removal.
