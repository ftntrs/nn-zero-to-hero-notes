#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./pdf-create.sh
  ./pdf-create.sh [notebooks-list.txt] [output.pdf] [root_dir]

Example:
  ./pdf-create.sh                         # builds one PDF for each notebooks-*.txt
  ./pdf-create.sh notebooks-exercises.txt
  ./pdf-create.sh notebooks-full.txt all-notebooks-with-solved.pdf .

Environment:
  PDF_DISABLE_COPY=0                      # keep copy/extract permissions enabled
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$#" -eq 0 ]]; then
  shopt -s nullglob
  LIST_FILES=(notebooks-*.txt)
  shopt -u nullglob

  if [[ "${#LIST_FILES[@]}" -eq 0 ]]; then
    echo "Error: no notebooks-*.txt files found."
    exit 1
  fi

  for list_file in "${LIST_FILES[@]}"; do
    echo "==> Building PDF for $list_file"
    "$0" "$list_file" "" "."
  done

  echo "Done: built ${#LIST_FILES[@]} PDFs."
  exit 0
fi

LIST_FILE="$1"
OUTPUT_PDF="${2:-}"
ROOT_DIR="${3:-.}"

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

JUPYTER_BIN="$(command -v jupyter)"
PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  PYTHON_BIN="python3"
  jupyter_shebang="$(head -n 1 "$JUPYTER_BIN" || true)"
  if [[ "$jupyter_shebang" == '#!'* ]]; then
    jupyter_python="${jupyter_shebang#\#!}"
    if [[ -x "$jupyter_python" ]]; then
      PYTHON_BIN="$jupyter_python"
    fi
  fi
fi

# Read notebook list from text file, preserving the file order.
# Set SORT_NOTEBOOKS=1 to sort explicitly.
if [[ "${SORT_NOTEBOOKS:-0}" == "1" ]]; then
  NOTEBOOKS=()
  while IFS= read -r nb; do
    NOTEBOOKS+=("$nb")
  done < <(
    sed 's/\r$//' "$LIST_FILE" \
    | awk 'NF && $1 !~ /^#/' \
    | sort
  )
