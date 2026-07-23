#!/usr/bin/env bash
# Converts validated private model candidates into canonical create-only
# AgentDoc patches and proves them in one disposable exact-head sandbox.
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

proposal_status skipped no_candidate_scope 0
echo 0 > "$OUT/adoc-propose-code"
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
    "$OUT/patch-manifest.screened.ndjson" "$OUT/proposal-digests.json"
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
  proposal_status skipped untrusted_pr 0
  exit 0
fi
if [ -s "$OUT/provider-stage-error" ]; then
  degrade "$(cat "$OUT/provider-stage-error")"
fi
if [ ! -s "$OUT/proposal-candidates.json" ] || [ ! -s "$OUT/proposal-context.json" ]; then
  reason="$(jq -r '.reason // empty' "$OUT/semantic-status.json" 2>/dev/null || true)"
  case "$reason" in
    no_candidate_scope | no_textual_hunks | credentials_unavailable | untrusted_pr)
      proposal_status skipped "$reason" 0
      exit 0
      ;;
  esac
  degrade proposal_context_unavailable
fi
if ! jq -e 'type == "array" and length <= 100' \
  "$OUT/proposal-candidates.json" >/dev/null 2>&1; then
  degrade proposal_candidate_contract_failed
fi
if [ "$(jq length "$OUT/proposal-candidates.json")" -eq 0 ]; then
  proposal_status skipped no_candidate_scope 0
  exit 0
fi
if ! jq -e '
  type == "object"
  and (.assessment_sha256 | test("^sha256:[0-9a-f]{64}$"))
  and (.revisions.head | test("^[0-9a-f]{40}$"))
  and (.evaluation_date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
  and (.graph_sha256 | test("^sha256:[0-9a-f]{64}$"))
  and (.object_set_sha256 | test("^sha256:[0-9a-f]{64}$"))
  and (.placement_allowlist | type == "array")
  and all(.placement_allowlist[];
    type == "object"
    and keys == ["anchors","page_id","path"]
    and (.page_id | type == "string")
    and (.path | type == "string" and endswith(".adoc"))
    and (.anchors | type == "array" and all(.[]; type == "string")))
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
  kind="$(jq -r '.kind // ""' <<< "$candidate")"
  status="$(jq -r '.status // ""' <<< "$candidate")"
  finding="$(jq -r '.finding_id // ""' <<< "$candidate")"

  if ! jq -e '
    type == "object"
    and (keys | all(. as $key | [
      "_ordinal","body","classification","fields","finding_id","kind",
      "placement","proposal_expected","rejection_reason","status","target"
    ] | index($key)))
    and (.finding_id | type == "string" and test("^finding-[0-9]{3}$"))
    and (.classification | type == "string")
    and (.proposal_expected | type == "boolean")
    and ((.rejection_reason == null) or (.rejection_reason | type == "string"))
    and (.kind | type == "string")
    and (.target | type == "string")
    and (.status | type == "string")
    and (.body | type == "string" and length > 0 and length <= 16384)
    and (.fields | type == "object" and all(.[]; type == "string"))
    and (.placement | type == "object")
  ' <<< "$candidate" >/dev/null 2>&1; then
    reject "$ordinal" 'candidate does not match the closed proposal profile'
    continue
  fi
  if [ "$(jq -r '.rejection_reason // ""' <<< "$candidate")" != "" ]; then
    reject "$ordinal" 'finding correlation was rejected'
    continue
  fi
  if [ "$(jq -r .classification <<< "$candidate")" != extends_existing_knowledge ] \
    || [ "$(jq -r .proposal_expected <<< "$candidate")" != true ]; then
    reject "$ordinal" 'finding is not eligible for an executable proposal'
    continue
  fi
  case "$kind/$status" in
    claim/draft | decision/proposed | api/draft | task/open) ;;
    *) reject "$ordinal" 'kind/status pair is not non-authoritative'; continue ;;
  esac
  if ! [[ "$target" =~ ^[a-z0-9]+(-[a-z0-9]+)*\.[a-z0-9]+(-[a-z0-9]+)*(\.[a-z0-9]+(-[a-z0-9]+)*)*$ ]] \
    || [ "$(printf %s "$target" | wc -c | tr -d ' ')" -gt 128 ]; then
    reject "$ordinal" 'target is not a valid AgentDoc Object ID'
    continue
  fi
  if grep -Fxq "$target" "$OUT/duplicate-targets"; then
    reject "$ordinal" 'duplicate proposal target'
    continue
  fi
  if jq -e '
    [.fields | keys[]]
    | any(. == "verified_at" or . == "reviewed_by" or . == "approved_by"
      or . == "decided_by" or . == "resolved_by" or . == "id"
      or . == "kind" or . == "status" or . == "body" or . == "placement")
  ' <<< "$candidate" >/dev/null; then
    reject "$ordinal" 'generated fields contain authority or structural metadata'
    continue
  fi

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

  patch_tmp="$OUT/patches/candidate-${ordinal}.json"
  jq -cS -n \
    --arg reason "AgentDoc assessment ${assessment} finding ${finding}." \
    --arg proposer "$proposer" \
    --argjson candidate "$candidate" '{
      schema_version:"adoc.patch.v0",
      op:"create_object",
      target:$candidate.target,
      changes:{
        kind:$candidate.kind,
        status:$candidate.status,
        body:$candidate.body,
        fields:$candidate.fields,
        placement:$candidate.placement
      },
      reason:$reason,
      proposer:{type:"agent",id:$proposer}
    }' > "$patch_tmp" || degrade patch_construction_failed
  patch_sha="sha256:$(sha256sum "$patch_tmp" | awk '{print $1}')"
  patch="$OUT/patches/${patch_sha#sha256:}.json"
  mv "$patch_tmp" "$patch"
  jq -cn --arg path "$patch" --arg sha "$patch_sha" --arg target "$target" \
    --arg kind "$kind" --arg status "$status" --arg finding "$finding" \
    --arg placement_path "$placement_path" --arg page_id "$page_id" '{
      schema_version:"adoc.patch.v0",operation:"create_object",
      target:$target,kind:$kind,status:$status,finding_id:$finding,
      placement_path:$placement_path,page_id:$page_id,path:$path,sha256:$sha
    }' >> "$OUT/patch-manifest.pending.ndjson"
