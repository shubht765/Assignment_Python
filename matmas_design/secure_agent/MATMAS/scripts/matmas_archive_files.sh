#!/bin/sh
# MATMAS - archive the files landed in this run (Linux Secure Agent)
# Post-processing command:  /opt/informatica/MATMAS/scripts/matmas_archive_files.sh /opt/informatica/MATMAS
ROOT="${1:-/opt/informatica/MATMAS}"
LIST="$ROOT/work/matmas_filelist.txt"; TS=$(date +%Y%m%d%H%M%S)
[ -f "$LIST" ] || exit 0
while IFS= read -r f; do
  [ "$(basename "$f")" = "_empty.txt" ] && continue
  [ -f "$f" ] || continue
  erp=$(basename "$(dirname "$f")"); name=$(basename "$f"); base="${name%.*}"; ext="${name##*.}"
  mkdir -p "$ROOT/archive/$erp"
  mv -f "$f" "$ROOT/archive/$erp/${base}_${TS}.${ext}" && echo "archived $f"
done < "$LIST"