else
  NOTEBOOKS=()
  while IFS= read -r nb; do
    NOTEBOOKS+=("$nb")
  done < <(
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
PDF_LABELS=()
index=1
total="${#NOTEBOOKS[@]}"

postprocess_pdf() {
  local input_pdf="$1"
  local output_pdf="$2"
  local footer_text="$3"
  "$PYTHON_BIN" - "$input_pdf" "$output_pdf" "$footer_text" <<'PY'
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
  nb_dir="$(dirname "$nb_path")"
  nb_file="$(basename "$nb_path")"
  if ! (
    cd "$nb_dir"
    jupyter nbconvert \
      --to webpdf \
      --HTMLExporter.embed_images=True \
      "$nb_file" \
      --output "$out_base" \
      --output-dir "$TMP_DIR"
  ); then
    echo "webpdf conversion failed for '$nb_path'; trying classic PDF exporter."
    (
      cd "$nb_dir"
      jupyter nbconvert --to pdf "$nb_file" --output "$out_base" --output-dir "$TMP_DIR"
    )
  fi

  pdf_path="$TMP_DIR/$out_base.pdf"
  if [[ -f "$pdf_path" ]]; then
    stamped_pdf="$TMP_DIR/${out_base}.stamped.pdf"
    footer_name="$(basename "$nb_path")"
    postprocess_pdf "$pdf_path" "$stamped_pdf" "$footer_name"
    PDF_FILES+=("$stamped_pdf")
    PDF_LABELS+=("${nb#./}")
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
if "$PYTHON_BIN" -c "import pypdf" >/dev/null 2>&1; then
  MANIFEST="$TMP_DIR/manifest.tsv"
  : > "$MANIFEST"
  for i in "${!PDF_FILES[@]}"; do
    printf '%s\t%s\n' "${PDF_LABELS[$i]}" "${PDF_FILES[$i]}" >> "$MANIFEST"
  done

  # Merge via pypdf to preserve per-page content and overlays.
  "$PYTHON_BIN" - "$OUTPUT_PDF" "${LIST_FILE%.*}" "$MANIFEST" <<'PY'
import io
import os
import secrets
import sys
from pypdf.constants import UserAccessPermissions
from pypdf import PdfReader, PdfWriter
from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import letter

output = sys.argv[1]
title = sys.argv[2]
manifest = sys.argv[3]

entries = []
with open(manifest, encoding="utf-8") as f:
    for line in f:
        label, pdf = line.rstrip("\n").split("\t", 1)
        reader = PdfReader(pdf)
        entries.append({"label": label, "pdf": pdf, "reader": reader, "pages": len(reader.pages)})

def fit_text(c, text, max_width, font_name="Helvetica", font_size=10):
    if c.stringWidth(text, font_name, font_size) <= max_width:
        return text
    ellipsis = "..."
    lo, hi = 0, len(text)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if c.stringWidth(text[:mid] + ellipsis, font_name, font_size) <= max_width:
            lo = mid
        else:
            hi = mid - 1
    return text[:lo] + ellipsis

def build_toc(entries, toc_page_count):
    width, height = letter
    left, right = 54, width - 54
    top, bottom = height - 72, 54
    line_height = 18
    first_line_y = top - 48
    rows_per_first = int((first_line_y - bottom) // line_height) + 1
    rows_per_next = int((top - bottom) // line_height) + 1

    starts = []
    page_number = toc_page_count + 1
    for entry in entries:
        starts.append(page_number)
        page_number += entry["pages"]

    packets = []
    row_index = 0
    page_index = 0
    while row_index < len(entries) or page_index == 0:
        packet = io.BytesIO()
        c = canvas.Canvas(packet, pagesize=letter)
        c.setTitle(title)
        c.setFont("Helvetica-Bold", 20)
        c.drawString(left, top, "Table of Contents")
        c.setFont("Helvetica", 10)
        c.drawString(left, top - 22, title)

        y = first_line_y if page_index == 0 else top
        rows_this_page = rows_per_first if page_index == 0 else rows_per_next
        for _ in range(rows_this_page):
            if row_index >= len(entries):
                break
            label = entries[row_index]["label"]
            start = str(starts[row_index])
            c.setFont("Helvetica", 10)
            label_width = right - left - c.stringWidth(start, "Helvetica", 10) - 18
            display_label = fit_text(c, label, label_width)
            c.drawString(left, y, display_label)
            c.drawRightString(right, y, start)
            dots_start = left + c.stringWidth(display_label, "Helvetica", 10) + 8
            dots_end = right - c.stringWidth(start, "Helvetica", 10) - 8
            if dots_end > dots_start:
                c.setDash(1, 3)
                c.line(dots_start, y + 2, dots_end, y + 2)
                c.setDash()
            y -= line_height
            row_index += 1

        c.save()
        packet.seek(0)
        packets.append(packet)
        page_index += 1

    return packets, starts

toc_packets, starts = build_toc(entries, 1)
if len(toc_packets) != 1:
    toc_packets, starts = build_toc(entries, len(toc_packets))

writer = PdfWriter()
for packet in toc_packets:
    writer.add_page(PdfReader(packet).pages[0])

for entry in entries:
    for page in entry["reader"].pages:
        writer.add_page(page)

total_pages = len(writer.pages)
for index, page in enumerate(writer.pages, start=1):
    w = float(page.mediabox.width)
    h = float(page.mediabox.height)
    packet = io.BytesIO()
    c = canvas.Canvas(packet, pagesize=(w, h))
    c.setFont("Helvetica", 8)
    c.drawRightString(w - 24, 12, f"{index} / {total_pages}")
    c.save()
    packet.seek(0)
    overlay = PdfReader(packet).pages[0]
    page.merge_page(overlay)

for entry, start in zip(entries, starts):
    writer.add_outline_item(entry["label"], start - 1)

if os.environ.get("PDF_DISABLE_COPY", "1") != "0":
    writer.encrypt(
        user_password="",
        owner_password=secrets.token_urlsafe(32),
        permissions_flag=(
            UserAccessPermissions.PRINT
            | UserAccessPermissions.PRINT_TO_REPRESENTATION
        ),
    )

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
