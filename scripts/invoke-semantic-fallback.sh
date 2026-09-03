#!/usr/bin/env bash
# Runs one eligible semantic executor and, on any failure, one eligible fallback.
set -uo pipefail

policy="${1:?semantic fallback policy is required}"
primary_request="${2:?primary request is required}"
fallback_request="${3:?fallback request or - is required}"
status="${4:?semantic status path is required}"
receipt="${5:?semantic receipt path is required}"
validated="${6:?validated assessment path is required}"
context_binding="${SEMANTIC_CONTEXT_DIGEST_PATH:-$(dirname "$validated")/semantic-context-digest-${ADOC_INVOCATION_ID:-current}.txt}"
context_artifact="$(dirname "$validated")/semantic-context-${ADOC_INVOCATION_ID:-current}.json"
graph_artifact="$(dirname "$validated")/knowledge-graph-${ADOC_INVOCATION_ID:-current}.json"
OUT="${ADOC_RUN_DIR:-${RUNNER_TEMP:?}}"
ROOT="${GITHUB_ACTION_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
invoker="${SEMANTIC_INVOKER:-$ROOT/scripts/invoke-semantic-executor.sh}"
primary_receipt="$OUT/semantic-primary-receipt.json"
primary_validated="$OUT/semantic-primary-assessment.json"
fallback_receipt="$OUT/semantic-fallback-receipt.json"
fallback_validated="$OUT/semantic-fallback-assessment.json"
trusted_repo=''
trusted_worktree="$OUT/trusted-context-worktree"
trusted_build="$OUT/trusted-context-build"

cleanup() {
  if [ -n "$trusted_repo" ] && git -C "$trusted_repo" worktree list --porcelain \
    2>/dev/null | grep -Fqx "worktree $trusted_worktree"; then
    git -C "$trusted_repo" worktree remove --force "$trusted_worktree" \
      >/dev/null 2>&1 || :
  fi
  rm -rf -- "$trusted_worktree" "$trusted_build"
  rm -f -- "$primary_receipt" "$primary_validated" \
    "$fallback_receipt" "$fallback_validated" "$OUT/semantic-context-retained.json"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
rm -f -- "$status" "$receipt" "$validated" "$context_binding" \
  "$context_artifact" "$graph_artifact"

identity() { # request, outcome, failure code
  jq -n --slurpfile request "$1" --arg outcome "$2" --arg failure "${3:-}" '{
    request_id:$request[0].request_id,
    provider:$request[0].adapter.provider,
    model:$request[0].adapter.model,
    outcome:$outcome,
    failure_code:(if $failure == "" then null else $failure end)
  }'
}

policy_identity() { # candidate selector, outcome, failure code
  jq -n --slurpfile policy "$policy" --arg selector "$1" \
    --arg outcome "$2" --arg failure "${3:-}" '
    (if $selector == "primary" then $policy[0].primary else $policy[0].fallback end) as $candidate
    | {request_id:$candidate.request_id,provider:$candidate.provider,model:$candidate.model,
       outcome:$outcome,failure_code:(if $failure == "" then null else $failure end)}
  '
}

write_status() { # status, digest/null, primary json, fallback json/null
  jq -n --arg status "$1" --arg digest "${2:-}" \
    --argjson primary "$3" --argjson fallback "$4" '{
      status:$status,
      failure_code:(if $status == "failed" then "action.semantic_review_failed" else null end),
      assessment_sha256:(if $digest == "" then null else $digest end),
      primary:$primary,fallback:$fallback
    }' > "$status"
}

failure_code() {
  jq -r '.failure_code // "provider_failed"' "$1" 2>/dev/null \
    || printf '%s\n' provider_failed
}

trusted_context_authorized() { # request
  [ "${ADOC_TRUSTED_PHASE:-false}" != true ] \
    || "$ROOT/scripts/trusted-context-authorized.sh" "$1"
}

