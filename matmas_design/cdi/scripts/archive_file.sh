#!/bin/sh
# archive_file.sh <source_folder> <file_name> <archive_folder> <batch_id>
SRC="$1"; FILE="$2"; ARC="$3"; BATCH="$4"
mkdir -p "$ARC"
[ -f "$SRC/$FILE" ] || { echo "file $SRC/$FILE not found"; exit 2; }
base="${FILE%.*}"; ext="${FILE##*.}"
mv -f "$SRC/$FILE" "$ARC/${base}_${BATCH}.${ext}"
