#!/bin/sh
# MATMAS - build the indirect file list for m_MATMAS_LAND (Linux Secure Agent)
# Pre-processing command:  /opt/informatica/MATMAS/scripts/matmas_prepare_filelist.sh /opt/informatica/MATMAS
ROOT="${1:-/opt/informatica/MATMAS}"
WORK="$ROOT/work"; LIST="$WORK/matmas_filelist.txt"
mkdir -p "$WORK"; : > "$LIST"
find "$ROOT/inbound" -mindepth 2 -maxdepth 2 -type f \( -name '*.txt' -o -name '*.csv' \) | sort >> "$LIST"
if [ ! -s "$LIST" ]; then : > "$WORK/_empty.txt"; echo "$WORK/_empty.txt" >> "$LIST"; fi
cat "$LIST"
