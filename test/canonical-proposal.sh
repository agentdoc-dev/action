#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=test/proposal-scenario.sh
source "$(cd "$(dirname "$0")" && pwd)/proposal-scenario.sh"

write_candidates
before="$(git -C "$ROOT" diff -- test/fixture-clean)"
run_proposals > "$CASE_DIR/propose.log"
after="$(git -C "$ROOT" diff -- test/fixture-clean)"
test "$before" = "$after"

jq -e '
  .status == "partial"
  and .count == 6
  and (.sha256 | test("^sha256:[0-9a-f]{64}$"))
  and .reason == "some_candidates_rejected"
' "$CASE_DIR/out/proposal-status.json" >/dev/null
test "$(wc -l < "$CASE_DIR/out/patch-manifest.ndjson" | tr -d ' ')" = 6
jq -se '
  ([.[] | select(.operation == "create_object") | .target] == [
    "fixture.proposed.api","fixture.proposed.claim",
    "fixture.proposed.decision","fixture.proposed.task"
  ])
  and ([.[] | select(.target == "fixture.ci.green") | .operation]
    == ["update_fields","replace_body"])
  and all(.[];
    .schema_version == "adoc.patch.v0"
    and (.sha256 | test("^sha256:[0-9a-f]{64}$"))
    and (.check_sha256 | test("^sha256:[0-9a-f]{64}$")))
' "$CASE_DIR/out/patch-manifest.ndjson" >/dev/null

while IFS= read -r patch; do
  jq -e '
    .schema_version == "adoc.patch.v0"
    and (.op | IN("create_object","update_fields","replace_body"))
    and (if .op == "create_object" then (.base_hash | not)
      else (.base_hash | test("^sha256:[0-9a-f]{64}$")) end)
    and (.reason | test("^AgentDoc assessment sha256:[0-9a-f]{64} finding finding-[0-9]{3}\\.$"))
    and .proposer == {
      type:"agent",
      id:"agentdoc-action/claude-code@2.1.215/claude-sonnet-5"
    }
  ' "$patch" >/dev/null
  test "$(tail -c 1 "$patch" | od -An -tuC | tr -d ' ')" = 10
done < <(jq -r .path "$CASE_DIR/out/patch-manifest.ndjson")

grep -q 'Canonical AgentDoc patches' "$CASE_DIR/out/proposed-drafts.md"
grep -q 'canonical &amp; safe' "$CASE_DIR/out/proposed-drafts.md"
grep -q 'Proof obligations' "$CASE_DIR/out/proposed-drafts.md"
grep -q '6 rejected' "$CASE_DIR/out/proposed-drafts.md"
! grep -q 'canonical & safe' "$CASE_DIR/out/proposed-drafts.md"
grep -Fq 'Candidate 9 — duplicate proposal target `fixture.rejected.duplicate`' \
  "$CASE_DIR/out/proposed-drafts.md"
grep -Fq 'AgentDoc: proposal candidate 9 rejected: duplicate proposal target `fixture.rejected.duplicate`' \
  "$CASE_DIR/propose.log"
first_digest="$(jq -r .sha256 "$CASE_DIR/out/proposal-status.json")"
first_order="$(jq -r .sha256 "$CASE_DIR/out/patch-manifest.ndjson")"

# Bootstrap accepts only candidates that can reduce uncovered path debt after
# human promotion.
jq '[.[] | select(.target == "fixture.proposed.claim"
  or .target == "fixture.proposed.decision"
  or .target == "fixture.ci.green")
  | if .target == "fixture.ci.green"
    then .fields = {impacts:"[src/new.rs]"} else . end]' \
  "$CASE_DIR/out/proposal-candidates.json" > "$CASE_DIR/bootstrap-candidates.json"
mv "$CASE_DIR/bootstrap-candidates.json" "$CASE_DIR/out/proposal-candidates.json"
jq '.bootstrap = {enabled:true,selected_paths:["src/new.rs"]}' \
  "$CASE_DIR/out/proposal-context.json" > "$CASE_DIR/bootstrap-context.json"
mv "$CASE_DIR/bootstrap-context.json" "$CASE_DIR/out/proposal-context.json"
BOOTSTRAP=true run_proposals
jq -e '.status == "partial" and .count == 1
  and .reason == "some_candidates_rejected"' \
  "$CASE_DIR/out/proposal-status.json" >/dev/null
grep -Fq 'bootstrap candidate does not cover a selected path' \
  "$CASE_DIR/out/rejected.md"
grep -Fq 'bootstrap candidate removes existing impacts' \
  "$CASE_DIR/out/rejected.md"

write_candidates
jq '.bootstrap = {enabled:false,selected_paths:[]}' \
  "$CASE_DIR/out/proposal-context.json" > "$CASE_DIR/non-bootstrap-context.json"
mv "$CASE_DIR/non-bootstrap-context.json" "$CASE_DIR/out/proposal-context.json"
jq 'reverse' "$CASE_DIR/out/proposal-candidates.json" > "$CASE_DIR/reversed.json"
mv "$CASE_DIR/reversed.json" "$CASE_DIR/out/proposal-candidates.json"
run_proposals
test "$(jq -r .sha256 "$CASE_DIR/out/proposal-status.json")" = "$first_digest"
test "$(jq -r .sha256 "$CASE_DIR/out/patch-manifest.ndjson")" = "$first_order"

jq '.policies.authority = "preserve"' "$CASE_DIR/out/proposal-context.json" \
  > "$CASE_DIR/context.preserve"
mv "$CASE_DIR/context.preserve" "$CASE_DIR/out/proposal-context.json"
TEST_AUTHORITY=preserve run_proposals
jq -se '
  [.[] | select(.target == "fixture.ci.green")]
  | length == 2 and all(.[]; .status == "verified")
' "$CASE_DIR/out/patch-manifest.ndjson" >/dev/null
jq -e '.changes.fields | has("status") | not' \
  "$(jq -r 'select(.target == "fixture.ci.green"
    and .operation == "update_fields") | .path' \
    "$CASE_DIR/out/patch-manifest.ndjson")" >/dev/null

jq '.policies.authority = "downgrade" | .policies.delivery = "atomic"' \
  "$CASE_DIR/out/proposal-context.json" \
  > "$CASE_DIR/context.atomic"
mv "$CASE_DIR/context.atomic" "$CASE_DIR/out/proposal-context.json"
TEST_DELIVERY_POLICY=atomic run_proposals
jq -e '.status == "skipped" and .reason == "atomic_candidate_rejection"
  and .count == 0 and .sha256 == null' \
  "$CASE_DIR/out/proposal-status.json" >/dev/null
test ! -s "$CASE_DIR/out/patch-manifest.ndjson"

rm "$CASE_DIR/out/proposal-candidates.json" "$CASE_DIR/out/proposal-context.json"
jq -n '{status:"skipped",reason:"no_candidate_scope",
  schema_version:null,path:null,sha256:null}' \
  > "$CASE_DIR/out/semantic-status.json"
run_proposals
jq -e '.status == "skipped" and .reason == "no_candidate_scope" and .count == 0' \
  "$CASE_DIR/out/proposal-status.json" >/dev/null
grep -Fq "**Proposal generation skipped:** \`no_candidate_scope\`." \
  "$CASE_DIR/out/proposed-drafts.md"

echo 'canonical proposal tests passed'
