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
for heading in '### What to do' 'Coverage · 4 changed paths' \
  'Affected knowledge · 3 objects' 'Diagnostics · 1 error · 1 warning' \
  'Run details and integrity'; do
  grep -Fq "$heading" "$CASE_DIR/compact.md"
done
for heading in '### Validation' '### Changed paths' '### Knowledge signals' \
  '### Affected knowledge' '### Required owners and proof obligations'; do
  if grep -Fq "$heading" "$CASE_DIR/compact.md"; then
    echo "legacy section $heading still rendered" >&2
    exit 1
  fi
done
# Brief anatomy: marker first, stamp second, verdict alert, five-row result table.
test "$(sed -n 1p "$CASE_DIR/compact.md")" = '<!-- adoc:pr-report -->'
sed -n 2p "$CASE_DIR/compact.md" | grep -Eq '^Assessed `[0-9a-f]{7}` · '
grep -Fq '> [!WARNING]' "$CASE_DIR/compact.md"
grep -Fq '> **Knowledge review needed.** 1 changed path without knowledge coverage, 1 provisional path and 1 proof obligation need a decision.' "$CASE_DIR/compact.md"
grep -Fq '| Area | Result |' "$CASE_DIR/compact.md"
grep -Fq '| Structure | failed · 1 error (1 changed · 0 unchanged · 0 unattributed) · 1 warning |' "$CASE_DIR/compact.md"
grep -Fq '| Coverage | needs attention · 1 uncovered · 1 provisional · 1 covered · 1 excluded |' "$CASE_DIR/compact.md"
grep -Fq '| Human review | required · 1 owner · 1 proof obligation |' "$CASE_DIR/compact.md"
grep -Fq '| Semantic review | not requested |' "$CASE_DIR/compact.md"
grep -Fq '| Knowledge update | not requested |' "$CASE_DIR/compact.md"
# Run details rows replace the former standalone provenance sections.
grep -Fq '| Field | Value |' "$CASE_DIR/compact.md"
grep -Fq '| Assessed head | <code>3333333333333333333333333333333333333333</code> |' "$CASE_DIR/compact.md"
grep -Fq '· merge base |' "$CASE_DIR/compact.md"
grep -Fq '| Requested base | <code>1111111111111111111111111111111111111111</code> |' "$CASE_DIR/compact.md"
grep -Fq '| Assessment | <code>complete / uncovered</code> · <code>sha256:' "$CASE_DIR/compact.md"
grep -Fq 'The receipt, not this comment, is the record.' "$CASE_DIR/compact.md"
grep -Fq '<sub>adoc v0.3.4 · action v1.6.0-test · enforcement advisory · scope full · ' "$CASE_DIR/compact.md"
for section in '### Deterministic assessment' '### Semantic assessment' '### Negative verdict' \
  '### Cloud hand-off' '### Repository baseline'; do
  if grep -Fq "$section" "$CASE_DIR/compact.md"; then
    echo "folded section $section still rendered" >&2
    exit 1
  fi
done
# What to do: one bullet per principal, permalinks at the assessed head, no @-mentions.
grep -Fq -e '- **<code>alice</code>** — decide on [<code>billing.covered</code>](https://github.com/agentdoc/test/blob/3333333333333333333333333333333333333333/docs/billing.adoc#L4). Its source changed in this PR while <code>verified</code>. Review impacted authoritative claim. Required evidence <code>source_code</code>. Either re-verify (read the new code, then set <code>verified_at: 2026-07-22</code>) or set <code>status: draft</code> until reviewed. Push the edit to this branch.' "$CASE_DIR/compact.md"
grep -Fq -e '- **Author** — <code>src/uncovered.rs</code> matches no Knowledge Object.' "$CASE_DIR/compact.md"
grep -Fq 'If the workflow owner enables <code>semantic-review</code>, AgentDoc drafts this.' "$CASE_DIR/compact.md"
if sed -n '/^### What to do$/,/^| Area | Result |$/p' "$CASE_DIR/compact.md" | grep -Fq '@'; then
  echo 'What to do section contains an @-mention' >&2
  exit 1
