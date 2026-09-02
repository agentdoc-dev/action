#!/usr/bin/env bash
# E5.1: propose.sh produces the canonical adoc.proposal.v0 record through
# `adoc proposal-record` and reports its status honestly.
set -euo pipefail

# shellcheck source=test/proposal-scenario.sh
source "$(cd "$(dirname "$0")" && pwd)/proposal-scenario.sh"

REAL_JQ="$(command -v jq)"
export ADOC_RETAINED_DIR="$CASE_DIR/retained" ADOC_PR_NUMBER=7
export ADOC_INVOCATION_ID=inv_1_1_test_0123456789abcdef0123456789abcdef
mkdir -p "$ADOC_RETAINED_DIR"
receipt="$ADOC_RETAINED_DIR/semantic-executor-$ADOC_INVOCATION_ID.json"
semantic_assessment="$ADOC_RETAINED_DIR/semantic-assessment-$ADOC_INVOCATION_ID.json"
semantic_context_binding="$ADOC_RETAINED_DIR/semantic-context-digest-$ADOC_INVOCATION_ID.txt"
execution_status="$CASE_DIR/out/semantic-execution-status.json"
record="$ADOC_RETAINED_DIR/proposal-record-$ADOC_INVOCATION_ID.json"
status="$CASE_DIR/out/proposal-record-status.json"
context_digest="sha256:$(printf 'c%.0s' {1..64})"
assessment_digest=''

write_receipt() { # outcome
  existing_hash="$(jq -r '
    .nodes[] | select(.id == "fixture.ci.green") | .content_hash
  ' "$graph")"
  contradiction_hash="$(jq -r '
    .nodes[] | select(.id == "fixture.ci.conflict") | .content_hash
  ' "$graph")"
  printf '%s\n' "$context_digest" > "$semantic_context_binding"
  jq -n --arg context "$context_digest" --arg head "$head" \
    --arg content "$existing_hash" --arg contradiction "$contradiction_hash" '{
    schema_version:"adoc.semantic_assessment.v0",context_digest:$context,
    base_revision:{system:"git",value:$head},
    head_revision:{system:"git",value:$head},
    identity:{provider:"claude-code",model:"claude-sonnet-5"},
    materiality_policy_version:"adoc.materiality.v0",
    scope:{handle_ids:["fixture.ci.conflict","fixture.ci.green"]},
    findings:[{
      finding_id:"finding-001",classification:"extends_existing_knowledge",
      affected_objects:[{object_id:"fixture.ci.green",content_hash:$content}],
      citations:["fixture.ci.green"],materiality:"material",
      proposed_disposition:"create_knowledge",candidate_updates:[],
      unresolved_questions:[],explanation:"The change extends fixture knowledge."
    },{
      finding_id:"finding-008",classification:"extends_existing_knowledge",
      affected_objects:[{object_id:"fixture.ci.green",content_hash:$content}],
      citations:["fixture.ci.green"],materiality:"material",
      proposed_disposition:"update_existing",candidate_updates:[],
      unresolved_questions:[],explanation:"The existing fixture knowledge must change."
    },{
      finding_id:"finding-009",classification:"contradicts_existing_knowledge",
      affected_objects:[{object_id:"fixture.ci.conflict",content_hash:$contradiction}],
      citations:["fixture.ci.conflict"],materiality:"material",
      proposed_disposition:"update_existing",candidate_updates:[],
      unresolved_questions:[],explanation:"The contradiction needs a lifecycle update."
    }]
  }' > "$semantic_assessment"
  assessment_digest="sha256:$(sha256sum "$semantic_assessment" | awk '{print $1}')"
  if [ "$1" = completed ]; then
    jq -n --arg digest "$assessment_digest" '{
      status:"completed",failure_code:null,assessment_sha256:$digest,
      primary:{request_id:"primary",provider:"claude-code",model:"claude-sonnet-5",
        outcome:"completed",failure_code:null},fallback:null
    }' > "$execution_status"
  else
    jq -n '{
      status:"failed",failure_code:"action.semantic_review_failed",
      assessment_sha256:null,
      primary:{request_id:"primary",provider:"claude-code",model:"claude-sonnet-5",
        outcome:"failed",failure_code:"provider_failed"},fallback:null
    }' > "$execution_status"
  fi
  jq -n --arg outcome "$1" --arg context "$context_digest" \
    --arg assessment "$assessment_digest" '{
      schema_version:"adoc.semantic_executor_receipt.v0",request_id:"primary",
      outcome:$outcome,context_digest:$context,assessment_digest:$assessment,
      adapter:{provider:"claude-code",model:"claude-sonnet-5"}
    }' > "$receipt"
}

