#!/usr/bin/env bash
# Converts validated private model candidates into canonical AgentDoc patches
# and proves them in one disposable exact-head sandbox.
set -uo pipefail

OUT="${ADOC_RUN_DIR:-${RUNNER_TEMP:?}}"

proposal_status() { # status, reason, count, optional digest
  jq -n --arg status "$1" --arg reason "$2" --argjson count "${3:-0}" \
    --arg sha "${4:-}" '{
      status:$status,count:$count,
      sha256:(if $sha == "" then null else $sha end),
      reason:$reason
    }' > "$OUT/proposal-status.json"
}

record_status() { # status, reason, optional path, optional digest
  jq -n --arg status "$1" --arg reason "$2" --arg path "${3:-}" \
    --arg sha "${4:-}" '{
      status:$status,reason:$reason,
      path:(if $path == "" then null else $path end),
      sha256:(if $sha == "" then null else $sha end)
    }' > "$OUT/proposal-record-status.json"
}

skip() {
  proposal_status skipped "$1" 0
  printf "%s\n" "> ℹ️ **Proposal generation skipped:** \`$1\`." \
    > "$OUT/proposed-drafts.md"
  exit 0
}

proposal_status skipped no_candidate_scope 0
record_status skipped no_valid_proposals
echo 0 > "$OUT/adoc-propose-code"
record=''
if [ -n "${ADOC_RETAINED_DIR:-}" ] && [ -n "${ADOC_INVOCATION_ID:-}" ]; then
  record="$ADOC_RETAINED_DIR/proposal-record-${ADOC_INVOCATION_ID}.json"
  rm -f -- "$record"
fi
repo=''
out_physical="$(cd "$OUT" && pwd -P)"
sandbox="$out_physical/proposal-worktree"

cleanup() {
  if [ -n "$repo" ] && git -C "$repo" worktree list --porcelain 2>/dev/null \
    | grep -Fqx "worktree $sandbox"; then
    git -C "$repo" worktree remove --force "$sandbox" >/dev/null 2>&1 || :
  fi
  rm -rf -- "$sandbox" "$OUT"/proposal-build-* "$OUT/proposal-object-set.json"
  rm -f -- "$OUT/patch-manifest.pending.ndjson" \
    "$OUT/patch-manifest.screened.ndjson" "$OUT/proposal-digests.json" \
    "$OUT/proposal-record-input.json"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

degrade() {
  echo 1 > "$OUT/adoc-propose-code"
  proposal_status error "$1" 0
  rm -f "$OUT/proposed-drafts.md" "$OUT/patch-manifest.ndjson"
  if [ "${PROPOSE_ON_ERROR:-warn}" = fail ]; then
    echo "::error::AgentDoc: canonical proposal validation failed ($1)"
  else
    echo "::warning::AgentDoc: canonical proposal validation failed ($1); deterministic assessment remains available"
  fi
  exit 0
}

if [ "${ADOC_PROPOSE_ELIGIBLE:-true}" != true ]; then
  skip untrusted_pr
fi
if [ -s "$OUT/provider-stage-error" ]; then
  degrade "$(cat "$OUT/provider-stage-error")"
fi
if [ ! -s "$OUT/proposal-candidates.json" ] || [ ! -s "$OUT/proposal-context.json" ]; then
  reason="$(jq -r '.reason // empty' "$OUT/semantic-status.json" 2>/dev/null || true)"
  case "$reason" in
    no_candidate_scope | no_textual_hunks | credentials_unavailable | untrusted_pr)
      skip "$reason"
      ;;
  esac
  degrade proposal_context_unavailable
fi
if ! jq -e 'type == "array" and length <= 100' \
  "$OUT/proposal-candidates.json" >/dev/null 2>&1; then
  degrade proposal_candidate_contract_failed
fi
if [ "$(jq length "$OUT/proposal-candidates.json")" -eq 0 ]; then
  skip no_candidate_scope
