#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE_DIR="$(mktemp -d)"
trap 'rm -rf "$CASE_DIR"' EXIT
export ADOC_RUN_DIR="$CASE_DIR/private" ADOC_RETAINED_DIR="$CASE_DIR/retained"
export ADOC_INVOCATION_ID=inv_1_1_report_0123456789abcdef0123456789abcdef
export ADOC_REQUESTED_BASE=1111111111111111111111111111111111111111
export ADOC_COMPARISON_BASE=2222222222222222222222222222222222222222
export ADOC_HEAD=3333333333333333333333333333333333333333
export GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=agentdoc/test GITHUB_RUN_ID=1
export ADOC_ACTION_REF=v1.6.0-test
mkdir -p "$ADOC_RUN_DIR" "$ADOC_RETAINED_DIR"
cp "$ROOT/test/fixture-assessment.json" "$ADOC_RETAINED_DIR/assessment.json"
printf '%s\n' "$ADOC_RETAINED_DIR/assessment.json" > "$ADOC_RUN_DIR/assessment-path"
printf 'sha256:%064d\n' 9 > "$ADOC_RUN_DIR/receipt-sha256"

render() {
  REPORT_STYLE="$1" ENFORCEMENT=advisory SCOPE=full ADOC_VERSION=v0.3.4 \
    "$ROOT/scripts/compose.sh"
  COMMENT_MAX_COMMENTS=5 "$ROOT/scripts/finalize-report.sh"
  cp "$ADOC_RUN_DIR/report.md" "$CASE_DIR/$1.md"
}

render compact
cp "$CASE_DIR/compact.md" "$CASE_DIR/compact-baseline.md"
cmp "$ROOT/test/golden-report-compact.md" "$CASE_DIR/compact.md"
for heading in '### Validation' '### Deterministic assessment' '### Changed paths' \
  '### Affected knowledge' '### Knowledge signals' \
  '### Required owners and proof obligations' 'Run details and integrity'; do
  grep -Fq "$heading" "$CASE_DIR/compact.md"
done
grep -Fq '**Covered:** 1' "$CASE_DIR/compact.md"
grep -Fq '**Provisional:** 1' "$CASE_DIR/compact.md"
grep -Fq '**Uncovered:** 1' "$CASE_DIR/compact.md"
grep -Fq '**Excluded:** 1' "$CASE_DIR/compact.md"
grep -Fq 'changed in this PR' "$CASE_DIR/compact.md"
grep -Fq 'human disposition required' "$CASE_DIR/compact.md"
grep -Fq '&lt;img src=x onerror=alert(1)&gt;' "$CASE_DIR/compact.md"
grep -Fq 'Unsafe &#124; &lt;!-- adoc:pr-report --&gt; marker' "$CASE_DIR/compact.md"
if grep -Fq '<img src=x' "$CASE_DIR/compact.md" \
  || grep -Fq '<!-- adoc:pr-report --> marker' "$CASE_DIR/compact.md"; then
  echo 'unescaped repository content reached the report' >&2
  exit 1
fi

render table
grep -Fq '| Classification | Path |' "$CASE_DIR/table.md"
render detailed
grep -Fq 'sha256:aaaaaaaa' "$CASE_DIR/detailed.md"

jq -n '{status:"skipped",count:0,sha256:null,reason:"no_candidate_scope"}' \
  > "$ADOC_RUN_DIR/proposal-status.json"
PROPOSE=true PROPOSE_DELIVERY=pr REPORT_STYLE=compact ENFORCEMENT=advisory \
  SCOPE=full ADOC_VERSION=v0.3.4 "$ROOT/scripts/compose.sh"
COMMENT_MAX_COMMENTS=5 "$ROOT/scripts/finalize-report.sh"
grep -Fq 'No knowledge update was proposed' "$ADOC_RUN_DIR/report.md"
grep -Fq 'no follow-up pull request was created' "$ADOC_RUN_DIR/report.md"
grep -Fq '<details><summary>Proposal audit metadata</summary>' "$ADOC_RUN_DIR/report.md"
grep -Fq 'no_candidate_scope' "$ADOC_RUN_DIR/report.md"
rm "$ADOC_RUN_DIR/proposal-status.json"

