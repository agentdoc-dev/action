#!/usr/bin/env bash
# E5.1: propose.sh produces the canonical adoc.proposal.v0 record through
# `adoc proposal-record` and reports its status honestly.
set -euo pipefail

# shellcheck source=test/proposal-scenario.sh
source "$(cd "$(dirname "$0")" && pwd)/proposal-scenario.sh"

export ADOC_RETAINED_DIR="$CASE_DIR/retained" ADOC_PR_NUMBER=7
export ADOC_INVOCATION_ID=inv_1_1_test_0123456789abcdef0123456789abcdef
mkdir -p "$ADOC_RETAINED_DIR"
receipt="$ADOC_RETAINED_DIR/semantic-executor-$ADOC_INVOCATION_ID.json"
record="$ADOC_RETAINED_DIR/proposal-record-$ADOC_INVOCATION_ID.json"
status="$CASE_DIR/out/proposal-record-status.json"
context_digest="sha256:$(printf 'c%.0s' {1..64})"
assessment_digest="sha256:$(printf 'd%.0s' {1..64})"

write_receipt() { # outcome
  jq -n --arg outcome "$1" --arg context "$context_digest" \
    --arg assessment "$assessment_digest" '{
      schema_version:"adoc.semantic_executor_receipt.v0",request_id:"primary",
      outcome:$outcome,context_digest:$context,assessment_digest:$assessment,
      adapter:{provider:"anthropic",model:"claude-sonnet-5"}
    }' > "$receipt"
}

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
  --arg assessment "$assessment_digest" '
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
  and (.content_bindings | length == 1)
' "$record" >/dev/null
test "$(jq -r '.patches[].patch_digest' "$record" | sort)" \
  = "$(jq -r .sha256 "$CASE_DIR/out/patch-manifest.ndjson" | sort)"
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

echo 'proposal record tests passed'
