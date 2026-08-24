#!/usr/bin/env bash
# Runs one eligible semantic executor and, on any failure, one eligible fallback.
set -uo pipefail

policy="${1:?semantic fallback policy is required}"
primary_request="${2:?primary request is required}"
fallback_request="${3:?fallback request or - is required}"
status="${4:?semantic status path is required}"
receipt="${5:?semantic receipt path is required}"
validated="${6:?validated assessment path is required}"
OUT="${ADOC_RUN_DIR:-${RUNNER_TEMP:?}}"
ROOT="${GITHUB_ACTION_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
invoker="${SEMANTIC_INVOKER:-$ROOT/scripts/invoke-semantic-executor.sh}"
primary_receipt="$OUT/semantic-primary-receipt.json"
primary_validated="$OUT/semantic-primary-assessment.json"
fallback_receipt="$OUT/semantic-fallback-receipt.json"
fallback_validated="$OUT/semantic-fallback-assessment.json"

cleanup() {
  rm -f -- "$primary_receipt" "$primary_validated" \
    "$fallback_receipt" "$fallback_validated"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
rm -f -- "$status" "$receipt" "$validated"

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
if ! candidate_valid primary "$primary_request"; then
  primary="$(policy_identity primary not_invoked policy_ineligible)"
  write_status failed '' "$primary" null
  exit 2
fi
if [ "$fallback_configured" = true ]; then
  if [ "$fallback_request" = - ] || ! candidate_valid fallback "$fallback_request"; then
    primary="$(policy_identity primary not_invoked policy_ineligible)"
    fallback="$(policy_identity fallback not_invoked policy_ineligible)"
    write_status failed '' "$primary" "$fallback"
    exit 2
  fi
elif [ "$fallback_configured" != false ]; then
  primary="$(policy_identity primary not_invoked policy_invalid)"
  write_status failed '' "$primary" null
  exit 2
fi

primary_kind="$(jq -er '.adapter.kind' "$primary_request")" || exit 2
if "$invoker" "$primary_kind" "$primary_request" "$primary_receipt" \
  "$primary_validated"; then
  digest="$(jq -er '.assessment_digest | select(test("^sha256:[0-9a-f]{64}$"))' \
    "$primary_receipt")" || exit 2
  install -m 600 "$primary_receipt" "$receipt"
  install -m 600 "$primary_validated" "$validated"
  primary="$(identity "$primary_request" completed)"
  write_status completed "$digest" "$primary" null
  exit 0
fi

primary="$(identity "$primary_request" failed "$(failure_code "$primary_receipt")")"
if [ "$fallback_configured" = false ]; then
  [ ! -f "$primary_receipt" ] || install -m 600 "$primary_receipt" "$receipt"
  write_status failed '' "$primary" null
  exit 2
fi

fallback_kind="$(jq -er '.adapter.kind' "$fallback_request")" || exit 2
if "$invoker" "$fallback_kind" "$fallback_request" "$fallback_receipt" \
  "$fallback_validated"; then
  digest="$(jq -er '.assessment_digest | select(test("^sha256:[0-9a-f]{64}$"))' \
    "$fallback_receipt")" || exit 2
  install -m 600 "$fallback_receipt" "$receipt"
  install -m 600 "$fallback_validated" "$validated"
  fallback="$(identity "$fallback_request" completed)"
  write_status fell_back "$digest" "$primary" "$fallback"
  exit 0
fi

fallback="$(identity "$fallback_request" failed "$(failure_code "$fallback_receipt")")"
[ ! -f "$fallback_receipt" ] || install -m 600 "$fallback_receipt" "$receipt"
write_status failed '' "$primary" "$fallback"
exit 2