# partial_completeness_cannot_render_no_change_required: a receipted whole-run
# semantic negative verdict is visible only with a complete deterministic scan.
semantic_assessment="$ADOC_RETAINED_DIR/semantic-assessment-$ADOC_INVOCATION_ID.json"
cp "$ROOT/test/fixture-assessment.json" "$ADOC_RETAINED_DIR/assessment.json"
deterministic_assessment_sha="sha256:$(sha256sum "$ADOC_RETAINED_DIR/assessment.json" | awk '{print $1}')"
jq -n --arg base "$ADOC_COMPARISON_BASE" --arg head "$ADOC_HEAD" '{
  schema_version:"adoc.semantic_assessment.v0",
  context_digest:("sha256:" + ("1" * 64)),
  base_revision:{system:"git",value:$base},
  head_revision:{system:"git",value:$head},
  identity:{provider:"test",model:"test-v1"},
  materiality_policy_version:"adoc.materiality.v0",
  scope:{handle_ids:["src/covered.rs"]},
  findings:[{
    finding_id:"negative-verdict",classification:"consistent",
    affected_objects:[{object_id:"billing.covered",
      content_hash:("sha256:" + ("a" * 64))}],
    citations:["src/covered.rs#L1-L2"],materiality:"immaterial",
    proposed_disposition:"no_change_required",candidate_updates:[],
    unresolved_questions:[],explanation:"No knowledge change is required."
  }]
}' > "$semantic_assessment"
semantic_assessment_sha="sha256:$(sha256sum "$semantic_assessment" | awk '{print $1}')"
jq -n --arg digest "$semantic_assessment_sha" \
  --arg deterministic "$deterministic_assessment_sha" '{
  assessment:{sha256:$deterministic},
  semantic_assessment:{status:"completed",failure_code:null,
    assessment_sha256:$digest,
    primary:{request_id:"primary",provider:"test",model:"test-v1",
      outcome:"completed",failure_code:null},fallback:null}
}' > "$ADOC_RETAINED_DIR/receipt-$ADOC_INVOCATION_ID.json"
render compact
grep -Fq '### Negative verdict' "$CASE_DIR/compact.md"
grep -Fq "**Changed paths scanned:** \`4\`" "$CASE_DIR/compact.md"
grep -Fq '**Knowledge graph:** <code>sha256:1111111111111111111111111111111111111111111111111111111111111111</code>' "$CASE_DIR/compact.md"
grep -Fq '**Knowledge object set:** <code>sha256:2222222222222222222222222222222222222222222222222222222222222222</code>' "$CASE_DIR/compact.md"
grep -Fq "**Classification:** \`consistent\`" "$CASE_DIR/compact.md"
grep -Fq 'Merging this PR under branch protection is explicit acceptance of the negative verdict by the merging principal.' "$CASE_DIR/compact.md"

jq '.summary.changed_paths = 999' "$ROOT/test/fixture-assessment.json" \
  > "$ADOC_RETAINED_DIR/assessment.json"
render compact
if grep -Fq '### Negative verdict' "$CASE_DIR/compact.md"; then
  echo 'assessment bytes outside the receipt rendered no_change_required' >&2
  exit 1
fi

jq '.completeness = "partial" | .outcome = "not_evaluated"
  | .paths = {status:"unavailable"} | .objects = {status:"unavailable"}
  | .knowledge_changes = {status:"unavailable"}' \
  "$ROOT/test/fixture-assessment.json" > "$ADOC_RETAINED_DIR/assessment.json"
render compact
if grep -Fq '### Negative verdict' "$CASE_DIR/compact.md"; then
  echo 'partial completeness rendered no_change_required' >&2
  exit 1
fi
rm "$semantic_assessment" "$ADOC_RETAINED_DIR/receipt-$ADOC_INVOCATION_ID.json"
cp "$ROOT/test/fixture-assessment.json" "$ADOC_RETAINED_DIR/assessment.json"

