#!/usr/bin/env bash

set -euo pipefail

LIST_FILE="${1:-}"
OUTPUT_PDF="${2:-}"
ROOT_DIR="${3:-.}"

usage() {
  cat <<'EOF'
Usage:
  ./pdf-create.sh <notebooks-list.txt> [output.pdf] [root_dir]

Example:
  ./pdf-create.sh notebooks-full.txt all-notebooks.pdf .
EOF
}

if [[ -z "$LIST_FILE" ]]; then
  echo "Error: missing notebook list file."
  usage
  exit 1
fi

if [[ ! -f "$LIST_FILE" ]]; then
  echo "Error: list file not found: $LIST_FILE"
  exit 1
fi

if [[ -z "$OUTPUT_PDF" ]]; then
  list_base="$(basename "$LIST_FILE")"
  OUTPUT_PDF="${list_base%.*}.pdf"
fi

if ! command -v jupyter >/dev/null 2>&1; then
  echo "Error: 'jupyter' not found in PATH. Install Jupyter first."
  exit 1
fi

# Read notebook list from text file, preserving the file order.
# Set SORT_NOTEBOOKS=1 to sort explicitly.
if [[ "${SORT_NOTEBOOKS:-0}" == "1" ]]; then
  mapfile -t NOTEBOOKS < <(
    sed 's/\r$//' "$LIST_FILE" \
    | awk 'NF && $1 !~ /^#/' \
    | sort
  )
else
  mapfile -t NOTEBOOKS < <(
    sed 's/\r$//' "$LIST_FILE" \
    | awk 'NF && $1 !~ /^#/'
  )
fi

if [[ "${#NOTEBOOKS[@]}" -eq 0 ]]; then
  echo "No notebooks found in list file '$LIST_FILE'."
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

postprocess_pdf() {
  local input_pdf="$1"
  local output_pdf="$2"
  local footer_text="$3"
  python3 - "$input_pdf" "$output_pdf" "$footer_text" <<'PY'
import io
import sys
from pypdf import PdfReader, PdfWriter
from reportlab.pdfgen import canvas

in_pdf, out_pdf, footer = sys.argv[1], sys.argv[2], sys.argv[3]
reader = PdfReader(in_pdf)
pages = list(reader.pages)

def is_blank_like(page):
    text = (page.extract_text() or "").strip()
    if text:
        return False
    resources = page.get("/Resources")
    if resources and "/XObject" in resources:
        xobj = resources["/XObject"]
        for _, obj in xobj.items():
            try:
                if obj.get("/Subtype") == "/Image":
                    return False
            except Exception:
                pass
    return True

# Remove trailing blank pages that nbconvert may emit.
while pages and is_blank_like(pages[-1]):
    pages.pop()

writer = PdfWriter()
for page in pages:
    w = float(page.mediabox.width)
    h = float(page.mediabox.height)
    packet = io.BytesIO()
    c = canvas.Canvas(packet, pagesize=(w, h))
    c.setFont("Helvetica", 8)
    c.drawCentredString(w / 2.0, 12, footer)
    c.save()
    packet.seek(0)
    overlay = PdfReader(packet).pages[0]
    page.merge_page(overlay)
    writer.add_page(page)

with open(out_pdf, "wb") as f:
    writer.write(f)
PY
}

for nb in "${NOTEBOOKS[@]}"; do
  # Resolve notebook path relative to root_dir unless already absolute.
  if [[ "$nb" = /* ]]; then
    nb_path="$nb"
  else
    nb_path="$ROOT_DIR/$nb"
  fi

  if [[ ! -f "$nb_path" ]]; then
    echo "Warning: notebook missing, skipping: $nb_path"
    index=$((index + 1))
    continue
  fi

  safe_name="$(basename "$nb_path" .ipynb | tr ' /' '__')"
  out_base="$(printf "%04d_%s" "$index" "$safe_name")"

  echo "[$index/$total] Converting: $nb_path"
  if ! jupyter nbconvert --to webpdf --allow-chromium-download "$nb_path" --output "$out_base" --output-dir "$TMP_DIR"; then
    echo "webpdf conversion failed for '$nb_path'; trying classic PDF exporter."
    jupyter nbconvert --to pdf "$nb_path" --output "$out_base" --output-dir "$TMP_DIR"
  fi

  pdf_path="$TMP_DIR/$out_base.pdf"
  if [[ -f "$pdf_path" ]]; then
    stamped_pdf="$TMP_DIR/${out_base}.stamped.pdf"
    footer_name="$(basename "$nb_path")"
    postprocess_pdf "$pdf_path" "$stamped_pdf" "$footer_name"
    PDF_FILES+=("$stamped_pdf")
  else
    echo "Warning: expected PDF not found for $nb_path"
  fi

  index=$((index + 1))
done

if [[ "${#PDF_FILES[@]}" -eq 0 ]]; then
  echo "Error: no PDFs were generated."
  exit 1
fi

echo "Merging ${#PDF_FILES[@]} PDFs into: $OUTPUT_PDF"
if command -v python3 >/dev/null 2>&1 && python3 -c "import pypdf" >/dev/null 2>&1; then
  # Merge via pypdf to preserve per-page content and overlays.
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
elif command -v gs >/dev/null 2>&1; then
  gs -dBATCH -dNOPAUSE -q -sDEVICE=pdfwrite -sOutputFile="$OUTPUT_PDF" "${PDF_FILES[@]}"
else
  echo "Error: no PDF merge backend found."
  echo "Install Ghostscript ('gs') or Python package 'pypdf'."
  exit 1
fi

echo "Done: $OUTPUT_PDF"