expect_skipped() { # reason
  jq -e --arg reason "$1" '
    . == {status:"skipped",reason:$reason,path:null,sha256:null}
  ' "$status" >/dev/null
  test ! -e "$record"
}

# The comparison base is part of every record binding, so a missing or
# malformed base must fail the proposal context before patch production.
cp "$CASE_DIR/out/proposal-context.json" "$CASE_DIR/proposal-context.valid.json"
for mutation in 'del(.revisions.comparison_base)' \
  '.revisions.comparison_base = "not-a-commit"'; do
  jq "$mutation" "$CASE_DIR/proposal-context.valid.json" \
    > "$CASE_DIR/out/proposal-context.json"
  write_candidates
  write_receipt completed
  run_proposals >/dev/null
  jq -e '.status == "error" and .reason == "proposal_context_invalid"
    and .count == 0' "$CASE_DIR/out/proposal-status.json" >/dev/null
  jq -e '. == {status:"error",reason:"proposal_context_invalid",
    path:null,sha256:null}' "$status" >/dev/null
done
mv "$CASE_DIR/proposal-context.valid.json" "$CASE_DIR/out/proposal-context.json"

# T1: a completed semantic receipt plus validated patches yields the retained
# canonical record.
write_candidates
write_receipt completed
run_proposals >/dev/null
jq -e --arg path "$record" '
  .status == "complete" and .reason == "validated" and .path == $path
  and (.sha256 | test("^sha256:[0-9a-f]{64}$"))
' "$status" >/dev/null
test "sha256:$(sha256sum "$record" | awk '{print $1}')" \
  = "$(jq -r .sha256 "$status")"
jq -e --arg head "$head" --arg context "$context_digest" \
  --arg assessment "$assessment_digest" --arg original "$(jq -r '
    .findings[] | select(.finding_id == "finding-008")
    | .affected_objects[0].content_hash
  ' "$semantic_assessment")" '
  .schema_version == "adoc.proposal.v0"
  and (keys == ["bindings","content_bindings","patches",
    "proposal_set_digest","schema_version","supersedes"])
  and .supersedes == null
  and .bindings == {
    base_revision:{system:"git",value:$head},
    head_revision:{system:"git",value:$head},
    change_request:{system:"github_pull_request",id:"7"},
    assessment_digest:("sha256:" + ("a" * 64)),
    semantic_context_digest:$context,
    semantic_assessment_digest:$assessment
  }
  and (.patches | length == 6)
  and ([.patches[].patch_digest] | . == sort)
  and .content_bindings == [{
    object_id:"fixture.ci.green",
    content_hash:$original
  }]
' "$record" >/dev/null
# The body patch intentionally sorts first by digest; content binding must
# still come from logical sequence 1, never digest order.
jq -e '[.patches[] | select(.target == "fixture.ci.green") | .operation]
  == ["replace_body","update_fields"]' "$record" >/dev/null
test "$(jq -r '.patches[].patch_digest' "$record" | sort)" \
  = "$(jq -r .sha256 "$CASE_DIR/out/patch-manifest.ndjson" | sort)"
# T2: the reported proposal identity is the record's proposal_set_digest.
test "$(jq -r .sha256 "$CASE_DIR/out/proposal-status.json")" \
  = "$(jq -r .proposal_set_digest "$record")"
