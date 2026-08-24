#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE_DIR="$(mktemp -d)"
trap 'rm -rf "$CASE_DIR"' EXIT
mkdir -p "$CASE_DIR/run"

D="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
cat > "$CASE_DIR/request-primary.json" <<JSON
{"schema_version":"adoc.semantic_executor_request.v0","request_id":"primary","capability":"code_change_assessment","adapter":{"kind":"generic","provider":"local","model":"local-v1","endpoint_class":"local","endpoint_id":"local","executor_digest":"$D","model_digest":"$D","config_digest":"$D"},"context":{"schema_version":"adoc.semantic_context.v0","context_digest":"$D"}}
JSON
jq '.request_id="fallback" | .adapter.provider="customer" | .adapter.model="customer-v1" | .adapter.endpoint_class="customer_hosted"' \
  "$CASE_DIR/request-primary.json" > "$CASE_DIR/request-fallback.json"

policy() {
  local egress="$1" classes="$2" fallback="${3:-true}"
  jq -n --arg digest "$D" --argjson egress "$egress" --argjson classes "$classes" \
    --argjson fallback "$fallback" '{
      policy_id:"billing-semantic-v1",
      requirements:{capability:{name:"code_change_assessment",version:"1"},
        minimum_maturity:"qualified",scope:"repo:billing",risk:"high",
        allowed_egress:$egress,allowed_residency:["eu"],allowed_retention:["none"],
        allowed_telemetry:["disabled"],allowed_endpoint_classes:$classes,
        operation_digest:$digest,
        context:{schema_version:"adoc.semantic_context.v0",digest:$digest}},
      primary:{request_id:"primary",qualification_id:"qual-local",provider:"local",model:"local-v1",
        executor_digest:$digest,model_digest:$digest,config_digest:$digest,maturity:"production",
        egress:"none",residency:"eu",retention:"none",telemetry:"disabled",endpoint_class:"local",
        context:{schema_version:"adoc.semantic_context.v0",digest:$digest},
        eligibility:{capability_qualified:true,organization_approved:true,runtime_policy_eligible:true,
          scope:["repo:billing"],risk:["high"],operation_digest:$digest}},
      fallback:(if $fallback then {request_id:"fallback",qualification_id:"qual-customer",
        provider:"customer",model:"customer-v1",executor_digest:$digest,model_digest:$digest,
        config_digest:$digest,maturity:"production",egress:"public",residency:"eu",retention:"none",
        telemetry:"disabled",endpoint_class:"customer_hosted",
        context:{schema_version:"adoc.semantic_context.v0",digest:$digest},
        eligibility:{capability_qualified:true,organization_approved:true,runtime_policy_eligible:true,
          scope:["repo:billing"],risk:["high"],operation_digest:$digest}} else null end)
    }' > "$CASE_DIR/policy.json"
}

cat > "$CASE_DIR/invoke-one" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
kind="$1" request="$2" receipt="$3" validated="$4"
id="$(jq -r .request_id "$request")"
printf '%s\n' "$id" >> "$CALLS"
case "${PRIMARY_MODE:-ok}:$id" in
  malformed_success:primary)
    cp "$request" "$validated"
    jq -n --slurpfile request "$request" '{outcome:"completed",
      adapter:$request[0].adapter,request_id:$request[0].request_id}' > "$receipt"
    exit 0
    ;;
  process_fail:primary) exit 2 ;;
  invalid:primary) exit 2 ;;
  timeout:primary) exit 2 ;;
  both_fail:*) exit 2 ;;
esac
cp "$request" "$validated"
digest="sha256:$(sha256sum "$validated" | awk '{print $1}')"
jq -n --slurpfile request "$request" --arg digest "$digest" '{
  schema_version:"adoc.semantic_executor_receipt.v0",outcome:"completed",
  assessment_digest:$digest,adapter:$request[0].adapter,
  request_id:$request[0].request_id
}' > "$receipt"
SH
chmod +x "$CASE_DIR/invoke-one"

run_chain() {
  local fallback_request="${2:-$CASE_DIR/request-fallback.json}"
  : > "$CASE_DIR/calls"
  rm -f "$CASE_DIR/status.json" "$CASE_DIR/receipt.json" "$CASE_DIR/validated.json"
  ADOC_RUN_DIR="$CASE_DIR/run" CALLS="$CASE_DIR/calls" DIGEST="$D" \
    SEMANTIC_INVOKER="$CASE_DIR/invoke-one" PRIMARY_MODE="${1:-ok}" \
    "$ROOT/scripts/invoke-semantic-fallback.sh" "$CASE_DIR/policy.json" \
      "$CASE_DIR/request-primary.json" "$fallback_request" \
      "$CASE_DIR/status.json" "$CASE_DIR/receipt.json" "$CASE_DIR/validated.json"
}

policy '["none","public"]' '["local","customer_hosted"]'
run_chain ok
jq -e '.status == "completed" and .primary.outcome == "completed" and .fallback == null' \
  "$CASE_DIR/status.json" >/dev/null
test "$(cat "$CASE_DIR/calls")" = primary

