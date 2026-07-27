#!/usr/bin/env bash
#
# pdf-create-zhs.sh — build merged PDFs from the Simplified Chinese (_zhs) notebooks.
#
# It mirrors pdf-create.sh but operates on the *_zhs.ipynb translations. For each
# notebooks-*.txt list it derives a notebooks-*-zhs.txt (every .ipynb path gets
# _zhs inserted before the extension) and builds notebooks-*-zhs.pdf from those.
#
# Usage:
#   ./pdf-create-zhs.sh                       # build one PDF per notebooks-*.txt
#   ./pdf-create-zhs.sh notebooks-exercises.txt
#   ./pdf-create-zhs.sh notebooks-full.txt all-zhs.pdf .
#
# The actual conversion (nbconvert webpdf -> merge -> TOC -> footer/page numbers)
# is delegated to pdf-create.sh so this script stays in sync with any changes to
# the build logic. Only the notebook selection differs (the _zhs translations).

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./pdf-create-zhs.sh
  ./pdf-create-zhs.sh [notebooks-list.txt] [output.pdf] [root_dir]

Builds PDFs from the Simplified Chinese (_zhs) notebook translations.

Example:
  ./pdf-create-zhs.sh                         # builds one PDF for each notebooks-*.txt
  ./pdf-create-zhs.sh notebooks-exercises.txt
  ./pdf-create-zhs.sh notebooks-full.txt all-zhs.pdf .

For a given list file, each ".ipynb" path is rewritten to its "_zhs.ipynb"
translation (e.g. N001 - Micrograd.ipynb -> N001 - Micrograd_zhs.ipynb) and the
PDF is named after the list with a "-zhs" suffix
(notebooks-exercises.txt -> notebooks-exercises-zhs.pdf).

Environment:
  PDF_DISABLE_COPY=0                          # keep copy/extract permissions enabled
  SKIP_MISSING=0                              # skip notebooks whose _zhs file is absent
                                              # (default: error out so omissions are visible)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

# Locate pdf-create.sh next to this script (falls back to PATH).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "$SCRIPT_DIR/pdf-create.sh" ]]; then
  PDF_CREATE="$SCRIPT_DIR/pdf-create.sh"
else
  if ! command -v pdf-create.sh >/dev/null 2>&1; then
    echo "Error: cannot find pdf-create.sh (expected next to this script or in PATH)."
    exit 1
  fi
  PDF_CREATE="pdf-create.sh"
fi

# Rewrite every notebook path in a list file to its _zhs translation.
# Lines that are blank or start with '#' are passed through unchanged.
make_zhs_list() {
  local in_list="$1"
  local out_list="$2"
  sed 's/\r$//' "$in_list" \
    | awk '
        /^#/  { print; next }      # preserve comments
        NF==0 { print; next }       # preserve blank lines
        {
          # Insert _zhs before .ipynb (handles both "foo.ipynb" and "foo.ipynb" at EOL).
          # Idempotent: if the path already ends in _zhs.ipynb, leave it alone.
          line = $0
          if (line ~ /_zhs\.ipynb$/) {
            print line
          } else {
            sub(/\.ipynb$/, "_zhs.ipynb", line)
            print line
          }
        }
      ' > "$out_list"
}

# Verify that every notebook referenced in a _zhs list actually exists.
# Returns nonzero (with a message) if any are missing, unless SKIP_MISSING=1.
check_zhs_list() {
  local list="$1"
  local root_dir="$2"
  local missing=0
  while IFS= read -r nb; do
    # skip blank / comment lines
    [[ -z "$nb" || "$nb" =~ ^[[:space:]]*# ]] && continue
    if [[ "$nb" = /* ]]; then
      nb_path="$nb"
    else
      nb_path="$root_dir/$nb"
    fi
    if [[ ! -f "$nb_path" ]]; then
      echo "Error: translated notebook not found: $nb_path" >&2
      missing=$((missing + 1))
    fi
  done < "$list"
  if [[ "$missing" -gt 0 ]]; then
    if [[ "${SKIP_MISSING:-0}" == "1" ]]; then
      echo "Warning: $missing translated notebook(s) missing; pdf-create.sh will skip them." >&2
    else
      echo "Run the translation first, or set SKIP_MISSING=1 to build with the available ones." >&2
      return 1
    fi
  fi
  return 0
}

if [[ "$#" -eq 0 ]]; then
  shopt -s nullglob
  # Only iterate over ORIGINAL list files; exclude derived *-zhs.txt lists so
  # we don't recursively re-derive them (notebooks-exercises-zhs.txt -> -zhs-zhs.txt).
  all_lists=(notebooks-*.txt)
  shopt -u nullglob

  LIST_FILES=()
  for f in "${all_lists[@]}"; do
    base="$(basename "$f")"
    stem="${base%.*}"
    # Skip lists whose stem already ends in -zhs (they are this script's output).
    if [[ "$stem" == *-zhs ]]; then
      continue
    fi
    LIST_FILES+=("$f")
  done

  if [[ "${#LIST_FILES[@]}" -eq 0 ]]; then
    echo "Error: no notebooks-*.txt files found."
    exit 1
  fi

  built=0
  for list_file in "${LIST_FILES[@]}"; do
    echo "==> Building _zhs PDF for $list_file"
    if "$0" "$list_file" "" "."; then
      built=$((built + 1))
    fi
  done

  echo "Done: built $built _zhs PDF(s)."
  exit 0
fi

LIST_FILE="$1"
OUTPUT_PDF="${2:-}"
ROOT_DIR="${3:-.}"

if [[ ! -f "$LIST_FILE" ]]; then
  echo "Error: list file not found: $LIST_FILE"
  exit 1
fi

# Derive the _zhs list file name: notebooks-exercises.txt -> notebooks-exercises-zhs.txt
list_base="$(basename "$LIST_FILE")"
list_stem="${list_base%.*}"
zhs_list_name="${list_stem}-zhs.txt"

# Place the derived list next to the source list (same directory).
list_dir="$(cd "$(dirname "$LIST_FILE")" && pwd)"
ZHS_LIST="$list_dir/$zhs_list_name"

make_zhs_list "$LIST_FILE" "$ZHS_LIST"

# Remove the derived list on exit so it doesn't clutter the repo (it is
# regenerated on every run). Keep it only if KEEP_ZHS_LIST=1 is set.
if [[ "${KEEP_ZHS_LIST:-0}" != "1" ]]; then
  trap 'rm -f "$ZHS_LIST"' EXIT
fi

if ! check_zhs_list "$ZHS_LIST" "$ROOT_DIR"; then
  exit 1
fi

# Default output PDF mirrors the list name with a -zhs suffix.
if [[ -z "$OUTPUT_PDF" ]]; then
  OUTPUT_PDF="${list_stem}-zhs.pdf"
fi

echo "Derived list: $ZHS_LIST"
echo "Output PDF:   $OUTPUT_PDF"

# Delegate the actual conversion + merge to pdf-create.sh.
"$PDF_CREATE" "$ZHS_LIST" "$OUTPUT_PDF" "$ROOT_DIR"