# Rebuilding the record from the same exact inputs yields identical bytes.
jq -sc --arg head "$head" --arg context "$context_digest" \
  --arg assessment "$assessment_digest" '{
    bindings:{
      base_revision:{system:"git",value:$head},
      head_revision:{system:"git",value:$head},
      change_request:{system:"github_pull_request",id:"7"},
      assessment_digest:("sha256:" + ("a" * 64)),
      semantic_context_digest:$context,
      semantic_assessment_digest:$assessment
    },
    patches:map({finding_id,placement_path,page_id,patch_path:.path})
  }' "$CASE_DIR/out/patch-manifest.ndjson" > "$CASE_DIR/rebuild-input.json"
"$ADOC_BIN" proposal-record --input "$CASE_DIR/rebuild-input.json" \
  --out "$CASE_DIR/rebuild-record.json" >/dev/null
cmp "$record" "$CASE_DIR/rebuild-record.json"
# The record carries identifiers only — never branch names or titles.
branch="$(git -C "$ROOT" branch --show-current)"
if [ -n "$branch" ] && grep -Fq "$branch" "$record"; then
  echo "branch name leaked into the proposal record" >&2
  exit 1
fi
if grep -Eq '"(ref|branch|title|head_ref|base_ref)"' "$record"; then
  echo "branch-shaped field leaked into the proposal record" >&2
  exit 1
fi

# A retained patch must agree with the semantic disposition for its finding;
# matching receipt and assessment digests alone are insufficient.
jq '(.findings[] | select(.finding_id == "finding-001")) |= (
  .classification = "consistent" | .materiality = "immaterial"
  | .proposed_disposition = "no_change_required"
)' "$semantic_assessment" > "$semantic_assessment.next"
mv "$semantic_assessment.next" "$semantic_assessment"
assessment_digest="sha256:$(sha256sum "$semantic_assessment" | awk '{print $1}')"
jq --arg digest "$assessment_digest" '.assessment_sha256 = $digest' \
  "$execution_status" > "$execution_status.next"
mv "$execution_status.next" "$execution_status"
jq --arg digest "$assessment_digest" '.assessment_digest = $digest' \
  "$receipt" > "$receipt.next"
mv "$receipt.next" "$receipt"
run_proposals >/dev/null
expect_skipped semantic_receipt_unavailable
write_receipt completed
jq --arg hash "$(jq -r '
  .findings[] | select(.finding_id == "finding-009")
  | .affected_objects[0].content_hash
' "$semantic_assessment")" '
(.findings[] | select(.finding_id == "finding-008")) |= (
  .affected_objects = [{
    object_id:"fixture.ci.conflict",content_hash:$hash
  }]
  | .citations = ["fixture.ci.conflict"]
)' "$semantic_assessment" > "$semantic_assessment.next"
mv "$semantic_assessment.next" "$semantic_assessment"
assessment_digest="sha256:$(sha256sum "$semantic_assessment" | awk '{print $1}')"
jq --arg digest "$assessment_digest" '.assessment_sha256 = $digest' \
  "$execution_status" > "$execution_status.next"
mv "$execution_status.next" "$execution_status"
jq --arg digest "$assessment_digest" '.assessment_digest = $digest' \
  "$receipt" > "$receipt.next"
mv "$receipt.next" "$receipt"
run_proposals >/dev/null
expect_skipped semantic_receipt_unavailable
write_receipt completed

# The executor receipt must identify the exact completed execution evidence.
for mutation in \
  '.context_digest = ("sha256:" + ("e" * 64))' \
  '.request_id = "wrong-request"' \
  '.adapter.model = "wrong-model"' \
  '.assessment_digest = ("sha256:" + ("0" * 64))'; do
  write_receipt completed
  jq "$mutation" "$receipt" > "$receipt.next"
  mv "$receipt.next" "$receipt"
  run_proposals >/dev/null
  expect_skipped semantic_receipt_unavailable
  jq -e '.status == "partial" and .count == 6' \
    "$CASE_DIR/out/proposal-status.json" >/dev/null