fi
if ! jq -e '
  type == "object"
  and (.assessment_sha256 | test("^sha256:[0-9a-f]{64}$"))
  and (.revisions.head | test("^[0-9a-f]{40}$"))
  and (.evaluation_date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
  and (.graph_sha256 | test("^sha256:[0-9a-f]{64}$"))
  and (.object_set_sha256 | test("^sha256:[0-9a-f]{64}$"))
  and .policies.authority == ($ENV.PROPOSE_AUTHORITY // "downgrade")
  and .policies.contradictions == ($ENV.PROPOSE_CONTRADICTIONS // "suggest")
  and .policies.delivery == ($ENV.PROPOSE_DELIVERY_POLICY // "atomic")
  and .bootstrap.enabled == (($ENV.BOOTSTRAP // "false") == "true")
  and (.bootstrap.selected_paths | type == "array"
    and all(.[]; type == "string"))
  and (.placement_allowlist | type == "array")
  and all(.placement_allowlist[];
    type == "object"
    and keys == ["anchors","page_id","path"]
    and (.page_id | type == "string")
    and (.path | type == "string" and endswith(".adoc"))
    and (.anchors | type == "array" and all(.[]; type == "string")))
  and (.knowledge_objects | type == "array" and length <= 50)
  and all(.knowledge_objects[];
    type == "object"
    and (.id | type == "string")
    and (.kind | type == "string")
    and (.content_hash | test("^sha256:[0-9a-f]{64}$"))
    and (.body | type == "string")
    and (.fields | type == "object")
    and (.impacts | type == "array" and all(.[]; type == "string"))
    and (.page_id | type == "string")
    and (.source_span.path | type == "string" and endswith(".adoc")))
  and .provider.name == "claude-code"
  and (.provider.model | type == "string")
  and (.provider.provider_version | type == "string")
' "$OUT/proposal-context.json" >/dev/null 2>&1; then
  degrade proposal_context_invalid
fi

rm -rf -- "$OUT/patches" "$OUT/proposal-checks"
mkdir -m 700 "$OUT/patches" "$OUT/proposal-checks"
: > "$OUT/rejected.md"
: > "$OUT/patch-manifest.pending.ndjson"

reject() { # ordinal, safe reason
  printf -- '- Candidate %s — %s\n' "$1" "$2" >> "$OUT/rejected.md"
  printf 'AgentDoc: proposal candidate %s rejected: %s\n' "$1" "$2"
}

assessment="$(jq -r .assessment_sha256 "$OUT/proposal-context.json")"
head_revision="$(jq -r .revisions.head "$OUT/proposal-context.json")"
evaluation_date="$(jq -r .evaluation_date "$OUT/proposal-context.json")"
provider_version="$(jq -r .provider.provider_version "$OUT/proposal-context.json")"
model="$(jq -r .provider.model "$OUT/proposal-context.json")"
proposer="agentdoc-action/claude-code@${provider_version}/${model}"

jq -r 'group_by(.target)[] | select(length > 1) | .[0].target' \
  "$OUT/proposal-candidates.json" > "$OUT/duplicate-targets"

while IFS= read -r candidate; do
  ordinal="$(jq -r ._ordinal <<< "$candidate")"
  target="$(jq -r '.target // ""' <<< "$candidate")"
  candidate_operation="$(jq -r '.operation // ""' <<< "$candidate")"
  kind="$(jq -r '.kind // ""' <<< "$candidate")"
  status="$(jq -r '.status // ""' <<< "$candidate")"
  finding="$(jq -r '.finding_id // ""' <<< "$candidate")"

  if ! jq -e '
    type == "object"
    and (keys | all(. as $key | [
      "_ordinal","body","classification","desired_status","fields","finding_id",
      "kind","knowledge_evidence","operation","placement","proposal_expected",
      "rejection_reason","status","target"
    ] | index($key)))
    and (.finding_id | type == "string" and test("^finding-[0-9]{3}$"))
    and (.classification | type == "string")
    and (.proposal_expected | type == "boolean")
    and ((.rejection_reason == null) or (.rejection_reason | type == "string"))
    and (.operation | IN("create","update"))
    and (.target | type == "string")
    and (.knowledge_evidence | type == "array")
  ' <<< "$candidate" >/dev/null 2>&1; then
    reject "$ordinal" 'candidate does not match the closed proposal profile'
    continue
  fi
  if [ "$(jq -r '.rejection_reason // ""' <<< "$candidate")" != "" ]; then
    reject "$ordinal" 'finding correlation was rejected'
    continue
  fi
  classification="$(jq -r .classification <<< "$candidate")"
  if [ "$(jq -r .proposal_expected <<< "$candidate")" != true ] \
    || { [ "$classification" != extends_existing_knowledge ] \
      && [ "$classification" != contradicts_existing_knowledge ]; }; then
    reject "$ordinal" 'finding is not eligible for an executable proposal'
    continue
  fi
  if ! [[ "$target" =~ ^[a-z0-9]+(-[a-z0-9]+)*\.[a-z0-9]+(-[a-z0-9]+)*(\.[a-z0-9]+(-[a-z0-9]+)*)*$ ]] \
    || [ "$(printf %s "$target" | wc -c | tr -d ' ')" -gt 128 ]; then
    reject "$ordinal" 'target is not a valid AgentDoc Object ID'
    continue
  fi
  if grep -Fxq "$target" "$OUT/duplicate-targets"; then
    reject "$ordinal" "duplicate proposal target \`$target\`"
    continue
  fi
  if jq -e '
    [(.fields // {}) | keys[]]
    | any(. == "verified_at" or . == "reviewed_by" or . == "approved_by"
      or . == "decided_by" or . == "resolved_by" or . == "id"
      or . == "kind" or . == "status" or . == "body" or . == "placement")
  ' <<< "$candidate" >/dev/null; then
    reject "$ordinal" 'generated fields contain authority or structural metadata'
    continue
  fi

  if [ "$candidate_operation" = create ]; then
    if [ "$classification" != extends_existing_knowledge ]; then
      reject "$ordinal" 'create candidates must extend existing knowledge'
      continue
    fi
    case "$kind/$status" in
      claim/draft | decision/proposed | api/draft | task/open) ;;
      *) reject "$ordinal" 'kind/status pair is not non-authoritative'; continue ;;
    esac
    placement="$(jq -c .placement <<< "$candidate")"
    page_id="$(jq -r '.page_id // ""' <<< "$placement")"
    after="$(jq -r '.after // ""' <<< "$placement")"
    if ! jq -e '
      type == "object"
      and (keys | IN(["page_id"],["after","page_id"]))
      and (.page_id | type == "string" and length > 0)
      and ((has("after") | not) or (.after | type == "string"))
    ' <<< "$placement" >/dev/null 2>&1; then
      reject "$ordinal" 'placement does not match the closed profile'
      continue
    fi
    allowlist_match="$(jq -c --arg page "$page_id" \
      '[.placement_allowlist[] | select(.page_id == $page)]' \
      "$OUT/proposal-context.json")"
    if [ "$(jq length <<< "$allowlist_match")" -ne 1 ]; then
      reject "$ordinal" 'placement page is not in the exact-head allowlist'
      continue
    fi
    if [ -n "$after" ] && ! jq -e --arg anchor "$after" \
      '.[0].anchors | index($anchor) != null' <<< "$allowlist_match" >/dev/null; then
      reject "$ordinal" 'placement anchor is not in the exact-head allowlist'
      continue
    fi
    placement_path="$(jq -r '.[0].path' <<< "$allowlist_match")"
    patch="$OUT/patches/candidate-${ordinal}-create.json"
    jq -cS -n \
      --arg reason "AgentDoc assessment ${assessment} finding ${finding}." \
      --arg proposer "$proposer" --argjson candidate "$candidate" '{
        schema_version:"adoc.patch.v0",op:"create_object",target:$candidate.target,
        changes:{kind:$candidate.kind,status:$candidate.status,body:$candidate.body,
          fields:$candidate.fields,placement:$candidate.placement},
        reason:$reason,proposer:{type:"agent",id:$proposer}
      }' > "$patch" || degrade patch_construction_failed
    patch_sha="sha256:$(sha256sum "$patch" | awk '{print $1}')"
    jq -cn --arg path "$patch" --arg sha "$patch_sha" --arg target "$target" \
      --arg kind "$kind" --arg status "$status" --arg finding "$finding" \
      --arg placement_path "$placement_path" --arg page_id "$page_id" \
      --argjson logical "$ordinal" '{
        schema_version:"adoc.patch.v0",operation:"create_object",
        target:$target,kind:$kind,status:$status,finding_id:$finding,
        placement_path:$placement_path,page_id:$page_id,path:$path,sha256:$sha,
        logical_candidate:$logical,sequence:1
      }' >> "$OUT/patch-manifest.pending.ndjson"
    continue
  fi

  if [ "${PROPOSE_AUTHORITY:-downgrade}" = suggest ]; then
    reject "$ordinal" 'existing-object updates are configured as suggestions'
    continue
  fi
  object="$(jq -c --arg target "$target" \
    '[.knowledge_objects[] | select(.id == $target)]' "$OUT/proposal-context.json")"
  if [ "$(jq length <<< "$object")" -ne 1 ] \
    || ! jq -e --arg target "$target" --arg hash "$(jq -r '.[0].content_hash' <<< "$object")" \
      'any(.knowledge_evidence[]; .id == $target and .content_hash == $hash)' \
      <<< "$candidate" >/dev/null; then
    reject "$ordinal" 'update target was not cited from exact-head knowledge'
    continue
  fi
  kind="$(jq -r '.[0].kind' <<< "$object")"
  status="$(jq -r '.[0].status // ""' <<< "$object")"
  base_hash="$(jq -r '.[0].content_hash' <<< "$object")"
  placement_path="$(jq -r '.[0].source_span.path' <<< "$object")"
  page_id="$(jq -r '.[0].page_id' <<< "$object")"
  desired_status="$(jq -r '.desired_status // ""' <<< "$candidate")"
  if [ "$kind" = contradiction ]; then
    if [ "${PROPOSE_CONTRADICTIONS:-suggest}" != propose ]; then
      reject "$ordinal" 'contradiction lifecycle changes are configured as suggestions'
      continue
    fi
    case "$desired_status" in resolved | dismissed) ;;
      *) reject "$ordinal" 'contradiction update requires resolved or dismissed status'; continue ;;
    esac
  elif [ "${PROPOSE_AUTHORITY:-downgrade}" = downgrade ]; then
    case "$kind" in
      claim) desired_status=draft ;;
      decision | policy) desired_status=proposed ;;
      api | example | procedure) desired_status=draft ;;
      question | task) desired_status=open ;;
      *) reject "$ordinal" 'target kind has no non-authoritative lifecycle'; continue ;;
    esac
  else
    desired_status="$status"
  fi

  fields="$(jq -c '.fields // {}' <<< "$candidate")"
  if [ -n "$desired_status" ] && [ "$desired_status" != "$status" ]; then
    fields="$(jq -c --arg status "$desired_status" '. + {status:$status}' <<< "$fields")"
  fi
  sequence=0
  if [ "$(jq length <<< "$fields")" -gt 0 ]; then
    sequence=$((sequence + 1))
    patch="$OUT/patches/candidate-${ordinal}-fields.json"
    jq -cS -n --arg target "$target" --arg base "$base_hash" \
      --arg reason "AgentDoc assessment ${assessment} finding ${finding}." \
      --arg proposer "$proposer" --argjson fields "$fields" '{
        schema_version:"adoc.patch.v0",op:"update_fields",target:$target,
        base_hash:$base,changes:{fields:$fields},reason:$reason,
        proposer:{type:"agent",id:$proposer}
      }' > "$patch" || degrade patch_construction_failed
    patch_sha="sha256:$(sha256sum "$patch" | awk '{print $1}')"
    jq -cn --arg path "$patch" --arg sha "$patch_sha" --arg target "$target" \
      --arg kind "$kind" --arg status "$desired_status" --arg finding "$finding" \
      --arg placement_path "$placement_path" --arg page_id "$page_id" \
      --argjson logical "$ordinal" --argjson sequence "$sequence" '{
        schema_version:"adoc.patch.v0",operation:"update_fields",
        target:$target,kind:$kind,status:$status,finding_id:$finding,
        placement_path:$placement_path,page_id:$page_id,path:$path,sha256:$sha,
        logical_candidate:$logical,sequence:$sequence
      }' >> "$OUT/patch-manifest.pending.ndjson"
    base_hash=CURRENT
  fi
  if jq -e 'has("body")' <<< "$candidate" >/dev/null; then
    sequence=$((sequence + 1))
    patch="$OUT/patches/candidate-${ordinal}-body.json"
    jq -cS -n --arg target "$target" --arg base "$base_hash" \
      --arg reason "AgentDoc assessment ${assessment} finding ${finding}." \
      --arg proposer "$proposer" --argjson candidate "$candidate" '{
        schema_version:"adoc.patch.v0",op:"replace_body",target:$target,
        base_hash:$base,changes:{body:$candidate.body},reason:$reason,
        proposer:{type:"agent",id:$proposer}
      }' > "$patch" || degrade patch_construction_failed
    patch_sha="sha256:$(sha256sum "$patch" | awk '{print $1}')"
    jq -cn --arg path "$patch" --arg sha "$patch_sha" --arg target "$target" \
      --arg kind "$kind" --arg status "$desired_status" --arg finding "$finding" \
      --arg placement_path "$placement_path" --arg page_id "$page_id" \
      --argjson logical "$ordinal" --argjson sequence "$sequence" '{
        schema_version:"adoc.patch.v0",operation:"replace_body",
        target:$target,kind:$kind,status:$status,finding_id:$finding,
        placement_path:$placement_path,page_id:$page_id,path:$path,sha256:$sha,
        logical_candidate:$logical,sequence:$sequence
      }' >> "$OUT/patch-manifest.pending.ndjson"
  fi
