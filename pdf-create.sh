#!/usr/bin/env bash

set -euo pipefail

OUTPUT_PDF="${1:-all-notebooks.pdf}"
ROOT_DIR="${2:-.}"

if ! command -v jupyter >/dev/null 2>&1; then
  echo "Error: 'jupyter' not found in PATH. Install Jupyter first."
  exit 1
fi

mapfile -d '' NOTEBOOKS < <(find "$ROOT_DIR" -type f -name "*.ipynb" -print0 | sort -z)

if [[ "${#NOTEBOOKS[@]}" -eq 0 ]]; then
  echo "No notebooks found under '$ROOT_DIR'."
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

PDF_FILES=()
index=1
total="${#NOTEBOOKS[@]}"

for nb in "${NOTEBOOKS[@]}"; do
  safe_name="$(basename "$nb" .ipynb | tr ' /' '__')"
  out_base="$(printf "%04d_%s" "$index" "$safe_name")"

  echo "[$index/$total] Converting: $nb"
  if ! jupyter nbconvert --to webpdf --allow-chromium-download "$nb" --output "$out_base" --output-dir "$TMP_DIR"; then
    echo "webpdf conversion failed for '$nb'; trying classic PDF exporter."
    jupyter nbconvert --to pdf "$nb" --output "$out_base" --output-dir "$TMP_DIR"
  fi

  pdf_path="$TMP_DIR/$out_base.pdf"
  if [[ -f "$pdf_path" ]]; then
    PDF_FILES+=("$pdf_path")
  else
    echo "Warning: expected PDF not found for $nb"
  fi

  index=$((index + 1))
done

if [[ "${#PDF_FILES[@]}" -eq 0 ]]; then
  echo "Error: no PDFs were generated."
  exit 1
fi

echo "Merging ${#PDF_FILES[@]} PDFs into: $OUTPUT_PDF"
if command -v gs >/dev/null 2>&1; then
  gs -dBATCH -dNOPAUSE -q -sDEVICE=pdfwrite -sOutputFile="$OUTPUT_PDF" "${PDF_FILES[@]}"
elif command -v python3 >/dev/null 2>&1 && python3 -c "import pypdf" >/dev/null 2>&1; then
  # Fallback merge path when Ghostscript is unavailable.
  python3 - "$OUTPUT_PDF" "${PDF_FILES[@]}" <<'PY'
import sys
from pypdf import PdfWriter

output = sys.argv[1]
inputs = sys.argv[2:]

writer = PdfWriter()
for pdf in inputs:
    writer.append(pdf)

with open(output, "wb") as f:
    writer.write(f)
PY
else
  echo "Error: no PDF merge backend found."
  echo "Install Ghostscript ('gs') or Python package 'pypdf'."
  exit 1
fi

echo "Done: $OUTPUT_PDF"
