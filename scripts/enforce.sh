#!/usr/bin/env bash
set -uo pipefail

OUT="${ADOC_RUN_DIR:-$RUNNER_TEMP}"

# GitHub workflow commands are newline- and "::"-delimited; interpolated text
# comes from files and models, so it is flattened before it is printed.
safe() { printf '%s' "$1" | tr '\r\n' '  ' | sed 's/::/ /g'; }

sync_message() { # empty when the delivery facts are unavailable
  local count branch url number source_branch pr
  count="$(jq -r '.count // empty' "$OUT/proposal-status.json" 2>/dev/null)"
  branch="$(jq -r '.branch // empty' "$OUT/delivery-status.json" 2>/dev/null)"
  url="$(jq -r '.url // empty' "$OUT/delivery-status.json" 2>/dev/null)"
  number="$(printf '%s' "$url" | sed -n 's#.*/pull/\([0-9][0-9]*\)$#\1#p')"
  source_branch="${ADOC_HEAD_REF:-}"
  pr="${ADOC_PR_NUMBER:-}"
  [ -n "$count" ] && [ -n "$branch" ] && [ -n "$number" ] \
    && [ -n "$source_branch" ] || return 1
  printf '%s validated knowledge updates are waiting in draft PR #%s (%s). Merge #%s into %s to rerun this check.' \
    "$count" "$number" "$branch" "$number" "$source_branch"
  if [ -n "$pr" ]; then
    printf ' Details in the AgentDoc comment on #%s.' "$pr"
  else
    printf ' Details in the AgentDoc comment.'
  fi
}

structure_message() { # reason code; empty when the counts are unavailable
  local assessment errors enforcement scope receipt
  assessment="$(cat "$OUT/assessment-path" 2>/dev/null)"
  [ -n "$assessment" ] && [ -s "$assessment" ] || return 1
  if [ "$1" = action.structural_errors_full ]; then
    errors="$(jq -r '.validation.errors_full // empty' "$assessment" 2>/dev/null)"
  else
    errors="$(jq -r '
      [.validation.errors_changed, .validation.errors_unattributed]
      | map(select(type == "number")) | if length == 0 then empty else add end
    ' "$assessment" 2>/dev/null)"
  fi
  [ -n "$errors" ] || return 1
  receipt="$ADOC_RETAINED_DIR/receipt-${ADOC_INVOCATION_ID}.json"
  enforcement="$(jq -r '.policy.enforcement // "strict"' "$receipt" 2>/dev/null)"
  scope="$(jq -r '.policy.scope // "full"' "$receipt" 2>/dev/null)"
  printf '%s errors in changed knowledge sources under enforcement %s, scope %s. Run adoc check locally; details in the AgentDoc comment.' \
    "$errors" "${enforcement:-strict}" "${scope:-full}"
}

final_code="$(cat "$OUT/adoc-final-code" 2>/dev/null || echo 2)"
if ! [[ "$final_code" =~ ^[0-9]+$ ]]; then
  echo '::error::action.receipt_failed: final Action conclusion is missing or invalid'
  exit 2
fi
if [ "$final_code" -ne 0 ]; then
  reason="$(jq -r '.conclusion.reason_codes[0] // .failure.code // "action.receipt_failed"' \
    "$ADOC_RETAINED_DIR/receipt-${ADOC_INVOCATION_ID}.json" 2>/dev/null || echo action.receipt_failed)"
  title='' message=''
  case "$reason" in
    action.knowledge_sync_pending)
      title='AgentDoc knowledge sync'
      message="$(sync_message)" || message='Validated knowledge updates are waiting in a draft pull request. Merge it into the source branch to rerun this check. Details in the AgentDoc comment.'
      ;;
    action.structural_errors_changed | action.structural_errors_full)
      title='AgentDoc structure'
      message="$(structure_message "$reason")" || message='Structural errors in changed knowledge sources block this check. Run adoc check locally; details in the AgentDoc comment.'
      ;;
    *)
      if [ -s "$OUT/failure.json" ]; then
        title='AgentDoc assessment'
        message="$(jq -r '[.message, .help] | map(select(type == "string" and length > 0)) | join(" ")' \
          "$OUT/failure.json" 2>/dev/null)"
        [ -n "$message" ] || title=''
      fi
      ;;
  esac
  if [ -n "$title" ]; then
    echo "::error title=$(safe "$title")::${reason}: $(safe "$message")"
  else
    echo "::error::${reason}: AgentDoc concluded non-green; inspect the report and receipt"
  fi
fi
exit "$final_code"