done < <(jq -c 'to_entries[] | .value + {_ordinal:(.key + 1)}' \
  "$OUT/proposal-candidates.json")

jq -sc 'sort_by([.placement_path,.page_id,.target,.logical_candidate,.sequence])[]' \
  "$OUT/patch-manifest.pending.ndjson" > "$OUT/patch-manifest.screened.ndjson" \
  || degrade patch_sort_failed
while IFS= read -r placement_path; do
  case "$placement_path" in
    /* | *..* | *$'\n'* | *$'\r'* | *$'\t'* | '') degrade placement_path_invalid ;;
    *.adoc) ;;
    *) degrade placement_path_invalid ;;
  esac
done < <(jq -r .placement_path "$OUT/patch-manifest.screened.ndjson")

repo="$(git rev-parse --show-toplevel 2>/dev/null)" || degrade repository_unavailable
prefix="$(git rev-parse --show-prefix 2>/dev/null)" || degrade working_directory_invalid
git -C "$repo" cat-file -e "${head_revision}^{commit}" 2>/dev/null \
  || degrade head_unavailable
git -C "$repo" worktree add --detach "$sandbox" "$head_revision" >/dev/null 2>&1 \
  || degrade sandbox_creation_failed
sandbox_workdir="$sandbox/${prefix%/}"
[ -d "$sandbox_workdir" ] || degrade working_directory_invalid

(cd "$sandbox_workdir" && adoc check --as-of "$evaluation_date" --format json \
  > "$OUT/proposal-checks/initial-check.json" 2>"$OUT/proposal-checks/initial-check.stderr") \
  || degrade initial_check_failed
initial_build="$OUT/proposal-build-000"
mkdir -m 700 "$initial_build"
(cd "$sandbox_workdir" && adoc build --as-of "$evaluation_date" \
  --no-embeddings --out "$initial_build" >/dev/null \
  2>"$OUT/proposal-checks/initial-build.stderr") || degrade initial_build_failed
graph="$initial_build/docs.graph.json"
graph_sha="sha256:$(sha256sum "$graph" | awk '{print $1}')"
[ "$graph_sha" = "$(jq -r .graph_sha256 "$OUT/proposal-context.json")" ] \
  || degrade initial_graph_digest_mismatch
jq -c '[.nodes[] | select(.type == "knowledge_object") | {id,content_hash}] | sort_by(.id)' \
  "$graph" | tr -d '\n' > "$OUT/proposal-object-set.json"
object_sha="sha256:$(sha256sum "$OUT/proposal-object-set.json" | awk '{print $1}')"
[ "$object_sha" = "$(jq -r .object_set_sha256 "$OUT/proposal-context.json")" ] \
  || degrade initial_object_set_digest_mismatch

: > "$OUT/patch-manifest.ndjson"
index=0
while IFS= read -r logical; do
  [ -n "$logical" ] || continue
  group_manifest="$OUT/proposal-checks/group-${logical}.ndjson"
  : > "$group_manifest"
  placement_path="$(jq -r --argjson logical "$logical" \
    'select(.logical_candidate == $logical) | .placement_path' \
    "$OUT/patch-manifest.screened.ndjson" | head -n 1)"
  backup="$OUT/proposal-checks/group-${logical}.backup"
  cp -p "$sandbox_workdir/$placement_path" "$backup" \
    || degrade sandbox_backup_failed
  graph_before="$graph"
  group_ok=true
  group_rejection='canonical AgentDoc patch validation rejected the candidate'

  while IFS= read -r manifest; do
    [ -n "$manifest" ] || continue
    index=$((index + 1))
    ordinal="$(printf '%03d' "$index")"
    patch="$(jq -r .path <<< "$manifest")"
    target="$(jq -r .target <<< "$manifest")"
    if [ "$(jq -r '.base_hash // ""' "$patch")" = CURRENT ]; then
      base_hash="$(jq -r --arg target "$target" '
        first(.nodes[] | select(.type == "knowledge_object" and .id == $target)
          | .content_hash) // empty
      ' "$graph")"
      [[ "$base_hash" =~ ^sha256:[0-9a-f]{64}$ ]] \
        || { group_ok=false; break; }
      jq -cS --arg base "$base_hash" '.base_hash = $base' "$patch" \
        > "$OUT/proposal-checks/patch-next.json" \
        || { group_ok=false; break; }
      mv "$OUT/proposal-checks/patch-next.json" "$patch"
      patch_sha="sha256:$(sha256sum "$patch" | awk '{print $1}')"
      manifest="$(jq -c --arg sha "$patch_sha" '.sha256 = $sha' <<< "$manifest")"
    fi
    check="$OUT/proposal-checks/check-${ordinal}.json"
    if ! (cd "$sandbox_workdir" && adoc patch --check "$patch" --artifact "$graph" \
      --as-of "$evaluation_date" --format json > "$check" \
      2>"$OUT/proposal-checks/check-${ordinal}.stderr") \
      || ! jq -e '.schema_version == "adoc.patch.check.v0" and .valid == true' \
        "$check" >/dev/null 2>&1; then
      group_ok=false
      break
    fi

    apply="$OUT/proposal-checks/apply-${ordinal}.json"
    if ! (cd "$sandbox_workdir" && adoc patch --apply "$patch" --artifact "$graph" \
      --as-of "$evaluation_date" --format json > "$apply" \
      2>"$OUT/proposal-checks/apply-${ordinal}.stderr") \
      || ! jq -e '.schema_version == "adoc.patch.apply.v0" and .applied == true' \
        "$apply" >/dev/null 2>&1 \
      || ! (cd "$sandbox_workdir" \
        && adoc check --as-of "$evaluation_date" --format json \
          > "$OUT/proposal-checks/post-check-${ordinal}.json" \
          2>"$OUT/proposal-checks/post-check-${ordinal}.stderr"); then
      group_ok=false
      break
    fi

    build_out="$OUT/proposal-build-${ordinal}"
    mkdir -m 700 "$build_out"
    if ! (cd "$sandbox_workdir" && adoc build --as-of "$evaluation_date" \
      --no-embeddings --out "$build_out" >/dev/null \
      2>"$OUT/proposal-checks/build-${ordinal}.stderr"); then
      group_ok=false
      break
    fi
    graph="$build_out/docs.graph.json"
    if ! jq -e --arg target "$target" --arg kind "$(jq -r .kind <<< "$manifest")" \
      --arg status "$(jq -r .status <<< "$manifest")" '
        any(.nodes[];
          .type == "knowledge_object" and .id == $target
          and .kind == $kind and .status == $status)
      ' "$graph" >/dev/null 2>&1; then
      group_ok=false
      break
    fi
    if [ "${BOOTSTRAP:-false}" = true ] && ! jq -e --arg target "$target" \
      --argjson paths "$(jq -c '.bootstrap.selected_paths' "$OUT/proposal-context.json")" '
        any(.nodes[];
          .type == "knowledge_object" and .id == $target
          and any(.impacts[]?;
            . as $impact
            | any($paths[];
                . == $impact
                or (($impact | endswith("/")) and startswith($impact)))))
      ' "$graph" >/dev/null 2>&1; then
      group_ok=false
      group_rejection='bootstrap candidate does not cover a selected path'
      break
    fi
    if [ "${BOOTSTRAP:-false}" = true ] && ! jq -e --arg target "$target" \
      --slurpfile before "$graph_before" '
        ([$before[0].nodes[]
          | select(.type == "knowledge_object" and .id == $target)
          | .impacts[]?] | unique) as $old
        | ([.nodes[]
          | select(.type == "knowledge_object" and .id == $target)
          | .impacts[]?] | unique) as $new
        | all($old[]; . as $impact | $new | index($impact) != null)
      ' "$graph" >/dev/null 2>&1; then
      group_ok=false
      group_rejection='bootstrap candidate removes existing impacts'
      break
    fi
    check_sha="sha256:$(sha256sum "$check" | awk '{print $1}')"
    jq -c --arg check_path "$check" --arg check_sha "$check_sha" \
      '. + {check_path:$check_path,check_sha256:$check_sha}' <<< "$manifest" \
      >> "$group_manifest"
  done < <(jq -c --argjson logical "$logical" \
    'select(.logical_candidate == $logical)' \
    "$OUT/patch-manifest.screened.ndjson")

  if [ "$group_ok" = true ]; then
    cat "$group_manifest" >> "$OUT/patch-manifest.ndjson"
  else
    cp -p "$backup" "$sandbox_workdir/$placement_path" \
      || degrade sandbox_restore_failed
    graph="$graph_before"
    reject "$logical" "$group_rejection"
  fi
done < <(jq -r '.logical_candidate' "$OUT/patch-manifest.screened.ndjson" \
  | awk '!seen[$0]++')

count="$(wc -l < "$OUT/patch-manifest.ndjson" | tr -d ' ')"
rejected="$(wc -l < "$OUT/rejected.md" | tr -d ' ')"
if [ "$count" -eq 0 ]; then
  proposal_status skipped no_valid_proposals 0
elif [ "$rejected" -gt 0 ] \
  && [ "${PROPOSE_DELIVERY_POLICY:-atomic}" = atomic ]; then
  : > "$OUT/patch-manifest.ndjson"
  proposal_status skipped atomic_candidate_rejection 0
  count=0
else
  jq -sc 'map(.sha256)' "$OUT/patch-manifest.ndjson" > "$OUT/proposal-digests.json"
  set_sha="sha256:$(sha256sum "$OUT/proposal-digests.json" | awk '{print $1}')"
  if [ "$rejected" -gt 0 ]; then
    proposal_status partial some_candidates_rejected "$count" "$set_sha"
  else
    proposal_status complete validated "$count" "$set_sha"
  fi
fi

# E5.1: the canonical adoc.proposal.v0 record binds the validated patch set
# to the exact revisions, change request, and semantic executor receipt.
semantic_receipt="${ADOC_RETAINED_DIR:-}/semantic-executor-${ADOC_INVOCATION_ID:-}.json"
if [ "$count" -eq 0 ]; then
  record_status skipped no_valid_proposals
elif ! adoc proposal-record --help >/dev/null 2>&1; then
  record_status skipped adoc_command_unavailable
elif ! [[ "${ADOC_PR_NUMBER:-}" =~ ^[0-9]+$ ]]; then
  record_status skipped change_request_unavailable
elif [ -z "$record" ] || ! jq -e '
  .schema_version == "adoc.semantic_executor_receipt.v0"
  and .outcome == "completed"
  and (.context_digest | test("^sha256:[0-9a-f]{64}$"))
  and (.assessment_digest | test("^sha256:[0-9a-f]{64}$"))
' "$semantic_receipt" >/dev/null 2>&1; then
  record_status skipped semantic_receipt_unavailable
else
  jq -sc --arg base "$(jq -r .revisions.comparison_base "$OUT/proposal-context.json")" \
    --arg head "$head_revision" --arg pr "$ADOC_PR_NUMBER" \
    --arg assessment "$assessment" \
    --arg context "$(jq -r .context_digest "$semantic_receipt")" \
    --arg semantic "$(jq -r .assessment_digest "$semantic_receipt")" '{
      bindings:{
        base_revision:{system:"git",value:$base},
        head_revision:{system:"git",value:$head},
        change_request:{system:"github_pull_request",id:$pr},
        assessment_digest:$assessment,
        semantic_context_digest:$context,
        semantic_assessment_digest:$semantic
      },
      patches:map({finding_id,placement_path,page_id,patch_path:.path})
    }' "$OUT/patch-manifest.ndjson" > "$OUT/proposal-record-input.json" \
    || degrade proposal_record_input_failed
  if adoc proposal-record --input "$OUT/proposal-record-input.json" \
    --out "$record" >/dev/null 2>"$OUT/proposal-checks/proposal-record.stderr"; then
    record_status complete validated "$record" \
      "sha256:$(sha256sum "$record" | awk '{print $1}')"
    # The record's proposal_set_digest is the one proposal identity.
    jq --arg sha "$(jq -r .proposal_set_digest "$record")" '.sha256 = $sha' \
      "$OUT/proposal-status.json" > "$OUT/proposal-status.next" \
      || degrade proposal_status_failed
    mv "$OUT/proposal-status.next" "$OUT/proposal-status.json"
  else
    rm -f -- "$record"
    record_status error proposal_record_failed
    echo 1 > "$OUT/adoc-propose-code"
    echo "::warning::AgentDoc: canonical proposal record failed (proposal_record_failed); validated patches remain available"
  fi
fi

{
  echo 'Canonical AgentDoc patches for human review. Each draft passed the exact-head `patch --check` / `patch --apply` / `check` / fresh-build loop.'
  echo
  while IFS= read -r manifest; do
    [ -n "$manifest" ] || continue
    patch="$(jq -r .path <<< "$manifest")"
    check="$(jq -r .check_path <<< "$manifest")"
    echo '<!-- adoc:block:proposal -->'
    jq -r --argjson patch "$(cat "$patch")" '
      def html:
        tostring
        | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
      "<details><summary>"
      + (if .operation == "create_object" then "➕ " else "✏️ " end)
      + (.target | html)
      + " — " + (.placement_path | html) + "</summary>\n\n"
      + "<pre><code>" + ($patch | tojson | html) + "</code></pre>\n\n"
    ' <<< "$manifest"
    echo '**Proof obligations**'
    echo
    if ! jq -r '
      (.proof_obligations // []) as $items
      | if ($items | length) == 0 then "- None reported by AgentDoc."
        else $items[] | "- `" + (if type == "string" then .
          else (.id // .code // tojson) end
          | gsub("[\u0000-\u001f\u007f`]"; " ")) + "`"
        end
    ' "$check"; then
      degrade proposal_render_failed
    fi
    echo
    echo '</details>'
    echo
  done < "$OUT/patch-manifest.ndjson"
  if [ -s "$OUT/rejected.md" ]; then
    echo '<!-- adoc:block:proposal-rejected -->'
    echo 'Rejected candidates:'
    echo
    cat "$OUT/rejected.md"
    echo
  fi
  echo "<sub>canonical patches by claude-code · ${model} · ${count} validated · ${rejected} rejected</sub>"
} > "$OUT/proposed-drafts.md"

exit 0
