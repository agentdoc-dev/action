#!/usr/bin/env bash
# Transitional V9.2.2 summary. V9.2.3 owns the full disposition renderer.
set -euo pipefail

OUT="${ADOC_RUN_DIR:-$RUNNER_TEMP}"
assessment="$(cat "$OUT/assessment-path" 2>/dev/null || true)"
receipt_sha="$(cat "$OUT/receipt-sha256" 2>/dev/null || echo unavailable)"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/${GITHUB_RUN_ID:-unknown}"

{
  echo '<!-- adoc:pr-report -->'
  echo '## AgentDoc PR Report'
  echo
  if [ -f "$assessment" ]; then
    completeness="$(jq -r .completeness "$assessment")"
    outcome="$(jq -r .outcome "$assessment")"
    echo '### Assessment'
    echo
    case "$completeness/$outcome" in
      partial/not_evaluated)
        echo '> ⚠️ **Assessment incomplete.** AgentDoc could not establish a complete deterministic result.' ;;
      error/not_evaluated)
        echo '> ❌ **Assessment not evaluated.** Inspect the workflow failure and rerun.' ;;
      error/invalid)
        echo '> ❌ **Knowledge structure invalid.** The final gate follows the configured structural enforcement mode.' ;;
    esac
    echo "- Completeness: \`$completeness\`"
    echo "- Deterministic outcome: \`$outcome\`"
    echo "- Evaluation date: \`$(jq -r .evaluation_date "$assessment")\`"
    echo
    echo '### Validation'
    echo
    jq -r '"- Errors: \(.validation.errors_full) total · \(.validation.errors_changed) changed · \(.validation.errors_unchanged) unchanged · \(.validation.errors_unattributed) unattributed\n- Warnings: \(.validation.warnings)"' "$assessment"
    echo
    echo '### Change Assessment'
    echo
    jq -r '"- Paths: \(.summary.changed_paths) changed · \(.summary.covered) covered · \(.summary.provisional) provisional · \(.summary.uncovered) uncovered · \(.summary.excluded) excluded\n- Affected Knowledge Objects: \(.summary.impacted_objects)"' "$assessment"
  else
    failure="$OUT/failure.json"
    echo '### Assessment'
    echo
    echo '> ❌ **Assessment unavailable.** AgentDoc could not establish a valid Change Assessment.'
    if [ -s "$failure" ]; then
      echo
      echo "- Failure: \`$(jq -r .code "$failure")\` — $(jq -r .message "$failure")"
      echo "- Remediation: $(jq -r .help "$failure")"
    fi
  fi
  echo
  if [ -s "$OUT/proposed-drafts.md" ]; then
    echo '### Proposed Knowledge Objects'
    echo
    echo '> **Legacy advisory drafts:** these proposals are partial, unreviewed, and non-canonical.'
    echo
    cat "$OUT/proposed-drafts.md"
    echo
  fi
  echo '### Assessment Receipt'
  echo
  echo "- Requested base: \`${ADOC_REQUESTED_BASE:-unavailable}\`"
  echo "- Comparison base: \`${ADOC_COMPARISON_BASE:-unavailable}\`"
  echo "- Head: \`${ADOC_HEAD:-unavailable}\`"
  echo "- Receipt: \`$receipt_sha\` · [workflow run]($run_url)"
  echo
  echo "<sub>adoc ${ADOC_VERSION:-?} · enforcement: ${ENFORCEMENT:-advisory} · scope: ${SCOPE:-full}</sub>"
} > "$OUT/report.md"
exit 0