fi
# Coverage, Affected knowledge and Diagnostics tables replace the legacy sections.
grep -Fq '<details open><summary>Coverage · 4 changed paths</summary>' "$CASE_DIR/compact.md"
grep -Fq '| Path | Class | Knowledge |' "$CASE_DIR/compact.md"
grep -Fq '| <code>src/uncovered.rs</code> | **uncovered** | — |' "$CASE_DIR/compact.md"
grep -Fq '| <code>src/provisional.rs</code> | provisional | <code>billing.provisional</code> · matched by <code>source_path</code> only |' "$CASE_DIR/compact.md"
grep -Fq '| <code>dist/generated.js</code> | excluded | <code>generated_output</code> |' "$CASE_DIR/compact.md"
grep -Fq '<details open><summary>Affected knowledge · 3 objects</summary>' "$CASE_DIR/compact.md"
grep -Fq '| Decision | Object | Kind · status | Owner | Evidence |' "$CASE_DIR/compact.md"
grep -Fq '| **owner decision needed** · source changed in this PR | <code>billing.covered</code> | claim · <code>verified</code> | <code>team-billing</code> · <code>alice</code> | high |' "$CASE_DIR/compact.md"
grep -Fq '| none · open contradiction, change unknown | <code>billing.conflict</code> |' "$CASE_DIR/compact.md"
grep -Fq '| claim · <code>stale</code> |' "$CASE_DIR/compact.md"
grep -Fq '*Source changed in this PR* means' "$CASE_DIR/compact.md"
grep -Fq '<details open><summary>Diagnostics · 1 error · 1 warning</summary>' "$CASE_DIR/compact.md"
grep -Fq -e '- **error** <code>schema.test</code> · <code>docs/billing.adoc:12:1</code> — ' "$CASE_DIR/compact.md"
grep -Fq -e ' *changed in this PR*' "$CASE_DIR/compact.md"
grep -Fq '&lt;img src=x onerror=alert(1)&gt;' "$CASE_DIR/compact.md"
grep -Fq 'Unsafe &#124; &lt;!-- adoc:pr-report --&gt; marker' "$CASE_DIR/compact.md"
if grep -Fq '<img src=x' "$CASE_DIR/compact.md" \
  || grep -Fq '<!-- adoc:pr-report --> marker' "$CASE_DIR/compact.md"; then
  echo 'unescaped repository content reached the report' >&2
  exit 1
fi

# Non-compact styles render the same designed tables and must not error.
render table
grep -Fq '| Path | Class | Knowledge |' "$CASE_DIR/table.md"
render detailed
grep -Fq '| Decision | Object | Kind · status | Owner | Evidence |' "$CASE_DIR/detailed.md"

jq -n '{status:"skipped",count:0,sha256:null,reason:"no_candidate_scope"}' \
  > "$ADOC_RUN_DIR/proposal-status.json"
PROPOSE=true PROPOSE_DELIVERY=pr REPORT_STYLE=compact ENFORCEMENT=advisory \
  SCOPE=full ADOC_VERSION=v0.3.4 "$ROOT/scripts/compose.sh"
COMMENT_MAX_COMMENTS=5 "$ROOT/scripts/finalize-report.sh"
grep -Fq 'No knowledge update was proposed' "$ADOC_RUN_DIR/report.md"
grep -Fq 'no follow-up pull request was created' "$ADOC_RUN_DIR/report.md"
grep -Fq '<details><summary>Proposal audit metadata</summary>' "$ADOC_RUN_DIR/report.md"
grep -Fq 'no_candidate_scope' "$ADOC_RUN_DIR/report.md"
grep -Fq '| Knowledge update | none proposed · no follow-up PR expected |' "$ADOC_RUN_DIR/report.md"
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
  schema_version:"adoc.pr_assessment_receipt.v4",
  created_at:"2026-07-22T09:38:00Z",
  assessment:{sha256:$deterministic},
  semantic_assessment:{status:"completed",failure_code:null,
    assessment_sha256:$digest,
    primary:{request_id:"primary",provider:"test",model:"test-v1",
      outcome:"completed",failure_code:null},fallback:null}
}' > "$ADOC_RETAINED_DIR/receipt-$ADOC_INVOCATION_ID.json"
render compact
acceptance='Merging under branch protection records acceptance of this negative verdict by the merging principal.'
test "$(grep -Fc "$acceptance" "$CASE_DIR/compact.md")" = 1
sed -n '/<summary>Run details and integrity<\/summary>/,/<\/details>/p' "$CASE_DIR/compact.md" \
  | grep -Fq "$acceptance"