prepare_trusted_graph() {
  [ "${ADOC_TRUSTED_PHASE:-false}" = true ] || return 0
  if [ -s "${ADOC_TRUSTED_GRAPH_PATH:-}" ] \
    && [ -f "${ADOC_TRUSTED_DIFF_DIGESTS_PATH:-}" ]; then
    return 0
  fi
  local working="${ADOC_WORKING_DIRECTORY:?}" prefix head_workdir adoc_bin
  local raw parts part path index=0
  trusted_repo="$(git -C "$working" rev-parse --show-toplevel 2>/dev/null)" \
    || return 1
  prefix="$(git -C "$working" rev-parse --show-prefix 2>/dev/null)" || return 1
  git -C "$trusted_repo" cat-file -e "${ADOC_HEAD:?}^{commit}" 2>/dev/null \
    || return 1
  git -C "$trusted_repo" worktree add --detach "$trusted_worktree" "$ADOC_HEAD" \
    >/dev/null 2>&1 || return 1
  head_workdir="$trusted_worktree/${prefix%/}"
  [ -d "$head_workdir" ] || return 1
  mkdir -m 700 "$trusted_build" || return 1
  adoc_bin="${ADOC_BIN:-$(command -v adoc)}"
  [ -x "$adoc_bin" ] || return 1
  (cd "$head_workdir" && "$adoc_bin" build --as-of "$ADOC_EVALUATION_DATE" \
    --no-embeddings --out "$trusted_build" >/dev/null) || return 1
  install -m 600 "$trusted_build/docs.graph.json" \
    "$OUT/trusted-context-graph.json" || return 1
  : > "$OUT/trusted-diff-digests.ndjson"
  while IFS= read -r path; do
    index=$((index + 1))
    raw="$trusted_build/diff-$index"
    parts="$trusted_build/parts-$index"
    mkdir "$parts" || return 1
    git -C "$trusted_repo" -c core.quotePath=true diff --no-ext-diff \
      --no-textconv --no-renames --unified=3 \
      "${ADOC_DIFF_BASE:-$ADOC_COMPARISON_BASE}" "$ADOC_HEAD" -- "$path" \
      > "$raw" 2>/dev/null || return 1
    LC_ALL=C awk -v dir="$parts" '
      /^@@ / { n++; file=sprintf("%s/hunk-%03d", dir, n); bytes=0 }
      n > 0 {
        line_bytes=length($0)+1
        if (bytes+line_bytes <= 32768) { print $0 > file; bytes+=line_bytes }
      }
    ' "$raw" || return 1
    for part in "$parts"/hunk-*; do
      [ -f "$part" ] || continue
      jq -cn --arg path "$path" \
        --arg sha "sha256:$(sha256sum "$part" | awk '{print $1}')" \
        '{path:$path,sha256:$sha}' >> "$OUT/trusted-diff-digests.ndjson" \
        || return 1
    done
  done < <(jq -r '.context_request[].path' "$ADOC_TRUSTED_CHANGE_REQUEST_PATH")
  export ADOC_TRUSTED_GRAPH_PATH="$OUT/trusted-context-graph.json"
  export ADOC_TRUSTED_DIFF_DIGESTS_PATH="$OUT/trusted-diff-digests.ndjson"
}

trusted_candidate_authorized() { # candidate selector
  [ "${ADOC_TRUSTED_PHASE:-false}" != true ] || jq -e --arg selector "$1" \
    --slurpfile trusted "$OUT/trusted-phase-status.json" '
      (if $selector == "primary" then .primary else .fallback end) as $candidate
      | $trusted[0].executor.qualification_id == $candidate.qualification_id
      and $trusted[0].executor.provider == $candidate.provider
      and $trusted[0].executor.model == $candidate.model
      and $trusted[0].executor.config_digest == $candidate.config_digest
    ' "$policy" >/dev/null 2>&1
}

retain_completed() { # request, executor receipt, validated assessment
  local request="$1" source_receipt="$2" source_validated="$3" digest actual context
  digest="$(jq -er '.assessment_digest | select(test("^sha256:[0-9a-f]{64}$"))' \
    "$source_receipt" 2>/dev/null)" || return 1
  [ -s "$source_validated" ] || return 1
  actual="sha256:$(sha256sum "$source_validated" | awk '{print $1}')"
  [ "$actual" = "$digest" ] || return 1
  context="$(jq -er '.context.context_digest' "$request")" || return 1
  jq -e --arg digest "$digest" --arg context "$context" \
    --slurpfile request "$request" '
    .schema_version == "adoc.semantic_executor_receipt.v0"
    and .outcome == "completed" and .assessment_digest == $digest
    and .context_digest == $context
    and .request_id == $request[0].request_id
    and .adapter.provider == $request[0].adapter.provider
    and .adapter.model == $request[0].adapter.model
  ' "$source_receipt" >/dev/null 2>&1 || return 1
  jq -e --slurpfile request "$request" \
    -f "$ROOT/scripts/semantic-assessment-scope.jq" \
    "$source_validated" >/dev/null 2>&1 || return 1
  jq -e '.context | select(.schema_version == "adoc.semantic_context.v0")' \
    "$request" > "$OUT/semantic-context-retained.json" || return 1
  if ! install -m 600 "$source_receipt" "$receipt" \
    || ! install -m 600 "$source_validated" "$validated" \
    || ! install -m 600 "$OUT/semantic-context-retained.json" "$context_artifact" \
    || ! { [ -z "${ADOC_TRUSTED_GRAPH_PATH:-}" ] \
      || install -m 600 "$ADOC_TRUSTED_GRAPH_PATH" "$graph_artifact"; } \
    || ! printf '%s\n' "$context" > "$context_binding" \
    || ! chmod 600 "$context_binding"; then
    rm -f -- "$receipt" "$validated" "$context_binding" \
      "$context_artifact" "$graph_artifact"
    return 1
  fi
  printf '%s\n' "$digest"
}

