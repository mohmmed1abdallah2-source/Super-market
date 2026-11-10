# Noto Naskh Arabic fonts

The official PDF report template expects these local assets:

- `NotoNaskhArabic-Regular.ttf`
- `NotoNaskhArabic-Bold.ttf`

The binary font files are not checked into this commit because the connected GitHub file-writing interface accepts UTF-8 text, not raw binary uploads. Download the upstream hinted TTFs and the SIL Open Font License by running:

```bash
bash tool/download_report_fonts.sh
```

Upstream source: https://github.com/notofonts/arabic
Font dashboard: https://notofonts.github.io/arabic/
License: SIL Open Font License 1.1 (see `OFL.txt` after download).

Do not replace these assets with empty placeholders or text files: the PDF generator loads the actual TTF binary data at runtime.