grep -Fq '| Knowledge graph | <code>adoc.graph.v5</code> · <code>sha256:1111111111111111111111111111111111111111111111111111111111111111</code> · object set <code>sha256:2222222222222222222222222222222222222222222222222222222222222222</code> |' "$CASE_DIR/compact.md"
grep -Fq '| Receipt | <code>adoc.pr_assessment_receipt.v4</code> ·' "$CASE_DIR/compact.md"
grep -Fq '| Assessment | <code>complete / uncovered</code> · <code>sha256:' "$CASE_DIR/compact.md"
test "$(sed -n 2p "$CASE_DIR/compact.md")" = 'Assessed `3333333` · 2026-07-22 09:38 UTC'

jq '.summary.changed_paths = 999' "$ROOT/test/fixture-assessment.json" \
  > "$ADOC_RETAINED_DIR/assessment.json"
render compact
if grep -Fq "$acceptance" "$CASE_DIR/compact.md"; then
  echo 'assessment bytes outside the receipt rendered no_change_required' >&2
  exit 1
fi

jq '.completeness = "partial" | .outcome = "not_evaluated"
  | .paths = {status:"unavailable"} | .objects = {status:"unavailable"}
  | .knowledge_changes = {status:"unavailable"}' \
  "$ROOT/test/fixture-assessment.json" > "$ADOC_RETAINED_DIR/assessment.json"
render compact
if grep -Fq "$acceptance" "$CASE_DIR/compact.md"; then
  echo 'partial completeness rendered no_change_required' >&2
  exit 1
fi
rm "$semantic_assessment" "$ADOC_RETAINED_DIR/receipt-$ADOC_INVOCATION_ID.json"
cp "$ROOT/test/fixture-assessment.json" "$ADOC_RETAINED_DIR/assessment.json"

for tuple in 'partial not_evaluated' 'error invalid' 'error not_evaluated'; do
  read -r completeness outcome <<< "$tuple"
  jq --arg completeness "$completeness" --arg outcome "$outcome" '
    .completeness = $completeness | .outcome = $outcome
    | .paths = {status:"unavailable"} | .objects = {status:"unavailable"}
    | .knowledge_changes = {status:"unavailable"}
  ' "$ROOT/test/fixture-assessment.json" > "$ADOC_RETAINED_DIR/assessment.json"
  render compact
  grep -Fq "| Assessment | <code>$completeness / $outcome</code> ·" "$CASE_DIR/compact.md"
done

# Deterministic input order must not affect the rendered report. The Assessment
# digest is a hash of the assessment bytes, so permuting keys changes it
# legitimately; every other byte of the report must be identical.
jq '.paths.value |= reverse | .objects.value |= reverse | .diagnostics |= reverse' \
  "$ROOT/test/fixture-assessment.json" > "$ADOC_RETAINED_DIR/assessment.json"
render compact
strip_assessment_digest() {
  sed 's/^| Assessment | \(.*\) · <code>sha256:[0-9a-f]*<\/code> |$/| Assessment | \1 |/' "$1"
}
diff <(strip_assessment_digest "$CASE_DIR/compact-baseline.md") \
  <(strip_assessment_digest "$ADOC_RUN_DIR/report.md")

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
grep -Fq '| Area | Result |' "$ADOC_RUN_DIR/report.md"
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
grep -Fq '| Area | Result |' "$ADOC_RUN_DIR/report.md"
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

