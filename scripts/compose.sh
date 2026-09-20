#!/usr/bin/env bash
set -euo pipefail

OUT="${ADOC_RUN_DIR:-$RUNNER_TEMP}"
SELF="$(cd "$(dirname "$0")" && pwd)"
assessment="$(cat "$OUT/assessment-path" 2>/dev/null || true)"
receipt_sha="$(cat "$OUT/receipt-sha256" 2>/dev/null || echo unavailable)"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/${GITHUB_RUN_ID:-unknown}"
semantic_path="$(jq -r 'select(.status == "complete") | .path // empty' "$OUT/semantic-status.json" 2>/dev/null || true)"

# Every string below reaches Markdown from a file, a model or the environment,
# so the same escape is applied on both paths.
esc='def esc: tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")
  | gsub("\\|"; " ") | gsub("[\n\r]"; " ");'

# The fork job summary is the only surface an untrusted head gets; the preamble
# says so once, above the report, and never reaches a PR comment part.
write_preamble() {
  local preamble="$OUT/summary-preamble.md" label number request digest
  case "${ADOC_UNTRUSTED_CHANGE:-false}:${ADOC_UNTRUSTED_SOURCE:-none}" in
    true:fork) label='Fork pull request' ;;
    true:dependabot) label='Dependabot pull request' ;;
    *) rm -f "$preamble"; return 0 ;;
  esac
  number="${ADOC_PR_NUMBER:-}"
  [[ "$number" =~ ^[0-9]+$ ]] || number='?'
  {
    echo '> [!NOTE]'
    printf '> **%s #%s.** `GITHUB_TOKEN` is read-only, so this report is in the job summary only; nothing was posted to the PR. Model review, proposals and delivery did not run. This summary is written for maintainers.\n' \
      "$label" "$number"
    request="${ADOC_TRUSTED_CHANGE_REQUEST_PATH:-}"
    if [ -n "$request" ] && [ -r "$request" ] && [ -s "$request" ]; then
      digest="$(jq -r '.digest // .request_digest // empty' "$request" 2>/dev/null || true)"
      [ -n "$digest" ] || digest="sha256:$(sha256sum "$request" | awk '{print $1}')"
      echo
      jq -r --arg digest "$digest" "$esc"'
        (.head_sha // .head.sha // "") as $head
        | (.head_repository // .head.repository // "") as $head_repo
        | (.head_ref // .head.ref // "") as $head_ref
        | "<details><summary>Trusted change request</summary>",
          "",
          "| Field | Value |",
          "|---|---|",
          "| Request | <code>" + ((.schema_version // "adoc.trusted_change_request.v0") | esc)
            + "</code> · <code>" + ($digest | esc) + "</code> |",
          (if $head == "" then empty else
            "| Head | <code>" + ($head | esc) + "</code>"
            + (if $head_repo == "" and $head_ref == "" then "" else
                " · <code>" + ([$head_repo, $head_ref] | map(select(. != "")) | join(":") | esc)
                + "</code>" end)
            + " |" end),
          "| Authorization | none yet · expires with head change |",
          "",
          "</details>"' "$request"
    fi
  } > "$preamble"
}
write_preamble

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
receipt="${ADOC_RETAINED_DIR:-}/receipt-${ADOC_INVOCATION_ID:-}.json"
created_at="$(jq -r '.created_at // empty' "$receipt" 2>/dev/null || true)"
[ -n "$created_at" ] || created_at='time unavailable'
receipt_schema="$(jq -r '.schema_version // empty' "$receipt" 2>/dev/null || true)"
[ -n "$receipt_schema" ] || receipt_schema='adoc.pr_assessment_receipt.v4'
receipt_status="$(jq -r '.run_status // empty' "$receipt" 2>/dev/null || true)"
[ -n "$receipt_status" ] || receipt_status=failed

jq -rn \
  --slurpfile failure "$(if [ -s "$failure" ]; then printf %s "$failure"; else printf /dev/null; fi)" \
  --arg head "${ADOC_HEAD:-}" \
  --arg base_ref "${ADOC_BASE_REF:-}" \
  --arg requested_base "${ADOC_REQUESTED_BASE:-}" \
  --arg evaluation_date "${ADOC_EVALUATION_DATE:-}" \
  --arg created_at "$created_at" \
  --arg receipt_sha "$receipt_sha" \
  --arg receipt_schema "$receipt_schema" \
  --arg receipt_status "$receipt_status" \
  --arg run_url "$run_url" \
  --arg adoc_version "${ADOC_VERSION:-?}" \
  --arg action_ref "${ADOC_ACTION_REF:-local}" \
  --arg enforcement "${ENFORCEMENT:-advisory}" \
  --arg scope "${SCOPE:-full}" \
  "$esc"'
  def field($value): if $value == "" then "unavailable" else "<code>" + ($value | esc) + "</code>" end;
  ($failure[0] // {}) as $f
  | "<!-- adoc:block:summary -->",
    "<!-- adoc:pr-report -->",
    ("Head " + (if $head == "" then "<code>unavailable</code>"
                else "<code>" + ($head[0:7] | esc) + "</code>" end)
      + " · " + ($created_at | esc) + " · not assessed"),
    "",
    "> [!CAUTION]",
    "> **Assessment unavailable.** AgentDoc could not establish a valid Change Assessment for this head, so nothing about coverage or knowledge is known. This check fails in every mode until the assessment can run.",
    "",
    "### What to do",
    "",
    ("- **Author** — " + (if ($f.help // "") == "" then
        "rerun the workflow after the failing stage is fixed; see the workflow log."
      else ($f.help | esc) end)),
    "",
    "| Area | Result |",
    "|---|---|",
    ("| Failure | <code>" + (($f.code // "unavailable") | esc) + "</code>"
      + (if ($f.stage // null) == null then "" else " · stage <code>" + ($f.stage | esc) + "</code>" end)
      + " |"),
    ("| Detail | " + (($f.message // "no failure record was written for this run") | esc) + " |"),
    "| Assessment | not run · no <code>adoc.change_assessment.v0</code> envelope |",
    ("| Receipt | <code>" + ($receipt_status | esc) + "</code> · <code>"
      + ($receipt_schema | esc) + "</code> · <code>" + ($receipt_sha | esc) + "</code> |"),
    "",
    "<details><summary>Run details and integrity</summary>",
    "",
    "| Field | Value |",
    "|---|---|",
    ("| Requested head | " + field($head) + " |"),
    ("| Requested base | "
      + (if $base_ref == "" then "" else "<code>" + ($base_ref | esc) + "</code> · " end)
      + field($requested_base) + " |"),
    ("| Evaluation date | " + field($evaluation_date) + " |"),
    "",
    ("[Workflow run](" + $run_url + ") · [retained artifacts](" + $run_url
      + "#artifacts) (receipt only) · The receipt, not this comment, is the record."),
    "",
    "</details>",
    "",
    ("<sub>adoc " + ($adoc_version | esc) + " · action " + ($action_ref | esc)
      + " · enforcement " + ($enforcement | esc) + " · scope " + ($scope | esc) + "</sub>")
  ' > "$OUT/report.md"
