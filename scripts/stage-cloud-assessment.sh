#!/usr/bin/env bash
# Stages one workflow_run artifact as inert data for isolated Cloud submission.
set -euo pipefail

fail() {
  echo "::error::action.cloud_sync_failed: $1" >&2
  exit 1
}

[ "${GITHUB_EVENT_NAME:-}" = workflow_run ] \
  || fail 'Use the protected default-branch workflow_run ingestion workflow.'
[ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] \
  || fail 'Use a fresh GitHub-hosted runner for Cloud assessment ingestion.'
[ -f "${GITHUB_EVENT_PATH:-}" ] && [ -n "${GITHUB_REPOSITORY_ID:-}" ] \
  || fail 'GitHub workflow-run identity is unavailable.'

runner_root="$(realpath "${RUNNER_TEMP:?}" 2>/dev/null)" \
  || fail 'Runner temporary storage is unavailable.'
artifact_root="$(realpath "${ARTIFACT_DIRECTORY:?}" 2>/dev/null)" \
  || fail 'The downloaded assessment artifact is unavailable.'
case "$artifact_root" in
  "$runner_root"/*) ;;
  *) fail 'Download the assessment artifact beneath RUNNER_TEMP.' ;;
esac

assessments=()
receipts=()
while IFS= read -r -d '' path; do assessments+=("$path"); done \
  < <(find "$artifact_root" -type f -name 'assessment-*.json' -print0)
while IFS= read -r -d '' path; do receipts+=("$path"); done \
  < <(find "$artifact_root" -type f -name 'receipt-*.json' -print0)
[ "${#assessments[@]}" -eq 1 ] && [ "${#receipts[@]}" -eq 1 ] \
  || fail 'The artifact must contain exactly one assessment and one receipt.'
assessment="${assessments[0]}"
receipt="${receipts[0]}"
[ -f "$assessment" ] && [ ! -L "$assessment" ] \
  && [ -f "$receipt" ] && [ ! -L "$receipt" ] \
  || fail 'Assessment artifacts must be regular files.'

if ! jq -e '
  .schema_version == "adoc.pr_assessment_receipt.v4"
  and .run_status == "completed"
  and (.ci.pull_request | type == "number" and floor == . and . > 0)
  and (.ci.run_id | type == "string" and test("^[1-9][0-9]*$"))
  and (.ci.run_attempt | type == "number" and floor == . and . > 0)
  and (.ci.invocation_id | type == "string"
    and test("^inv_[A-Za-z0-9_.-]+_[0-9a-f]{32}$"))
  and (.ci.workload_identity.repository_id | type == "string"
    and test("^[1-9][0-9]*$"))
  and (.revisions.requested_base | test("^[0-9a-f]{40}$"))
  and (.revisions.head | test("^[0-9a-f]{40}$"))
  and .assessment.schema_version == "adoc.change_assessment.v0"
  and (.assessment.sha256 | test("^sha256:[0-9a-f]{64}$"))
' "$receipt" >/dev/null; then
  fail 'The receipt is not a complete v4 assessment receipt.'
fi

if ! jq -e --slurpfile receipt "$receipt" \
  --arg repository_id "$GITHUB_REPOSITORY_ID" '
  $receipt[0] as $r
  | .action == "completed"
  and .workflow_run.event == "pull_request"
  and (.workflow_run.id | tostring) == $r.ci.run_id
  and .workflow_run.run_attempt == $r.ci.run_attempt
  and (.repository.id | tostring) == $repository_id
  and $r.ci.workload_identity.repository_id == $repository_id
  and $r.ci.repository == .repository.full_name
  and any(.workflow_run.pull_requests[]?;
    .number == $r.ci.pull_request
    and .base.sha == $r.revisions.requested_base
    and .head.sha == $r.revisions.head)
' "$GITHUB_EVENT_PATH" >/dev/null; then
  fail 'The receipt does not belong to this completed pull-request workflow run.'
fi

invocation_id="$(jq -r .ci.invocation_id "$receipt")"
requested_base="$(jq -r .revisions.requested_base "$receipt")"
head="$(jq -r .revisions.head "$receipt")"
pr_number="$(jq -r .ci.pull_request "$receipt")"
[ "$(basename "$assessment")" = "assessment-$invocation_id.json" ] \
  && [ "$(basename "$receipt")" = "receipt-$invocation_id.json" ] \
  || fail 'Artifact filenames do not match the receipted invocation.'

assessment_digest="sha256:$(sha256sum "$assessment" | awk '{print $1}')"
[ "$assessment_digest" = "$(jq -r .assessment.sha256 "$receipt")" ] \
  || fail 'The assessment bytes do not match the receipt.'
if ! jq -e --arg base "$requested_base" --arg head "$head" '
  .schema_version == "adoc.change_assessment.v0"
  and .snapshots.requested_base.resolved_commit == $base
  and .snapshots.head.resolved_commit == $head
' "$assessment" >/dev/null; then
  fail 'The assessment is not bound to the receipted revisions.'
fi
receipt_digest="sha256:$(sha256sum "$receipt" | awk '{print $1}')"

private_root="$(mktemp -d "$runner_root/agentdoc-cloud-assessment.XXXXXX")"
run_dir="$private_root/private"
retained_dir="$private_root/retained"
mkdir -m 700 "$run_dir" "$retained_dir"
install -m 600 "$assessment" "$retained_dir/assessment-$invocation_id.json"
install -m 600 "$receipt" "$retained_dir/receipt-$invocation_id.json"
printf '%s\n' "$retained_dir/assessment-$invocation_id.json" > "$run_dir/assessment-path"
printf '%s\n' "$assessment_digest" > "$run_dir/assessment-sha256"
printf '%s\n' "$receipt_digest" > "$run_dir/receipt-sha256"

{
  printf 'ADOC_RUN_DIR=%s\n' "$run_dir"
  printf 'ADOC_RETAINED_DIR=%s\n' "$retained_dir"
  printf 'ADOC_INVOCATION_ID=%s\n' "$invocation_id"
  printf 'ADOC_REQUESTED_BASE=%s\n' "$requested_base"
  printf 'ADOC_HEAD=%s\n' "$head"
  printf 'ADOC_PR_NUMBER=%s\n' "$pr_number"
} >> "${GITHUB_ENV:?}"