for mode in process_fail invalid timeout malformed_success; do
  run_chain "$mode"
  jq -e '.status == "fell_back" and .primary.provider == "local"
    and .primary.outcome == "failed" and .fallback.provider == "customer"
    and .fallback.outcome == "completed" and (.assessment_sha256 | startswith("sha256:"))' \
    "$CASE_DIR/status.json" >/dev/null
  test "$(tr '\n' ' ' < "$CASE_DIR/calls")" = 'primary fallback '
done

jq '.capability="proposal_generation"' "$CASE_DIR/request-primary.json" \
  > "$CASE_DIR/request-wrong-capability.json"
mv "$CASE_DIR/request-wrong-capability.json" "$CASE_DIR/request-primary.json"
set +e
run_chain ok
code=$?
set -e
test "$code" = 2
jq -e '.status == "failed" and .primary.outcome == "not_invoked"' \
  "$CASE_DIR/status.json" >/dev/null
test ! -s "$CASE_DIR/calls"
jq '.capability="code_change_assessment"' "$CASE_DIR/request-primary.json" \
  > "$CASE_DIR/request-valid-capability.json"
mv "$CASE_DIR/request-valid-capability.json" "$CASE_DIR/request-primary.json"

set +e
run_chain both_fail
code=$?
set -e
test "$code" = 2
jq -e '.status == "failed" and .primary.outcome == "failed" and .fallback.outcome == "failed"' \
  "$CASE_DIR/status.json" >/dev/null

policy '["none"]' '["local"]'
set +e
run_chain process_fail
code=$?
set -e
test "$code" = 2
jq -e '.status == "failed" and .failure_code == "action.semantic_review_failed"
  and .fallback.outcome == "not_invoked"' "$CASE_DIR/status.json" >/dev/null
test ! -s "$CASE_DIR/calls"

jq 'del(.adapter.kind)' "$CASE_DIR/request-primary.json" > "$CASE_DIR/request-invalid.json"
mv "$CASE_DIR/request-invalid.json" "$CASE_DIR/request-primary.json"
set +e
run_chain ok
code=$?
set -e
test "$code" = 2
jq -e '.status == "failed" and .primary.outcome == "not_invoked"' \
  "$CASE_DIR/status.json" >/dev/null
test ! -s "$CASE_DIR/calls"
jq '.adapter.kind="generic"' "$CASE_DIR/request-primary.json" \
  > "$CASE_DIR/request-valid.json"
mv "$CASE_DIR/request-valid.json" "$CASE_DIR/request-primary.json"

policy '["none"]' '["local"]' false
set +e
run_chain ok
code=$?
set -e
test "$code" = 2
jq -e '.status == "failed" and .primary.outcome == "not_invoked"
  and .fallback == null' "$CASE_DIR/status.json" >/dev/null
test ! -s "$CASE_DIR/calls"

set +e
run_chain process_fail -
code=$?
set -e
test "$code" = 2
jq -e '.status == "failed" and .failure_code == "action.semantic_review_failed"
  and .fallback == null' "$CASE_DIR/status.json" >/dev/null
test "$(cat "$CASE_DIR/calls")" = primary

identity='{"request_id":"primary","provider":"local","model":"local-v1","outcome":"completed","failure_code":null}'
failed_identity='{"request_id":"primary","provider":"local","model":"local-v1","outcome":"failed","failure_code":"provider_failed"}'
fallback_identity='{"request_id":"fallback","provider":"customer","model":"customer-v1","outcome":"completed","failure_code":null}'
for fixture in \
  "{\"status\":\"required\",\"failure_code\":null,\"assessment_sha256\":null,\"primary\":null,\"fallback\":null}" \
  "{\"status\":\"skipped\",\"failure_code\":null,\"assessment_sha256\":null,\"primary\":null,\"fallback\":null}" \
  "{\"status\":\"completed\",\"failure_code\":null,\"assessment_sha256\":\"$D\",\"primary\":$identity,\"fallback\":null}" \
  "{\"status\":\"fell_back\",\"failure_code\":null,\"assessment_sha256\":\"$D\",\"primary\":$failed_identity,\"fallback\":$fallback_identity}" \
  "{\"status\":\"failed\",\"failure_code\":\"action.semantic_review_failed\",\"assessment_sha256\":null,\"primary\":$failed_identity,\"fallback\":null}"; do
  jq -e -f "$ROOT/scripts/semantic-status.jq" <<< "$fixture" >/dev/null
done
if jq -e -f "$ROOT/scripts/semantic-status.jq" \
  <<< '{"status":"future","failure_code":null,"assessment_sha256":null,"primary":null,"fallback":null}' \
  >/dev/null 2>&1; then
  exit 1
fi
if jq -e -f "$ROOT/scripts/semantic-status.jq" \
  <<< "{\"status\":\"completed\",\"failure_code\":null,\"assessment_sha256\":\"$D\",\"primary\":$failed_identity,\"fallback\":null}" \
  >/dev/null 2>&1; then
  exit 1
fi
grep -Fq '"${GITHUB_ACTION_PATH}/scripts/invoke-semantic-fallback.sh"' "$ROOT/action.yml"

echo 'semantic fallback tests passed'