candidate_valid() { # candidate selector, request
  jq -e --arg selector "$1" --slurpfile request "$2" '
    def exact($keys): type == "object" and (keys | sort) == ($keys | sort);
    def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
    def text: type == "string" and length > 0 and . == gsub("^\\s+|\\s+$"; "");
    def closed_set($values):
      type == "array" and length > 0 and length == (unique | length)
      and all(.[]; IN($values[]));
    def maturity: if . == "experimental" then 0 elif . == "qualified" then 1
      elif . == "production" then 2 else -1 end;
    . as $policy
    | select(exact(["policy_id","requirements","primary","fallback"]))
    | .requirements as $requirements
    | select($requirements | exact(["capability","minimum_maturity","scope","risk",
        "allowed_egress","allowed_residency","allowed_retention","allowed_telemetry",
        "allowed_endpoint_classes","operation_digest","context"]))
    | select($requirements.capability | exact(["name","version"])
        and (.name | text) and (.version | text))
    | select($requirements.minimum_maturity | IN("experimental","qualified","production"))
    | select($requirements.scope | text)
    | select($requirements.risk | text)
    | select($requirements.allowed_egress | closed_set(["none","private","public"]))
    | select($requirements.allowed_residency | type == "array" and length > 0
        and length == (unique | length) and all(.[]; text))
    | select($requirements.allowed_retention | closed_set(["none","transient","retained"]))
    | select($requirements.allowed_telemetry | closed_set(["disabled","metadata","content"]))
    | select($requirements.allowed_endpoint_classes
        | closed_set(["public_provider","customer_hosted","local","human"]))
    | select($requirements.operation_digest | digest)
    | select($requirements.context | exact(["schema_version","digest"])
        and .schema_version == "adoc.semantic_context.v0" and (.digest | digest))
    | (if $selector == "primary" then .primary else .fallback end) as $candidate
    | select($candidate | exact(["request_id","qualification_id","provider","model",
        "executor_digest","model_digest","config_digest","maturity","egress","residency",
        "retention","telemetry","endpoint_class","context","eligibility"]))
    | select($candidate.eligibility | exact(["capability_qualified","organization_approved",
        "runtime_policy_eligible","scope","risk","operation_digest"]))
    | select($candidate.eligibility.scope | type == "array" and length > 0
        and length == (unique | length) and all(.[]; text))
    | select($candidate.eligibility.risk | type == "array" and length > 0
        and length == (unique | length) and all(.[]; text))
    | select($candidate.context | exact(["schema_version","digest"]))
    | select([$candidate.request_id,$candidate.qualification_id,$candidate.provider,$candidate.model]
        | all(.[]; text))
    | select([$candidate.executor_digest,$candidate.model_digest,$candidate.config_digest]
        | all(.[]; digest))
    | select(($candidate.maturity | maturity) >= ($requirements.minimum_maturity | maturity))
    | select($candidate.egress | IN($requirements.allowed_egress[]))
    | select($candidate.residency | IN($requirements.allowed_residency[]))
    | select($candidate.retention | IN($requirements.allowed_retention[]))
    | select($candidate.telemetry | IN($requirements.allowed_telemetry[]))
    | select($candidate.endpoint_class | IN($requirements.allowed_endpoint_classes[]))
    | select($candidate.eligibility.capability_qualified == true)
    | select($candidate.eligibility.organization_approved == true)
    | select($candidate.eligibility.runtime_policy_eligible == true)
    | select($requirements.scope | IN($candidate.eligibility.scope[]))
    | select($requirements.risk | IN($candidate.eligibility.risk[]))
    | select($candidate.eligibility.operation_digest == $requirements.operation_digest)
    | select($candidate.context == $requirements.context)
    | select($request[0].request_id == $candidate.request_id)
    | select($request[0].capability == $requirements.capability.name)
    | select($request[0].adapter.kind
        | IN("claude_code","codex","generic","human","test"))
    | select($request[0].adapter.provider == $candidate.provider)
    | select($request[0].adapter.model == $candidate.model)
    | select($request[0].adapter.executor_digest == $candidate.executor_digest)
    | select($request[0].adapter.model_digest == $candidate.model_digest)
    | select($request[0].adapter.config_digest == $candidate.config_digest)
    | select($request[0].adapter.endpoint_class == $candidate.endpoint_class)
    | select($request[0].context.schema_version == $candidate.context.schema_version)
    | select($request[0].context.context_digest == $candidate.context.digest)
    | select($selector == "primary" or $candidate.request_id != $policy.primary.request_id)
  ' "$policy" >/dev/null 2>&1
}