# Verdict vocabulary: one alert per state, driven by validation, proposal and
# delivery facts plus the sync policy.
rm -f "$ADOC_RUN_DIR/proposed-drafts.md"
verdict_render() { # renders with the current env and returns the report path
  "$ROOT/scripts/compose.sh"
  COMMENT_MAX_COMMENTS=5 "$ROOT/scripts/finalize-report.sh"
}

jq '.validation = {errors_full:0,errors_changed:0,errors_unchanged:0,errors_unattributed:0,warnings:0}
  | .summary.uncovered = 0 | .summary.provisional = 0 | .summary.covered = 3
  | .proof_obligations = [] | .required_reviewers = []' \
  "$ROOT/test/fixture-assessment.json" > "$ADOC_RETAINED_DIR/assessment.json"
REPORT_STYLE=compact ENFORCEMENT=advisory SCOPE=full ADOC_VERSION=v0.3.4 verdict_render
grep -Fq '> [!TIP]' "$ADOC_RUN_DIR/report.md"
grep -Fq '**Consistent with knowledge.**' "$ADOC_RUN_DIR/report.md"
grep -Fq '| Human review | none required |' "$ADOC_RUN_DIR/report.md"
if grep -Fq '### What to do' "$ADOC_RUN_DIR/report.md"; then
  echo 'consistent report addressed an action to someone' >&2
  exit 1
fi
grep -Fq '<details><summary>Coverage · ' "$ADOC_RUN_DIR/report.md"
grep -Fq '<details><summary>Diagnostics · none</summary>' "$ADOC_RUN_DIR/report.md"

cp "$ROOT/test/fixture-assessment.json" "$ADOC_RETAINED_DIR/assessment.json"
REPORT_STYLE=compact ENFORCEMENT=strict SCOPE=full ADOC_VERSION=v0.3.4 verdict_render
# errors alone do not block: finalize.sh only fails the check on error/invalid
grep -Fq '> [!WARNING]' "$ADOC_RUN_DIR/report.md"
! grep -Fq '**Blocked by structural errors.**' "$ADOC_RUN_DIR/report.md"
jq '.completeness = "error" | .outcome = "invalid"
  | .validation = {errors_full:3,errors_changed:0,errors_unchanged:3,errors_unattributed:0,warnings:0}' \
  "$ROOT/test/fixture-assessment.json" > "$ADOC_RETAINED_DIR/assessment.json"
REPORT_STYLE=compact ENFORCEMENT=strict SCOPE=full ADOC_VERSION=v0.3.4 verdict_render
grep -Fq '> [!CAUTION]' "$ADOC_RUN_DIR/report.md"
grep -Fq '**Blocked by structural errors.** 3 errors in Knowledge Object sources (none in sources changed by this PR).' "$ADOC_RUN_DIR/report.md"
REPORT_STYLE=compact ENFORCEMENT=strict SCOPE=diff ADOC_VERSION=v0.3.4 verdict_render
! grep -Fq '> [!CAUTION]' "$ADOC_RUN_DIR/report.md"
jq '.validation.errors_changed = 1 | .validation.errors_unchanged = 2' \
  "$ADOC_RETAINED_DIR/assessment.json" > "$ADOC_RETAINED_DIR/assessment.tmp" \
  && mv "$ADOC_RETAINED_DIR/assessment.tmp" "$ADOC_RETAINED_DIR/assessment.json"
REPORT_STYLE=compact ENFORCEMENT=strict SCOPE=diff ADOC_VERSION=v0.3.4 verdict_render
grep -Fq '**Blocked by structural errors.** 1 error in Knowledge Object sources changed by this PR.' "$ADOC_RUN_DIR/report.md"
# Blocked: the Author bullet lists the errors and Diagnostics comes first.
grep -Fq -e '- **Author** — fix [<code>docs/billing.adoc</code>](https://github.com/agentdoc/test/blob/3333333333333333333333333333333333333333/docs/billing.adoc#L12): line 12 <code>schema.test</code> ' "$ADOC_RUN_DIR/report.md"
grep -Fq '. Run <code>adoc check</code> locally to confirm.' "$ADOC_RUN_DIR/report.md"
grep -Fq 'Errors are also posted as inline annotations on the changed lines.' "$ADOC_RUN_DIR/report.md"
test "$(grep -n 'summary>Diagnostics · ' "$ADOC_RUN_DIR/report.md" | cut -d: -f1)" \
  -lt "$(grep -n 'summary>Coverage · ' "$ADOC_RUN_DIR/report.md" | cut -d: -f1)"