done
write_receipt completed

# Matching hashes are insufficient: malformed, wrong-revision, or wrong-model
# retained assessments must not be bound into a canonical proposal record.
for mutation in \
  '.head_revision.value = "wrong-head"' \
  '.identity.model = "wrong-model"' \
  'del(.scope)'; do
  write_receipt completed
  jq "$mutation" "$semantic_assessment" > "$semantic_assessment.next"
  mv "$semantic_assessment.next" "$semantic_assessment"
  assessment_digest="sha256:$(sha256sum "$semantic_assessment" | awk '{print $1}')"
  jq --arg digest "$assessment_digest" '.assessment_sha256 = $digest' \
    "$execution_status" > "$execution_status.next"
  mv "$execution_status.next" "$execution_status"
  jq --arg digest "$assessment_digest" '.assessment_digest = $digest' \
    "$receipt" > "$receipt.next"
  mv "$receipt.next" "$receipt"
  run_proposals >/dev/null
  expect_skipped semantic_receipt_unavailable
done
write_receipt completed

# A successful producer exit is insufficient: malformed output must never be
# retained or reported as a complete canonical record.
mv "$CASE_DIR/bin/adoc" "$CASE_DIR/bin/adoc.real"
cat > "$CASE_DIR/bin/adoc" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = proposal-record ] && [ "\${2:-}" != --help ]; then
  while [ "\$#" -gt 0 ]; do
    [ "\$1" != --out ] || { printf '{}\n' > "\$2"; exit 0; }
    shift
  done
fi
exec "$CASE_DIR/bin/adoc.real" "\$@"
EOF
chmod +x "$CASE_DIR/bin/adoc"
run_proposals >/dev/null
jq -e '. == {status:"error",reason:"proposal_record_failed",path:null,sha256:null}' \
  "$status" >/dev/null
test ! -e "$record"
test "$(cat "$CASE_DIR/out/adoc-propose-code")" = 1
jq -e '.status == "partial" and .count == 6' \
  "$CASE_DIR/out/proposal-status.json" >/dev/null
rm "$CASE_DIR/bin/adoc"
mv "$CASE_DIR/bin/adoc.real" "$CASE_DIR/bin/adoc"

# A successful producer must not omit the exact source-content binding carried
# by an existing-object update patch.
mv "$CASE_DIR/bin/adoc" "$CASE_DIR/bin/adoc.real"
cat > "$CASE_DIR/bin/adoc" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = proposal-record ] && [ "\${2:-}" != --help ]; then
  "$CASE_DIR/bin/adoc.real" "\$@" || exit
  while [ "\$#" -gt 0 ]; do
    if [ "\$1" = --out ]; then
      jq '.content_bindings = []' "\$2" > "\$2.next"
      mv "\$2.next" "\$2"
      exit 0
    fi
    shift
  done
fi
exec "$CASE_DIR/bin/adoc.real" "\$@"
EOF
chmod +x "$CASE_DIR/bin/adoc"
run_proposals >/dev/null
jq -e '. == {status:"error",reason:"proposal_record_failed",path:null,sha256:null}' \
  "$status" >/dev/null
test ! -e "$record"
test "$(cat "$CASE_DIR/out/adoc-propose-code")" = 1
rm "$CASE_DIR/bin/adoc"
mv "$CASE_DIR/bin/adoc.real" "$CASE_DIR/bin/adoc"

# A producer-side patch-byte change must use the normal record error path,
# rather than terminating warn-mode proposal generation from inside the loop.
mv "$CASE_DIR/bin/adoc" "$CASE_DIR/bin/adoc.real"
cat > "$CASE_DIR/bin/adoc" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = proposal-record ] && [ "\${2:-}" != --help ]; then
  "$CASE_DIR/bin/adoc.real" "\$@" || exit
  while [ "\$#" -gt 0 ]; do
    if [ "\$1" = --out ]; then
      jq '.patches[0].patch.reason += " tampered"' "\$2" > "\$2.next"
      mv "\$2.next" "\$2"
      exit 0
    fi
    shift
  done
