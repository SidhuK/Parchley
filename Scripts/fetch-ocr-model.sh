#!/bin/zsh
set -euo pipefail

root="${PARCHLEY_MODEL_DIR:?set PARCHLEY_MODEL_DIR to the durable Application Support model directory}"
mkdir -p "$root"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fetch() {
  local name="$1" bytes="$2" sha="$3" url="$4"
  curl -L --fail --silent --show-error --connect-timeout 20 -o "$tmp/$name" "$url"
  [[ "$(stat -f '%z' "$tmp/$name")" == "$bytes" ]] || exit 2
  [[ "$(shasum -a 256 "$tmp/$name" | cut -d ' ' -f1)" == "$sha" ]] || exit 2
}
fetch pp-ocrv6_small_det.onnx 9880512 d73e0058b7a8086bbd57f3d10b8bcd4ff95363f67e06e2762b5e814fe9c9410e https://github.com/GreatV/oar-ocr/releases/download/v0.7.0/pp-ocrv6_small_det.onnx
fetch pp-ocrv6_small_rec.onnx 21159378 5435fd747c9e0efe15a96d0b378d5bd157e9492ed8fd80edf08f30d02fa24634 https://github.com/GreatV/oar-ocr/releases/download/v0.7.0/pp-ocrv6_small_rec.onnx
fetch ppocrv6_dict.txt 74947 b5f2bfe2bdd9448429e3e82b51c789775d9b42f2403d082b00662eb77e401c5d https://github.com/GreatV/oar-ocr/releases/download/v0.7.0/ppocrv6_dict.txt
cp "$tmp"/* "$root/"
print "installed verified PP-OCRv6 Small model set in $root"
