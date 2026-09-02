#!/usr/bin/env bash
set -euo pipefail

OUT="${ADOC_RUN_DIR:-$RUNNER_TEMP}"
SELF="$(cd "$(dirname "$0")" && pwd)"
assessment="$(cat "$OUT/assessment-path" 2>/dev/null || true)"
receipt_sha="$(cat "$OUT/receipt-sha256" 2>/dev/null || echo unavailable)"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/${GITHUB_RUN_ID:-unknown}"
semantic_path="$(jq -r 'select(.status == "complete") | .path // empty' "$OUT/semantic-status.json" 2>/dev/null || true)"

render_cloud_assessment_status() {
  [ -s "$OUT/cloud-assessment-status.json" ] || return 0
  jq -r '
    def esc: tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
    "\n<!-- adoc:block:cloud-assessment -->\n### Cloud assessment ingestion\n\n"
    + (if .status == "completed" then "> ✅ **" + (.disposition | ascii_upcase) + ".**"
      elif .status == "failed" then "> ⚠️ **Ingestion failed; the local assessment remains valid.**"
      else "> ℹ️ **Skipped.**" end) + "\n"
    + (if .code == null then "" else
        "\n- Signal: <code>" + (.code | esc) + "</code>\n" end)
    + (if .request_digest == null then "" else
        "- Submission: <code>" + (.request_digest | esc) + "</code>\n" end)
    + (if .remediation == null then "" else
        "- Remediation: " + (.remediation | esc) + "\n" end)
  ' "$OUT/cloud-assessment-status.json" >> "$OUT/report.md"
}

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
    --arg server_url "${GITHUB_SERVER_URL:-https://github.com}" \
    --arg repository "${GITHUB_REPOSITORY:-unknown/unknown}" \
    --arg semantic_requested "${SEMANTIC_REVIEW:-false}" \
    --arg propose_enabled "${PROPOSE:-false}" \
    --arg propose_delivery "${PROPOSE_DELIVERY:-comment}" \
    --slurpfile semantic "$(if [ -s "$semantic_path" ]; then printf %s "$semantic_path"; else printf /dev/null; fi)" \
    --slurpfile proposal_status "$(if [ -s "$OUT/proposal-status.json" ]; then printf %s "$OUT/proposal-status.json"; else printf /dev/null; fi)" \
    --slurpfile delivery_status "$(if [ -s "$OUT/delivery-status.json" ]; then printf %s "$OUT/delivery-status.json"; else printf /dev/null; fi)" \
    --rawfile proposal "$(if [ -s "$OUT/proposed-drafts.md" ]; then printf %s "$OUT/proposed-drafts.md"; else printf /dev/null; fi)" \
    -f "$SELF/render-assessment.jq" "$assessment" > "$OUT/report.md"
  receipt="$ADOC_RETAINED_DIR/receipt-${ADOC_INVOCATION_ID}.json"
  if [ -f "$receipt" ]; then
    jq -r '
      def esc: tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
      .semantic_assessment as $semantic
      | "\n<!-- adoc:block:semantic-assessment -->\n### Semantic assessment\n\n"
      + (if $semantic.status == "completed" then "> ✅ **Completed.**"
        elif $semantic.status == "fell_back" then "> ⚠️ **Completed through the configured fallback.**"
        elif $semantic.status == "failed" then "> ❌ **Failed.**"
        elif $semantic.status == "required" then "> ⏳ **Required.**"
        else "> ℹ️ **Skipped.**" end)
      + (if $semantic.failure_code == null then "\n" else
          " <code>" + ($semantic.failure_code | esc) + "</code>\n" end)
      + (if $semantic.primary == null then "" else
          "\n- Primary: <code>" + ($semantic.primary.provider | esc) + "/"
          + ($semantic.primary.model | esc) + "</code> — `"
          + $semantic.primary.outcome + "`\n" end)
      + (if $semantic.fallback == null then "" else
          "- Fallback: <code>" + ($semantic.fallback.provider | esc) + "/"
          + ($semantic.fallback.model | esc) + "</code> — `"
          + $semantic.fallback.outcome + "`\n" end)
    ' "$receipt" >> "$OUT/report.md"
    jq -r '
      def esc: tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
      .cloud_sync // {status:"skipped",reason:"not_requested",reason_code:null,
        result_digest:null,remediation:null}
      | "\n<!-- adoc:block:cloud-sync -->\n### Cloud hand-off\n\n"
      + (if .status == "completed" then "> ✅ **Uploaded.**"
        elif .status == "failed" then "> ⚠️ **Upload failed; the local assessment remains valid.**"
        else "> ℹ️ **Skipped.**" end)
      + " `" + (.reason | esc) + "`\n"
      + (if .reason_code == null then "" else
          "\n- Signal: <code>" + (.reason_code | esc) + "</code>\n" end)
      + (if .result_digest == null then "" else
          "- Result: <code>" + (.result_digest | esc) + "</code>\n" end)
      + (if .remediation == null then "" else
          "- Remediation: " + (.remediation | esc) + "\n" end)
    ' "$receipt" >> "$OUT/report.md"
  fi
  render_cloud_assessment_status
  baseline="$(cat "$OUT/baseline-path" 2>/dev/null || true)"
  if [ -f "$baseline" ]; then
    jq -r '
      "\n<!-- adoc:block:baseline -->\n### Repository baseline\n\n"
      + (if .readiness.ready then
          "> ✅ **Ready.** Every non-excluded tracked path has authoritative knowledge coverage.\n"
        else
          "> ⚠️ **Not ready:** `" + .readiness.reason + "`.\n"
        end)
      + "\n- **Tracked:** \(.summary.changed_paths)"
      + " · **Covered:** \(.summary.covered)"
      + " · **Provisional:** \(.summary.provisional)"
      + " · **Uncovered:** \(.summary.uncovered)"
      + " · **Excluded:** \(.summary.excluded)\n"
    ' "$baseline" >> "$OUT/report.md"
  fi
  rm -f "$OUT/delivery.md"
  exit 0
fi

failure="$OUT/failure.json"
{
  echo '<!-- adoc:block:summary -->'
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
render_cloud_assessment_status