for tuple in 'partial not_evaluated Assessment incomplete' \
  'error invalid Knowledge structure invalid' \
  'error not_evaluated Assessment not evaluated'; do
  read -r completeness outcome banner <<< "$tuple"
  jq --arg completeness "$completeness" --arg outcome "$outcome" '
    .completeness = $completeness | .outcome = $outcome
    | .paths = {status:"unavailable"} | .objects = {status:"unavailable"}
    | .knowledge_changes = {status:"unavailable"}
  ' "$ROOT/test/fixture-assessment.json" > "$ADOC_RETAINED_DIR/assessment.json"
  render compact
  grep -Fq "$banner" "$CASE_DIR/compact.md"
done

# Deterministic input order must not affect the rendered report.
jq '.paths.value |= reverse | .objects.value |= reverse | .diagnostics |= reverse' \
  "$ROOT/test/fixture-assessment.json" > "$ADOC_RETAINED_DIR/assessment.json"
render compact
cmp "$CASE_DIR/compact-baseline.md" "$ADOC_RUN_DIR/report.md"

# A malformed oversized record is bounded without breaking a comment.
cp "$ROOT/test/fixture-assessment.json" "$ADOC_RETAINED_DIR/assessment.json"
{
  echo '<details><summary>canonical proposals</summary>'
  head -c 70000 /dev/zero | tr '\0' x
  echo '</details>'
} > "$ADOC_RUN_DIR/proposed-drafts.md"
render compact
test "$(jq -Rs length "$ADOC_RUN_DIR/report.md")" -le 60000
grep -RFq 'Oversized record detail omitted' "$ADOC_RUN_DIR/comment-parts"
grep -Fq '**Outcome:**' "$ADOC_RUN_DIR/report.md"
grep -Fq 'Run details and integrity' "$ADOC_RUN_DIR/job-summary.md"

# Oversized deterministic collections keep the outcome and provenance rather
# than slicing through a Markdown record.
jq '
  .paths.value = [range(0;200) as $n | {
    path:("src/" + ($n|tostring) + "-" + ("x" * 1000)),
    classification:(if ($n % 4) == 0 then "covered" elif ($n % 4) == 1 then "provisional" elif ($n % 4) == 2 then "uncovered" else "excluded" end),
    exclusion_reason:(if ($n % 4) == 3 then "generated_output" else null end), matches:[]
  }]
  | .objects.value = [range(0;100) as $n | {
    id:("fixture.object-" + ($n|tostring)), kind:"claim", content_hash:("sha256:" + ("a" * 64)),
    owner:("owner-" + ("x" * 500)), reviewers:[], source:{path:("docs/" + ("x" * 1000)),line:1,column:1},
    authority:"authoritative", changed_in_pr:"no", reasons:[]
  }]
  | .summary = {changed_paths:200,covered:50,provisional:50,uncovered:50,excluded:50,impacted_objects:100}