fi
exec "$CASE_DIR/bin/adoc.real" "\$@"
EOF
chmod +x "$CASE_DIR/bin/adoc"
set +e
run_proposals >/dev/null
propose_exit=$?
set -e
test "$propose_exit" = 0
jq -e '. == {status:"error",reason:"proposal_record_failed",path:null,sha256:null}' \
  "$status" >/dev/null
test ! -e "$record"
test "$(cat "$CASE_DIR/out/adoc-propose-code")" = 1
rm "$CASE_DIR/bin/adoc"
mv "$CASE_DIR/bin/adoc.real" "$CASE_DIR/bin/adoc"

# Optional record plumbing failures preserve the already-proven patch set.
cat > "$CASE_DIR/bin/jq" <<'EOF'
#!/usr/bin/env bash
status_input=false
for arg in "$@"; do
  case "$arg" in
    */proposal-status.json) status_input=true ;;
  esac
done
previous=''
for arg in "$@"; do
  if [ "${FAIL_RECORD_JQ:-}" = bindings ] \
    && [ "$previous" = --slurpfile ] && [ "$arg" = assessment ]; then
    exit 1
  fi
  if [ "${FAIL_RECORD_JQ:-}" = input ] \
    && [[ "$arg" == *'patch_path:.path'* ]]; then
    exit 1
  fi
  if [ "${FAIL_RECORD_JQ:-}" = status ] && [ "$status_input" = true ] \
    && [ "$arg" = '.sha256 = $sha' ]; then
    exit 1
  fi
  previous="$arg"
done
exec "$REAL_JQ" "$@"
EOF
chmod +x "$CASE_DIR/bin/jq"
hash -r
export REAL_JQ
for failure in bindings input status; do
  write_candidates
  write_receipt completed
  FAIL_RECORD_JQ="$failure" run_proposals >/dev/null
  jq -e --arg reason "$(if [ "$failure" = status ]; then
    printf proposal_status_failed
  else
    printf proposal_record_input_failed
  fi)" '. == {status:"error",reason:$reason,path:null,sha256:null}' \
    "$status" >/dev/null
  jq -e '.status == "partial" and .count == 6' \
    "$CASE_DIR/out/proposal-status.json" >/dev/null
  test -s "$CASE_DIR/out/patch-manifest.ndjson"
  test -s "$CASE_DIR/out/proposed-drafts.md"
  test ! -e "$record"
  test "$(cat "$CASE_DIR/out/adoc-propose-code")" = 1
done
rm "$CASE_DIR/bin/jq"
hash -r

# A failure after record production invalidates and removes that record.
mv "$CASE_DIR/bin/adoc" "$CASE_DIR/bin/adoc.real"
cat > "$CASE_DIR/bin/adoc" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = patch ] && [ "\${2:-}" = --check ]; then
  "$CASE_DIR/bin/adoc.real" "\$@" | jq '.proof_obligations = "invalid"'
  exit "\${PIPESTATUS[0]}"
fi
exec "$CASE_DIR/bin/adoc.real" "\$@"
EOF
chmod +x "$CASE_DIR/bin/adoc"
run_proposals >/dev/null 2>&1
jq -e '. == {status:"error",reason:"proposal_render_failed",count:0,sha256:null}' \
  "$CASE_DIR/out/proposal-status.json" >/dev/null
jq -e '. == {status:"error",reason:"proposal_render_failed",path:null,sha256:null}' \
  "$status" >/dev/null
test ! -e "$record"
test "$(cat "$CASE_DIR/out/adoc-propose-code")" = 1
rm "$CASE_DIR/bin/adoc"
mv "$CASE_DIR/bin/adoc.real" "$CASE_DIR/bin/adoc"

