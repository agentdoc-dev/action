#!/usr/bin/env bash
set -uo pipefail

OUT="${ADOC_RUN_DIR:-$RUNNER_TEMP}"
final_code="$(cat "$OUT/adoc-final-code" 2>/dev/null || echo 2)"
if ! [[ "$final_code" =~ ^[0-9]+$ ]]; then
  echo '::error::action.receipt_failed: final Action conclusion is missing or invalid'
  exit 2
fi
if [ "$final_code" -ne 0 ]; then
  reason="$(jq -r '.conclusion.reason_codes[0] // .failure.code // "action.receipt_failed"' \
    "$ADOC_RETAINED_DIR/receipt-${ADOC_INVOCATION_ID}.json" 2>/dev/null || echo action.receipt_failed)"
  echo "::error::${reason}: AgentDoc concluded non-green; inspect the report and receipt"
fi
exit "$final_code"