# Hostile paths never link outside the repo blob, and permuting obligations or
# equal-keyed diagnostics renders byte-identical output.
jq '.objects.value[0].source.path = "../../evil/README.md"
  | .diagnostics = [
      {code:"dup.code",severity:"error",message:"BBB",source:{path:"../x.rs",line:3,column:2},changed_in_pr:"yes"},
      {code:"dup.code",severity:"error",message:"AAA",source:{path:"../x.rs",line:3,column:1},changed_in_pr:"yes"}]
  | .proof_obligations += [{object_id:"billing.covered",kind:"claim",reason:"Second obligation.",required_evidence:["tests"]}]' \
  "$ADOC_RETAINED_DIR/assessment.json" > "$ADOC_RETAINED_DIR/hostile-a.json"
jq '.diagnostics |= reverse | .proof_obligations |= reverse | .objects.value |= reverse' \
  "$ADOC_RETAINED_DIR/hostile-a.json" > "$ADOC_RETAINED_DIR/hostile-b.json"
for v in a b; do
  cp "$ADOC_RETAINED_DIR/hostile-$v.json" "$ADOC_RETAINED_DIR/assessment.json"
  REPORT_STYLE=compact ENFORCEMENT=strict SCOPE=diff ADOC_VERSION=v0.3.4 verdict_render
  cp "$ADOC_RUN_DIR/report.md" "$ADOC_RETAINED_DIR/hostile-$v.md"
done
cmp <(grep -v "^| Assessment |" "$ADOC_RETAINED_DIR/hostile-a.md") \
  <(grep -v "^| Assessment |" "$ADOC_RETAINED_DIR/hostile-b.md") # digest row differs by construction
! grep -Fq '/../' "$ADOC_RETAINED_DIR/hostile-a.md"
grep -Fq -e '- **Author** — fix <code>../x.rs</code>: line 3 <code>dup.code</code> AAA; line 3 <code>dup.code</code> BBB.' "$ADOC_RETAINED_DIR/hostile-a.md"
grep -Fq 'Review impacted authoritative claim. Required evidence <code>source_code</code>. Second obligation. Required evidence <code>tests</code>.' "$ADOC_RETAINED_DIR/hostile-a.md"
# not_evaluated outcomes fail the check in finalize.sh; the headline must say so
# before any coverage or delivery verdict.
jq '.completeness = "partial" | .outcome = "not_evaluated"
  | .validation = {errors_full:0,errors_changed:0,errors_unchanged:0,errors_unattributed:0,warnings:0}
  | .summary.uncovered = 0 | .summary.provisional = 0 | .summary.covered = 3
  | .proof_obligations = [] | .required_reviewers = []' \
  "$ROOT/test/fixture-assessment.json" > "$ADOC_RETAINED_DIR/assessment.json"
REPORT_STYLE=compact ENFORCEMENT=advisory SCOPE=full ADOC_VERSION=v0.3.4 verdict_render
grep -Fq '> [!CAUTION]' "$ADOC_RUN_DIR/report.md"
grep -Fq '**Assessment incomplete.** AgentDoc could not evaluate this change (completeness `partial`, outcome `not_evaluated`). The check fails with `action.assessment_partial` until a rerun completes.' "$ADOC_RUN_DIR/report.md"
! grep -Fq '**Consistent with knowledge.**' "$ADOC_RUN_DIR/report.md"
jq '.completeness = "error"' "$ADOC_RETAINED_DIR/assessment.json" > "$ADOC_RETAINED_DIR/assessment.tmp" \
  && mv "$ADOC_RETAINED_DIR/assessment.tmp" "$ADOC_RETAINED_DIR/assessment.json"