# Under `propose-authority: preserve` the validated edits retain the target's
# non-reviewable authority; the record cannot bind them without minting it
# (ADR-0062 §6), so it is honestly skipped and the patches stay available.
context="$CASE_DIR/out/proposal-context.json"
jq '.policies.authority = "preserve"' "$context" > "$context.preserve"
cp "$context" "$context.downgrade"
mv "$context.preserve" "$context"
TEST_AUTHORITY=preserve run_proposals >/dev/null
expect_skipped non_reviewable_status
jq -e '.status == "partial" and .count == 6' \
  "$CASE_DIR/out/proposal-status.json" >/dev/null
mv "$context.downgrade" "$context"

# A contradiction lifecycle transition remains non-reviewable under the
# default downgrade policy, so the canonical record is skipped without
# discarding the validated patch.
jq '.policies.contradictions = "propose"' "$context" > "$context.propose"
cp "$context" "$context.suggest"
mv "$context.propose" "$context"
TEST_CONTRADICTIONS=propose run_proposals >/dev/null
expect_skipped non_reviewable_status
jq -e '.status == "partial" and .count == 7' \
  "$CASE_DIR/out/proposal-status.json" >/dev/null
mv "$context.suggest" "$context"

# T3: every non-produced record is reported honestly and leaves no stale file.
# Missing or incomplete semantic receipt: skipped.
rm "$receipt"
run_proposals >/dev/null
expect_skipped semantic_receipt_unavailable
jq -e '.status == "partial" and .count == 6' \
  "$CASE_DIR/out/proposal-status.json" >/dev/null
write_receipt failed
run_proposals >/dev/null
expect_skipped semantic_receipt_unavailable

# No change-request identity (workflow_dispatch bootstrap): skipped.
write_receipt completed
ADOC_PR_NUMBER='' run_proposals >/dev/null
expect_skipped change_request_unavailable

# A released adoc without `proposal-record`: skipped, proposals unaffected.
mv "$CASE_DIR/bin/adoc" "$CASE_DIR/bin/adoc.real"
cat > "$CASE_DIR/bin/adoc" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" != proposal-record ] || { echo 'error: unrecognized subcommand' >&2; exit 2; }
exec "$CASE_DIR/bin/adoc.real" "\$@"
EOF
chmod +x "$CASE_DIR/bin/adoc"
run_proposals >/dev/null
expect_skipped adoc_command_unavailable
jq -e '.status == "partial" and .count == 6' \
  "$CASE_DIR/out/proposal-status.json" >/dev/null

# A failing `proposal-record`: error, validated patches stay available.
cat > "$CASE_DIR/bin/adoc" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" != proposal-record ] || [ "\${2:-}" = --help ] \
  || { echo 'error: [proposal_record.patch_invalid] injected' >&2; exit 1; }
exec "$CASE_DIR/bin/adoc.real" "\$@"
EOF
run_proposals > "$CASE_DIR/propose-error.log"
jq -e '. == {status:"error",reason:"proposal_record_failed",path:null,sha256:null}' \
  "$status" >/dev/null
test ! -e "$record"
test "$(cat "$CASE_DIR/out/adoc-propose-code")" = 1
jq -e '.status == "partial" and .count == 6' \
  "$CASE_DIR/out/proposal-status.json" >/dev/null
grep -q '::warning::AgentDoc: canonical proposal record failed' \
  "$CASE_DIR/propose-error.log"
rm "$CASE_DIR/bin/adoc"
mv "$CASE_DIR/bin/adoc.real" "$CASE_DIR/bin/adoc"

# No validated proposals: skipped.
jq '.policies.delivery = "atomic"' "$context" > "$context.atomic"
mv "$context.atomic" "$context"
TEST_DELIVERY_POLICY=atomic run_proposals >/dev/null
expect_skipped no_valid_proposals

echo 'proposal record tests passed'
