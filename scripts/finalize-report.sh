#!/usr/bin/env bash
set -euo pipefail

OUT="${ADOC_RUN_DIR:-$RUNNER_TEMP}"
REPORT="$OUT/report.md"
if [ -s "$OUT/delivery.md" ]; then
  printf '\n%s\n' "$(cat "$OUT/delivery.md")" >> "$REPORT"
  rm -f "$OUT/delivery.md"
fi
[ "$(jq -Rs 'length' "$REPORT")" -le 60000 ] && exit 0

jq -Rrs '.[0:50000]
  + "\n\n> ⚠️ Report truncated at the 60,000-character Action limit. See job diagnostics for omitted detail.\n\n"
  + .[-8000:]' "$REPORT" > "$REPORT.tmp"
mv "$REPORT.tmp" "$REPORT"