fallback_configured="$(jq -r 'if .fallback == null then "false" else "true" end' \
  "$policy" 2>/dev/null || printf invalid)"
if ! prepare_trusted_graph; then
  primary="$(policy_identity primary not_invoked policy_ineligible)"
  write_status failed '' "$primary" null
  exit 2
fi
if ! candidate_valid primary "$primary_request" \
  || ! trusted_context_authorized "$primary_request"; then
  primary="$(policy_identity primary not_invoked policy_ineligible)"
  write_status failed '' "$primary" null
  exit 2
fi
if [ "$fallback_configured" = true ]; then
  if [ "$fallback_request" = - ] || ! candidate_valid fallback "$fallback_request" \
    || ! trusted_context_authorized "$fallback_request"; then
    primary="$(policy_identity primary not_invoked policy_ineligible)"
    fallback="$(policy_identity fallback not_invoked policy_ineligible)"
    write_status failed '' "$primary" "$fallback"
    exit 2
  fi
elif [ "$fallback_configured" = false ] && [ "$fallback_request" != - ]; then
  primary="$(policy_identity primary not_invoked policy_ineligible)"
  write_status failed '' "$primary" null
  exit 2
elif [ "$fallback_configured" != false ]; then
  primary="$(policy_identity primary not_invoked policy_invalid)"
  write_status failed '' "$primary" null
  exit 2
fi

primary_authorized=false
fallback_authorized=false
trusted_candidate_authorized primary && primary_authorized=true
if [ "$fallback_configured" = true ]; then
  trusted_candidate_authorized fallback && fallback_authorized=true
fi
if [ "$primary_authorized" != true ] && [ "$fallback_authorized" != true ]; then
  primary="$(policy_identity primary not_invoked policy_ineligible)"
  if [ "$fallback_configured" = true ]; then
    fallback="$(policy_identity fallback not_invoked policy_ineligible)"
  else
    fallback=null
  fi
  write_status failed '' "$primary" "$fallback"
  exit 2
fi

if [ "$primary_authorized" = true ]; then
  primary_kind="$(jq -er '.adapter.kind' "$primary_request")" || exit 2
  if "$invoker" "$primary_kind" "$primary_request" "$primary_receipt" \
    "$primary_validated"; then
    if digest="$(retain_completed "$primary_request" "$primary_receipt" \
      "$primary_validated")"; then
      primary="$(identity "$primary_request" completed)"
      write_status completed "$digest" "$primary" null
      exit 0
    fi
    primary_failure=provider_contract_failed
  else
    primary_failure="$(failure_code "$primary_receipt")"
  fi
  primary="$(identity "$primary_request" failed "$primary_failure")"
else
  primary="$(identity "$primary_request" failed policy_ineligible)"
fi

rm -f -- "$receipt" "$validated"
if [ "$fallback_configured" = false ]; then
  [ ! -f "$primary_receipt" ] || install -m 600 "$primary_receipt" "$receipt"
  write_status failed '' "$primary" null
  exit 2
fi
if [ "$fallback_authorized" != true ]; then
  fallback="$(identity "$fallback_request" not_invoked policy_ineligible)"
  [ ! -f "$primary_receipt" ] || install -m 600 "$primary_receipt" "$receipt"
  write_status failed '' "$primary" "$fallback"
  exit 2
fi

fallback_kind="$(jq -er '.adapter.kind' "$fallback_request")" || exit 2
if "$invoker" "$fallback_kind" "$fallback_request" "$fallback_receipt" \
  "$fallback_validated"; then
  if digest="$(retain_completed "$fallback_request" "$fallback_receipt" \
    "$fallback_validated")"; then
    fallback="$(identity "$fallback_request" completed)"
    write_status fell_back "$digest" "$primary" "$fallback"
    exit 0
  fi
  fallback_failure=provider_contract_failed
else
  fallback_failure="$(failure_code "$fallback_receipt")"
fi

rm -f -- "$receipt" "$validated"
fallback="$(identity "$fallback_request" failed "$fallback_failure")"
[ ! -f "$fallback_receipt" ] || install -m 600 "$fallback_receipt" "$receipt"
write_status failed '' "$primary" "$fallback"
exit 2