REPORT_STYLE=compact ENFORCEMENT=advisory SCOPE=full ADOC_VERSION=v0.3.4 verdict_render
grep -Fq 'The check fails with `action.assessment_not_evaluated` until a rerun completes.' "$ADOC_RUN_DIR/report.md"
cp "$ROOT/test/fixture-assessment.json" "$ADOC_RETAINED_DIR/assessment.json"

jq -n '{status:"complete",count:2,sha256:("sha256:" + ("b" * 64)),reason:"validated"}' \
  > "$ADOC_RUN_DIR/proposal-status.json"
PROPOSE=true PROPOSE_DELIVERY=comment REPORT_STYLE=compact ENFORCEMENT=advisory \
  SCOPE=full ADOC_VERSION=v0.3.4 verdict_render
grep -Fq '> [!IMPORTANT]' "$ADOC_RUN_DIR/report.md"
grep -Fq '**2 knowledge updates proposed.**' "$ADOC_RUN_DIR/report.md"
grep -Fq '| Knowledge update | drafted · 2 patches · not delivered |' "$ADOC_RUN_DIR/report.md"

jq -n '{status:"complete",mode:"pr",reason:null,
  assessed_head:"3333333333333333333333333333333333333333",delivery_commit:null,
  branch:"adoc/proposals/pr-7",url:"https://github.com/agentdoc/test/pull/483"}' \
  > "$ADOC_RUN_DIR/delivery-status.json"
PROPOSE=true PROPOSE_DELIVERY=pr SYNC_POLICY=required REPORT_STYLE=compact \
  ENFORCEMENT=advisory SCOPE=full ADOC_VERSION=v0.3.4 verdict_render
grep -Fq '**Knowledge sync pending.**' "$ADOC_RUN_DIR/report.md"
grep -Fq 'action.knowledge_sync_pending' "$ADOC_RUN_DIR/report.md"
grep -Fq '| Knowledge update | delivered · draft PR #483 · 2 patches |' "$ADOC_RUN_DIR/report.md"

jq -n '{status:"complete",mode:"commit",reason:null,
  assessed_head:"3333333333333333333333333333333333333333",
  delivery_commit:"c2d9a01f7e3b5d9a2c4e6f8b0d1a3c5e7f9b2d4a",branch:"feat/x",url:null}' \
  > "$ADOC_RUN_DIR/delivery-status.json"
PROPOSE=true PROPOSE_DELIVERY=commit REPORT_STYLE=compact ENFORCEMENT=advisory \
  SCOPE=full ADOC_VERSION=v0.3.4 verdict_render
grep -Fq '**Knowledge update committed.**' "$ADOC_RUN_DIR/report.md"
grep -Fq '**Pull before pushing again.**' "$ADOC_RUN_DIR/report.md"
grep -Fq '| Knowledge update | committed `c2d9a01` · 2 patches |' "$ADOC_RUN_DIR/report.md"
jq '.count = 1' "$ADOC_RUN_DIR/proposal-status.json" > "$ADOC_RUN_DIR/proposal-status.tmp" \
  && mv "$ADOC_RUN_DIR/proposal-status.tmp" "$ADOC_RUN_DIR/proposal-status.json"
PROPOSE=true PROPOSE_DELIVERY=commit REPORT_STYLE=compact ENFORCEMENT=advisory \
  SCOPE=full ADOC_VERSION=v0.3.4 verdict_render
grep -Fq '1 validated patch was fast-forwarded' "$ADOC_RUN_DIR/report.md"
grep -Fq '| Knowledge update | committed `c2d9a01` · 1 patch |' "$ADOC_RUN_DIR/report.md"
rm "$ADOC_RUN_DIR/delivery-status.json"
PROPOSE=true PROPOSE_DELIVERY=comment REPORT_STYLE=compact ENFORCEMENT=advisory \
  SCOPE=full ADOC_VERSION=v0.3.4 verdict_render
grep -Fq '**1 knowledge update proposed.** Review it below' "$ADOC_RUN_DIR/report.md"
rm "$ADOC_RUN_DIR/proposal-status.json"
cp "$ROOT/test/fixture-assessment.json" "$ADOC_RETAINED_DIR/assessment.json"

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
