#!/usr/bin/env bash
set -euo pipefail

OUT="${ADOC_RUN_DIR:-$RUNNER_TEMP}"
SELF="$(cd "$(dirname "$0")" && pwd)"
assessment="$(cat "$OUT/assessment-path" 2>/dev/null || true)"
receipt_sha="$(cat "$OUT/receipt-sha256" 2>/dev/null || echo unavailable)"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/${GITHUB_RUN_ID:-unknown}"

if [ -f "$assessment" ]; then
  jq -r \
    --arg style "${REPORT_STYLE:-compact}" \
    --arg receipt_sha "$receipt_sha" \
    --arg run_url "$run_url" \
    --arg adoc_version "${ADOC_VERSION:-?}" \
    --arg action_ref "${ADOC_ACTION_REF:-local}" \
    --arg enforcement "${ENFORCEMENT:-advisory}" \
    --arg scope "${SCOPE:-full}" \
    --arg requested_base "${ADOC_REQUESTED_BASE:-unavailable}" \
    --arg comparison_base "${ADOC_COMPARISON_BASE:-unavailable}" \
    --arg head "${ADOC_HEAD:-unavailable}" \
    --rawfile proposal "$(if [ -s "$OUT/proposed-drafts.md" ]; then printf %s "$OUT/proposed-drafts.md"; else printf /dev/null; fi)" \
    --rawfile delivery "$(if [ -s "$OUT/delivery.md" ]; then printf %s "$OUT/delivery.md"; else printf /dev/null; fi)" \
    -f "$SELF/render-assessment.jq" "$assessment" > "$OUT/report.md"
  rm -f "$OUT/delivery.md"
  exit 0
fi

failure="$OUT/failure.json"
{
  echo '<!-- adoc:pr-report -->'
  echo '## AgentDoc PR Report'
  echo
  echo '### Assessment'
  echo
  echo '> ❌ **Assessment unavailable.** AgentDoc could not establish a valid Change Assessment.'
  if [ -s "$failure" ]; then
    jq -r 'def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
      "\n- Failure: <code>\(.code|esc)</code> — \(.message|esc)\n- Remediation: \(.help|esc)"' "$failure"
  fi
  echo
  echo '### Assessment receipt'
  echo
  echo "- Assessment receipt: <code>$receipt_sha</code> · [workflow run]($run_url)"
} > "$OUT/report.md"
