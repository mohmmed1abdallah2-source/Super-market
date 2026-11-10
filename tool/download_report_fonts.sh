#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FONT_DIR="$ROOT/assets/fonts"
mkdir -p "$FONT_DIR"

BASE="https://cdn.jsdelivr.net/gh/notofonts/notofonts.github.io/fonts/NotoNaskhArabic/hinted/ttf"
curl -fL --retry 3 "$BASE/NotoNaskhArabic-Regular.ttf" -o "$FONT_DIR/NotoNaskhArabic-Regular.ttf"
curl -fL --retry 3 "$BASE/NotoNaskhArabic-Bold.ttf" -o "$FONT_DIR/NotoNaskhArabic-Bold.ttf"
curl -fL --retry 3 "https://raw.githubusercontent.com/notofonts/arabic/main/OFL.txt" -o "$FONT_DIR/OFL.txt"

python3 - "$FONT_DIR" <<'PY'
from pathlib import Path
import sys
folder = Path(sys.argv[1])
for name in ("NotoNaskhArabic-Regular.ttf", "NotoNaskhArabic-Bold.ttf"):
    data = (folder / name).read_bytes()
    if len(data) < 100_000 or data[:4] not in (b"\x00\x01\x00\x00", b"OTTO", b"true"):
        raise SystemExit(f"Invalid font file: {name}")
    print(f"Verified {name}: {len(data):,} bytes")
PY