done < <(jq -c 'to_entries[] | .value + {_ordinal:(.key + 1)}' \
  "$OUT/proposal-candidates.json")

jq -sc 'sort_by([.placement_path,.page_id,.target,.sha256])[]' \
  "$OUT/patch-manifest.pending.ndjson" > "$OUT/patch-manifest.screened.ndjson" \
  || degrade patch_sort_failed

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
while IFS= read -r manifest; do
  [ -n "$manifest" ] || continue
  index=$((index + 1))
  patch="$(jq -r .path <<< "$manifest")"
  target="$(jq -r .target <<< "$manifest")"
  check="$OUT/proposal-checks/check-$(printf '%03d' "$index").json"
  if ! (cd "$sandbox_workdir" && adoc patch --check "$patch" --artifact "$graph" \
    --as-of "$evaluation_date" --format json > "$check" \
    2>"$OUT/proposal-checks/check-$(printf '%03d' "$index").stderr"); then
    reject "$index" 'canonical AgentDoc patch validation rejected the candidate'
    continue
  fi
  if ! jq -e '.schema_version == "adoc.patch.check.v0" and .valid == true' \
    "$check" >/dev/null 2>&1; then
    reject "$index" 'canonical AgentDoc patch validation rejected the candidate'
    continue
  fi

  apply="$OUT/proposal-checks/apply-$(printf '%03d' "$index").json"
  if ! (cd "$sandbox_workdir" && adoc patch --apply "$patch" --artifact "$graph" \
    --as-of "$evaluation_date" --format json > "$apply" \
    2>"$OUT/proposal-checks/apply-$(printf '%03d' "$index").stderr"); then
    degrade sandbox_apply_failed
  fi
  jq -e '.schema_version == "adoc.patch.apply.v0" and .applied == true' \
    "$apply" >/dev/null 2>&1 || degrade sandbox_apply_contract_failed
  (cd "$sandbox_workdir" && adoc check --as-of "$evaluation_date" --format json \
    > "$OUT/proposal-checks/post-check-$(printf '%03d' "$index").json" \
    2>"$OUT/proposal-checks/post-check-$(printf '%03d' "$index").stderr") \
    || degrade sandbox_post_check_failed

  build_out="$OUT/proposal-build-$(printf '%03d' "$index")"
  mkdir -m 700 "$build_out"
  (cd "$sandbox_workdir" && adoc build --as-of "$evaluation_date" \
    --no-embeddings --out "$build_out" >/dev/null \
    2>"$OUT/proposal-checks/build-$(printf '%03d' "$index").stderr") \
    || degrade sandbox_rebuild_failed
  graph="$build_out/docs.graph.json"
  jq -e --arg target "$target" --arg kind "$(jq -r .kind <<< "$manifest")" \
    --arg status "$(jq -r .status <<< "$manifest")" '
      any(.nodes[];
        .type == "knowledge_object" and .id == $target
        and .kind == $kind and .status == $status)
    ' "$graph" >/dev/null 2>&1 || degrade sandbox_target_confirmation_failed
  check_sha="sha256:$(sha256sum "$check" | awk '{print $1}')"
  jq -c --arg check_path "$check" --arg check_sha "$check_sha" \
    '. + {check_path:$check_path,check_sha256:$check_sha}' <<< "$manifest" \
    >> "$OUT/patch-manifest.ndjson"
done < "$OUT/patch-manifest.screened.ndjson"

count="$(wc -l < "$OUT/patch-manifest.ndjson" | tr -d ' ')"
rejected="$(wc -l < "$OUT/rejected.md" | tr -d ' ')"
if [ "$count" -eq 0 ]; then
  proposal_status skipped no_valid_proposals 0
else
  jq -sc 'map(.sha256)' "$OUT/patch-manifest.ndjson" > "$OUT/proposal-digests.json"
  set_sha="sha256:$(sha256sum "$OUT/proposal-digests.json" | awk '{print $1}')"
  if [ "$rejected" -gt 0 ]; then
    proposal_status partial some_candidates_rejected "$count" "$set_sha"
  else
    proposal_status complete validated "$count" "$set_sha"
  fi
fi

{
  echo 'Canonical AgentDoc patches for human review. Each create-only draft passed the exact-head `patch --check` / `patch --apply` / `check` / fresh-build loop.'
  echo
  while IFS= read -r manifest; do
    [ -n "$manifest" ] || continue
    patch="$(jq -r .path <<< "$manifest")"
    check="$(jq -r .check_path <<< "$manifest")"
    jq -r --argjson patch "$(cat "$patch")" '
      def html:
        tostring
        | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
      "<details><summary>➕ " + (.target | html)
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
    echo 'Rejected candidates:'
    echo
    cat "$OUT/rejected.md"
    echo
  fi
  echo "<sub>canonical patches by claude-code · ${model} · ${count} validated · ${rejected} rejected</sub>"
} > "$OUT/proposed-drafts.md"

exit 0
