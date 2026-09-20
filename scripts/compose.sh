#!/usr/bin/env bash
set -euo pipefail

OUT="${ADOC_RUN_DIR:-$RUNNER_TEMP}"
SELF="$(cd "$(dirname "$0")" && pwd)"
assessment="$(cat "$OUT/assessment-path" 2>/dev/null || true)"
receipt_sha="$(cat "$OUT/receipt-sha256" 2>/dev/null || echo unavailable)"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/${GITHUB_RUN_ID:-unknown}"
semantic_path="$(jq -r 'select(.status == "complete") | .path // empty' "$OUT/semantic-status.json" 2>/dev/null || true)"

if [ -f "$assessment" ]; then
  receipt="${ADOC_RETAINED_DIR:-}/receipt-${ADOC_INVOCATION_ID:-}.json"
  semantic_assessment="${ADOC_RETAINED_DIR:-}/semantic-assessment-${ADOC_INVOCATION_ID:-}.json"
  baseline="$(cat "$OUT/baseline-path" 2>/dev/null || true)"
  created_at="$(jq -r '.created_at // empty' "$receipt" 2>/dev/null || true)"
  [ -n "$created_at" ] || created_at='time unavailable'

  # The acceptance sentence keeps the exact gate the standalone negative-verdict
  # block used: receipted, whole-run, no_change_required over a complete scan.
  deterministic_assessment_sha="sha256:$(sha256sum "$assessment" | awk '{print $1}')"
  acceptance=false
  if [ -f "$receipt" ]; then
    semantic_assessment_sha="$(if [ -f "$semantic_assessment" ]; then
      printf 'sha256:'
      sha256sum "$semantic_assessment" | awk '{print $1}'
    fi)"
    if jq -e --arg assessment_sha "$semantic_assessment_sha" \
      --arg deterministic_sha "$deterministic_assessment_sha" \
      --slurpfile deterministic "$assessment" \
      --slurpfile assessment "$(if [ -s "$semantic_assessment" ]; then
        printf %s "$semantic_assessment"
      else
        printf /dev/null
      fi)" '
      .semantic_assessment as $semantic
      | (($semantic.status == "completed" or $semantic.status == "fell_back")
        and $semantic.assessment_sha256 == $assessment_sha
        and .assessment.sha256 == $deterministic_sha
        and ($deterministic | length) == 1
        and $deterministic[0].completeness == "complete"
        and $deterministic[0].knowledge_snapshot.status == "available"
        and ($assessment | length) == 1
        and ($assessment[0].findings | length) > 0
        and all($assessment[0].findings[];
          .proposed_disposition == "no_change_required"))
      ' "$receipt" >/dev/null 2>&1; then
      acceptance=true
    fi
  fi

  jq -r \
    --arg style "${REPORT_STYLE:-compact}" \
    --arg receipt_sha "$receipt_sha" \
    --arg run_url "$run_url" \
    --arg adoc_version "${ADOC_VERSION:-?}" \
    --arg action_ref "${ADOC_ACTION_REF:-local}" \
    --arg enforcement "${ENFORCEMENT:-advisory}" \
    --arg scope "${SCOPE:-full}" \
    --arg requested_base "${ADOC_REQUESTED_BASE:-unavailable}" \
    --arg requested_base_ref "${ADOC_BASE_REF:-}" \
    --arg assessment_sha "$deterministic_assessment_sha" \
    --arg comparison_base "${ADOC_COMPARISON_BASE:-unavailable}" \
    --arg head "${ADOC_HEAD:-unavailable}" \
    --arg server_url "${GITHUB_SERVER_URL:-https://github.com}" \
    --arg repository "${GITHUB_REPOSITORY:-unknown/unknown}" \
    --arg semantic_requested "${SEMANTIC_REVIEW:-false}" \
    --arg propose_enabled "${PROPOSE:-false}" \
    --arg propose_delivery "${PROPOSE_DELIVERY:-comment}" \
    --arg sync_policy "${SYNC_POLICY:-advisory}" \
    --arg created_at "$created_at" \
    --arg acceptance "$acceptance" \
    --slurpfile semantic "$(if [ -s "$semantic_path" ]; then printf %s "$semantic_path"; else printf /dev/null; fi)" \
    --slurpfile proposal_status "$(if [ -s "$OUT/proposal-status.json" ]; then printf %s "$OUT/proposal-status.json"; else printf /dev/null; fi)" \
    --slurpfile delivery_status "$(if [ -s "$OUT/delivery-status.json" ]; then printf %s "$OUT/delivery-status.json"; else printf /dev/null; fi)" \
    --slurpfile receipt "$(if [ -s "$receipt" ]; then printf %s "$receipt"; else printf /dev/null; fi)" \
    --slurpfile baseline "$(if [ -s "$baseline" ]; then printf %s "$baseline"; else printf /dev/null; fi)" \
    --rawfile proposal "$(if [ -s "$OUT/proposed-drafts.md" ]; then printf %s "$OUT/proposed-drafts.md"; else printf /dev/null; fi)" \
    -f "$SELF/render-assessment.jq" "$assessment" > "$OUT/report.md"
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
