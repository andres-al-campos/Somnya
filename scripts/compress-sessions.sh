#!/usr/bin/env bash
# Compress the synced nights in analysis/sessions to .json.gz (about a third the size).
# The phone's folder sync counts a .json.gz as already synced, and the analysis package reads
# either form. A file written in the last 5 minutes is skipped: a sync may still be writing it.
set -euo pipefail
dir="$(cd "$(dirname "$0")/../analysis/sessions" && pwd)"
before=$(du -sk "$dir" | cut -f1)
n=0
while IFS= read -r -d '' f; do
  gzip -6 "$f"
  n=$((n + 1))
done < <(find "$dir" -maxdepth 1 -name 'somnya-session-*.json' -mmin +5 -print0)
after=$(du -sk "$dir" | cut -f1)
echo "Compressed $n nights: $((before / 1024)) MB → $((after / 1024)) MB"
