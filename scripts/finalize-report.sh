#!/usr/bin/env bash
set -euo pipefail

OUT="${ADOC_RUN_DIR:-$RUNNER_TEMP}"
REPORT="$OUT/report.md"
if [ -s "$OUT/delivery.md" ]; then
  printf '\n%s\n' "$(cat "$OUT/delivery.md")" >> "$REPORT"
  rm -f "$OUT/delivery.md"
fi
[ "$(jq -Rs 'length' "$REPORT")" -le 60000 ] && exit 0

awk '
  /<!-- adoc:optional-start -->/ {
    print "> ⚠️ Optional model output omitted at the 60,000-character Action limit. See the retained assessment and workflow diagnostics."
    omitted = 1
    next
  }
  /<!-- adoc:optional-end -->/ { omitted = 0; next }
  !omitted { print }
' "$REPORT" > "$REPORT.tmp"
mv "$REPORT.tmp" "$REPORT"
[ "$(jq -Rs 'length' "$REPORT")" -le 60000 ] && exit 0

# Last-resort invariant guard for malformed or legacy callers: retain only
# complete bounded lines, then keep the remediation and delivery surfaces.
awk '
  BEGIN { total = 0 }
  {
    bytes = length($0) + 1
    if (bytes <= 4096 && total + bytes <= 50000) {
      print
      total += bytes
    }
  }
' "$REPORT" > "$REPORT.tmp"
{
  cat "$REPORT.tmp"
  echo
  echo '> ⚠️ Report detail omitted at the 60,000-character Action limit. See the retained assessment and workflow diagnostics.'
  if [ -s "$OUT/delivery.md" ]; then
    awk 'length($0) <= 4096' "$OUT/delivery.md"
  fi
} > "$REPORT"
rm -f "$REPORT.tmp" "$OUT/delivery.md"
[ "$(jq -Rs 'length' "$REPORT")" -le 60000 ]
