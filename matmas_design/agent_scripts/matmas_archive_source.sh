#!/bin/sh
# MATMAS - archive collected source files (Linux Secure Agent)
# Usage: matmas_archive_source.sh <source_dir> <file_pattern> <archive_dir> <run_id yyyyMMddHHmmss UTC>
SRC="$1"; PATTERN="$2"; ARC="$3"; RUN="$4"
[ -d "$SRC" ] || { echo "source folder not found: $SRC"; exit 2; }
mkdir -p "$ARC"
# reference file stamped with the run start (UTC) - only older files are archived
REF=$(mktemp); TZ=UTC touch -t "$(echo "$RUN" | cut -c1-12).$(echo "$RUN" | cut -c13-14)" "$REF"
moved=0
for f in "$SRC"/$PATTERN; do
  [ -f "$f" ] || continue
  if [ "$f" -ot "$REF" ]; then
    name=$(basename "$f"); base="${name%.*}"; ext="${name##*.}"
    [ "$base" = "$name" ] && dest="$ARC/${name}_${RUN}" || dest="$ARC/${base}_${RUN}.${ext}"
    mv -f "$f" "$dest" && echo "archived $f -> $dest" && moved=$((moved+1))
  fi
done
rm -f "$REF"; echo "files archived: $moved"