' "$ROOT/test/fixture-assessment.json" > "$ADOC_RETAINED_DIR/assessment.json"
render detailed
for part in "$ADOC_RUN_DIR"/comment-parts/*.md; do
  test "$(jq -Rs length "$part")" -le 60000
done
grep -Fq '**Outcome:**' "$ADOC_RUN_DIR/report.md"
grep -Fq 'Run details and integrity' "$ADOC_RUN_DIR/job-summary.md"

# Reports split only at renderer-owned block boundaries. The configured cap
# omits lowest-priority trailing blocks; unlimited retains every block.
{
  echo '<!-- adoc:block:summary -->'
  echo '<!-- adoc:pr-report -->'
  echo '## AgentDoc PR Report'
  for index in 1 2 3; do
    echo "<!-- adoc:block:semantic-consistent -->"
    echo "<details><summary>Finding $index</summary>"
    head -c 30000 /dev/zero | tr '\0' x
    echo
    echo '</details>'
  done
} > "$ADOC_RUN_DIR/report.md"
cp "$ADOC_RUN_DIR/report.md" "$CASE_DIR/report-split-source.md"
GITHUB_REPOSITORY=agentdoc/test ADOC_PR_NUMBER=7 COMMENT_MAX_COMMENTS=2 \
  "$ROOT/scripts/finalize-report.sh"
test "$(find "$ADOC_RUN_DIR/comment-parts" -type f -name '*.md' | wc -l | tr -d ' ')" = 2
grep -RFq 'Report detail omitted at the configured comment limit' \
  "$ADOC_RUN_DIR/comment-parts"
if grep -RFq '<!-- adoc:block:' "$ADOC_RUN_DIR/comment-parts"; then
  echo 'internal report block marker reached a comment' >&2
  exit 1
fi

cp "$CASE_DIR/report-split-source.md" "$ADOC_RUN_DIR/report.md"
GITHUB_REPOSITORY=agentdoc/test ADOC_PR_NUMBER=7 COMMENT_MAX_COMMENTS=unlimited \
  "$ROOT/scripts/finalize-report.sh"
test "$(find "$ADOC_RUN_DIR/comment-parts" -type f -name '*.md' | wc -l | tr -d ' ')" = 3
grep -Fq '<!-- adoc:pr-report-part:agentdoc/test#7:002 -->' \
  "$ADOC_RUN_DIR/comment-parts/002.md"

# Nested values consumed by the renderer are validated before retention.
mkdir -p "$CASE_DIR/bin" "$CASE_DIR/validation-run" "$CASE_DIR/validation-retained"
cat > "$CASE_DIR/bin/adoc" <<'EOF'
#!/usr/bin/env bash
cat "$MOCK_ASSESSMENT"
exit "${MOCK_ASSESSMENT_CODE:-0}"
EOF
chmod +x "$CASE_DIR/bin/adoc"
jq '.objects.value[0].changed_in_pr = "maybe"' "$ROOT/test/fixture-assessment.json" \
  > "$CASE_DIR/invalid-assessment.json"
printf '%s\n' '{"assessment":"pending"}' > "$CASE_DIR/validation-run/stages.json"
: > "$CASE_DIR/github-env"
ADOC_RUN_DIR="$CASE_DIR/validation-run" \
ADOC_RETAINED_DIR="$CASE_DIR/validation-retained" \
ADOC_INVOCATION_ID=inv_1_1_validation_0123456789abcdef0123456789abcdef \
ADOC_EVALUATION_DATE=2026-07-22 \
ADOC_REQUESTED_BASE=1111111111111111111111111111111111111111 \
ADOC_COMPARISON_BASE=2222222222222222222222222222222222222222 \
ADOC_HEAD=3333333333333333333333333333333333333333 \
GITHUB_ENV="$CASE_DIR/github-env" MOCK_ASSESSMENT="$CASE_DIR/invalid-assessment.json" \
PATH="$CASE_DIR/bin:$PATH" "$ROOT/scripts/report.sh"
jq -e '.code == "action.assessment_contract_failed"' \
  "$CASE_DIR/validation-run/failure.json" >/dev/null
grep -q '^ADOC_ASSESSMENT_VALID=false$' "$CASE_DIR/github-env"

jq '.completeness = "partial" | .outcome = "not_evaluated"
  | .paths = {status:"unavailable"} | .objects = {status:"unavailable"}
  | .knowledge_changes = {status:"unavailable"}' \
  "$ROOT/test/fixture-assessment.json" > "$CASE_DIR/partial-assessment.json"
mkdir "$CASE_DIR/partial-run" "$CASE_DIR/partial-retained"
printf '%s\n' '{"assessment":"pending"}' > "$CASE_DIR/partial-run/stages.json"
: > "$CASE_DIR/partial-env"
ADOC_RUN_DIR="$CASE_DIR/partial-run" ADOC_RETAINED_DIR="$CASE_DIR/partial-retained" \
ADOC_INVOCATION_ID=inv_1_1_partial_0123456789abcdef0123456789abcdef \
ADOC_EVALUATION_DATE=2026-07-22 \
ADOC_REQUESTED_BASE=1111111111111111111111111111111111111111 \
ADOC_COMPARISON_BASE=2222222222222222222222222222222222222222 \
ADOC_HEAD=3333333333333333333333333333333333333333 \
GITHUB_ENV="$CASE_DIR/partial-env" MOCK_ASSESSMENT="$CASE_DIR/partial-assessment.json" \
MOCK_ASSESSMENT_CODE=2 PATH="$CASE_DIR/bin:$PATH" "$ROOT/scripts/report.sh"
grep -q '^ADOC_ASSESSMENT_VALID=true$' "$CASE_DIR/partial-env"
grep -q '^ADOC_TRUSTED_REQUEST_ELIGIBLE=false$' "$CASE_DIR/partial-env"

echo 'advisory disposition report tests passed'
