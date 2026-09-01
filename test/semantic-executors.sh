#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADOC_BIN="${ADOC_BIN:?E3.4 tests require the coordinated adoc binary}"
CASE_DIR="$(mktemp -d)"
trap 'rm -rf "$CASE_DIR"' EXIT
mkdir -p "$CASE_DIR/run"
export HUMAN_REVIEWING_PRINCIPAL_ID=principal:reviewer
export HUMAN_REQUESTING_PRINCIPAL_ID=principal:author

cat > "$CASE_DIR/context-input.json" <<'JSON'
{
  "schema_version": "adoc.semantic_context_input.v0",
  "evaluation_date": "2026-08-24",
  "subject_revision": {"system": "git", "value": "head-sha"},
  "source_revision": {"system": "git", "value": "head-sha"},
  "base_revision": {"system": "git", "value": "base-sha"},
  "head_revision": {"system": "git", "value": "head-sha"},
  "basis": {
    "assessment_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "knowledge_basis": {"kind": "graph_artifact", "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
  },
  "selection": {"algorithm": "action-bounded-lexical", "version": "1", "authorized_scope": ["repo:agentdoc/test"]},
  "capability_policy": {"version": "semantic-context-policy-v1", "rules": [
    {"reason": "permission", "outcome": "insufficient"},
    {"reason": "retention", "outcome": "insufficient"},
    {"reason": "source_outage", "outcome": "failed"},
    {"reason": "truncation", "outcome": "insufficient"},
    {"reason": "resource_limit", "outcome": "insufficient"}
  ]},
  "context_classes": [{"class_id": "changed_knowledge", "requirement": "required", "byte_budget": 4096}],
  "items": [
    {"handle_id": "hunk-a", "class_id": "changed_knowledge", "scope_ref": "repo:agentdoc/test",
      "handle": {"kind": "diff_hunk", "changed_source_id": "src/billing.rs", "hunk_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
      "content": {"diff": "+ durable billing behavior"}, "truncated": false},
    {"handle_id": "object-a", "class_id": "changed_knowledge", "scope_ref": "repo:agentdoc/test",
      "handle": {"kind": "knowledge_object", "object_id": "billing.policy", "semantic_hash": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
      "content": {"body": "Current billing policy."}, "truncated": false}
  ],
  "unavailability": []
}
JSON
"$ADOC_BIN" semantic-context --input "$CASE_DIR/context-input.json" \
  --out "$CASE_DIR/context.json" >/dev/null

cat > "$CASE_DIR/mock-adapter" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
request="$2"
candidate="$3"
if [ "${MOCK_MODE:-valid}" = corrupt ]; then
  printf '{corrupt' > "$candidate"
  exit 0
fi
if [ "${MOCK_MODE:-valid}" = empty ]; then
  : > "$candidate"
  exit 0
fi
if [ "${MOCK_MODE:-valid}" = oversized ]; then
  head -c 1048577 /dev/zero | tr '\0' x > "$candidate"
  exit 0
fi
if [ "${MOCK_MODE:-valid}" = timeout ]; then
  exit 124
fi
jq -n --slurpfile request "$request" '
  $request[0] as $request | ({
    schema_version:"adoc.semantic_assessment.v0",
    context_digest:$request.context.context_digest,
    base_revision:$request.context.base_revision,
    head_revision:$request.context.head_revision,
    identity:{provider:$request.adapter.provider,model:$request.adapter.model},
    materiality_policy_version:"adoc.materiality.v0",
    scope:{handle_ids:["hunk-a","object-a"]},
    findings:[{
      finding_id:"finding-001",classification:"extends_existing_knowledge",
      affected_objects:[{object_id:"billing.policy",content_hash:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}],
      citations:["hunk-a","object-a"],materiality:"material",
      proposed_disposition:"update_existing",
      candidate_updates:[],unresolved_questions:[],
      explanation:"The change extends durable billing behavior."
    }]
  } + if $request.adapter.kind == "human" then {human_review:{
    authority:"semantic_review",
    reviewing_principal_id:$request.human_review.reviewing_principal_id,
    requesting_principal_id:$request.human_review.requesting_principal_id,
    independence:"independent"
  }} else {} end)
' > "$candidate"
SH
chmod +x "$CASE_DIR/mock-adapter"

make_request() {
  local kind="$1" provider="$2" model="$3" endpoint_class="$4" endpoint_id="$5"
  local contract_version="semantic-assessment-task-v1"
  local instructions="Return one structured semantic assessment."
  local prompt_contract prompt_digest
  prompt_contract="$(jq -cn --arg contract_version "$contract_version" \
    --arg instructions "$instructions" '{contract_version:$contract_version,instructions:$instructions}')"
  prompt_digest="sha256:$(printf '%s' "$prompt_contract" | sha256sum | awk '{print $1}')"
  jq -n --slurpfile context "$CASE_DIR/context.json" \
    --arg kind "$kind" --arg provider "$provider" --arg model "$model" \
    --arg endpoint_class "$endpoint_class" --arg endpoint_id "$endpoint_id" \
    --arg contract_version "$contract_version" --arg instructions "$instructions" \
    --arg prompt_digest "$prompt_digest" '({
      schema_version:"adoc.semantic_executor_request.v0",request_id:("request-" + $kind),
      capability:"code_change_assessment",
      adapter:{kind:$kind,provider:$provider,model:$model,endpoint_class:$endpoint_class,
        endpoint_id:$endpoint_id,
        executor_digest:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        model_digest:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        config_digest:"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},
      task_digest:"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
      prompt:{contract_version:$contract_version,digest:$prompt_digest,instructions:$instructions},
      timeout_seconds:600,context:$context[0]
    } + if $kind == "human" then {human_review:{
      reviewing_principal_id:"principal:reviewer",
      requesting_principal_id:"principal:author"
    }} else {} end)' > "$CASE_DIR/request-$kind.json"
}

bind_executor() {
  local request="$1" provider="$2" output="$3"
  local digest
  digest="sha256:$(sha256sum "$provider" | awk '{print $1}')"
  jq --arg digest "$digest" '.adapter.executor_digest = $digest' \
    "$request" > "$output"
}

for row in \
  'claude_code claude-code claude-sonnet-5 public_provider anthropic' \
  'codex codex gpt-5.6-codex public_provider openai' \
  'generic customer-runtime local-model-v1 customer_hosted endpoint-1' \
  'human human authenticated-principal human human-structured'; do
  read -r kind provider model endpoint_class endpoint_id <<< "$row"
  make_request "$kind" "$provider" "$model" "$endpoint_class" "$endpoint_id"
  ADOC_RUN_DIR="$CASE_DIR/run" ADOC_BIN="$ADOC_BIN" \
    TEST_ADAPTER_COMMAND="$CASE_DIR/mock-adapter" \
    "$ROOT/scripts/invoke-semantic-executor.sh" "$kind" \
      "$CASE_DIR/request-$kind.json" "$CASE_DIR/receipt-$kind.json" \
      "$CASE_DIR/validated-$kind.json"
  jq -e --arg provider "$provider" --arg model "$model" '
    .outcome == "completed" and .adapter.provider == $provider and .adapter.model == $model
  ' "$CASE_DIR/receipt-$kind.json" >/dev/null
done

cat > "$CASE_DIR/expected-codex" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$CASE_DIR/replaced-codex" <<SH
#!/usr/bin/env bash
touch "$CASE_DIR/replaced-codex-ran"
SH
chmod +x "$CASE_DIR/expected-codex" "$CASE_DIR/replaced-codex"
bind_executor "$CASE_DIR/request-codex.json" "$CASE_DIR/expected-codex" \
  "$CASE_DIR/request-expected-codex.json"
set +e
ADOC_RUN_DIR="$CASE_DIR/run" ADOC_BIN="$ADOC_BIN" \
  ADOC_PROVIDER_BIN="$CASE_DIR/replaced-codex" INPUT_OPENAI_API_KEY=test-key \
  "$ROOT/scripts/invoke-semantic-executor.sh" codex \
    "$CASE_DIR/request-expected-codex.json" "$CASE_DIR/replaced-codex-receipt.json" \
    "$CASE_DIR/replaced-codex-assessment.json"
code=$?
set -e
test "$code" = 2
jq -e '.outcome == "failed" and .failure_code == "executor_digest_mismatch"' \
  "$CASE_DIR/replaced-codex-receipt.json" >/dev/null
test ! -e "$CASE_DIR/replaced-codex-ran"

set +e
ADOC_RUN_DIR="$CASE_DIR/run" ADOC_BIN="$ADOC_BIN" \
  TEST_ADAPTER_COMMAND="$CASE_DIR/mock-adapter" \
  "$ROOT/scripts/invoke-semantic-executor.sh" codex \
    "$CASE_DIR/request-claude_code.json" "$CASE_DIR/receipt-codex.json" \
    "$CASE_DIR/validated-codex.json"
code=$?
set -e
test "$code" = 2
test ! -e "$CASE_DIR/receipt-codex.json"
test ! -e "$CASE_DIR/validated-codex.json"

jq '.human_review.reviewing_principal_id = "principal:claimed-reviewer"' \
  "$CASE_DIR/request-human.json" > "$CASE_DIR/claimed-human.json"
set +e
ADOC_RUN_DIR="$CASE_DIR/run" ADOC_BIN="$ADOC_BIN" \
  TEST_ADAPTER_COMMAND="$CASE_DIR/mock-adapter" \
  "$ROOT/scripts/invoke-semantic-executor.sh" human "$CASE_DIR/claimed-human.json" \
    "$CASE_DIR/claimed-human-receipt.json" "$CASE_DIR/never-claimed-human.json"
code=$?
set -e
test "$code" = 2
jq -e '.outcome == "failed"' "$CASE_DIR/claimed-human-receipt.json" >/dev/null
test ! -e "$CASE_DIR/never-claimed-human.json"

make_request codex codex gpt-5.6-codex public_provider openai
set +e
ADOC_RUN_DIR="$CASE_DIR/run" ADOC_BIN="$ADOC_BIN" MOCK_MODE=corrupt \
  TEST_ADAPTER_COMMAND="$CASE_DIR/mock-adapter" \
  "$ROOT/scripts/invoke-semantic-executor.sh" codex "$CASE_DIR/request-codex.json" \
    "$CASE_DIR/failed.json" "$CASE_DIR/never.json"
code=$?
set -e
test "$code" = 2
jq -e '.outcome == "failed" and .failure_code == "assessment.semantic_schema_invalid"' \
  "$CASE_DIR/failed.json" >/dev/null
test ! -e "$CASE_DIR/never.json"

for mode in oversized timeout empty; do
  set +e
  ADOC_RUN_DIR="$CASE_DIR/run" ADOC_BIN="$ADOC_BIN" MOCK_MODE="$mode" \
    TEST_ADAPTER_COMMAND="$CASE_DIR/mock-adapter" \
    "$ROOT/scripts/invoke-semantic-executor.sh" codex "$CASE_DIR/request-codex.json" \
      "$CASE_DIR/failed-$mode.json" "$CASE_DIR/never-$mode.json"
  code=$?
  set -e
  test "$code" = 2
  case "$mode" in
    timeout) expected=provider_timeout ;;
    oversized) expected=provider_output_too_large ;;
    empty) expected=provider_contract_failed ;;
  esac
  jq -e --arg code "$expected" \
    '.outcome == "failed" and .failure_code == $code' \
    "$CASE_DIR/failed-$mode.json" >/dev/null
  test ! -e "$CASE_DIR/never-$mode.json"
done

if [ -x /usr/bin/timeout ]; then
  cat > "$CASE_DIR/fake-claude" <<SH
#!/usr/bin/env bash
set -euo pipefail
tee "$CASE_DIR/claude-prompt" >/dev/null
head -c 2097152 /dev/zero | tr '\0' x
SH
  chmod +x "$CASE_DIR/fake-claude"
  bind_executor "$CASE_DIR/request-claude_code.json" "$CASE_DIR/fake-claude" \
    "$CASE_DIR/request-fake-claude.json"
  set +e
  ADOC_RUN_DIR="$CASE_DIR/run" ADOC_BIN="$ADOC_BIN" \
    ADOC_PROVIDER_BIN="$CASE_DIR/fake-claude" INPUT_ANTHROPIC_API_KEY=test-key \
    "$ROOT/scripts/invoke-semantic-executor.sh" claude_code \
      "$CASE_DIR/request-fake-claude.json" "$CASE_DIR/oversized-claude.json" \
      "$CASE_DIR/oversized-claude-assessment.json"
  code=$?
  set -e
  test "$code" = 2
  jq -e '.outcome == "failed" and .failure_code == "provider_output_too_large"' \
    "$CASE_DIR/oversized-claude.json" >/dev/null
  grep -Fq '<trusted-assessment-identity>' "$CASE_DIR/claude-prompt"
  grep -Fq '{"provider":"claude-code","model":"claude-sonnet-5"}' \
    "$CASE_DIR/claude-prompt"

  cat > "$CASE_DIR/fake-stubborn-claude" <<'SH'
#!/usr/bin/env bash
trap '' TERM
while :; do sleep 1; done
SH
  chmod +x "$CASE_DIR/fake-stubborn-claude"
  bind_executor "$CASE_DIR/request-claude_code.json" "$CASE_DIR/fake-stubborn-claude" \
    "$CASE_DIR/request-stubborn-claude.json"
  jq '.timeout_seconds = 60' "$CASE_DIR/request-stubborn-claude.json" \
    > "$CASE_DIR/request-stubborn-claude.tmp"
  mv "$CASE_DIR/request-stubborn-claude.tmp" "$CASE_DIR/request-stubborn-claude.json"
  set +e
  ADOC_RUN_DIR="$CASE_DIR/run" ADOC_BIN="$ADOC_BIN" \
    ADOC_PROVIDER_BIN="$CASE_DIR/fake-stubborn-claude" INPUT_ANTHROPIC_API_KEY=test-key \
    "$ROOT/scripts/invoke-semantic-executor.sh" claude_code \
      "$CASE_DIR/request-stubborn-claude.json" "$CASE_DIR/stubborn-claude.json" \
      "$CASE_DIR/stubborn-claude-assessment.json"
  code=$?
  set -e
  test "$code" = 2
  jq -e '.outcome == "failed" and .failure_code == "provider_timeout"' \
    "$CASE_DIR/stubborn-claude.json" >/dev/null

  cat > "$CASE_DIR/fake-codex" <<SH
#!/usr/bin/env bash
set -uo pipefail
output=''
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = --output-last-message ]; then
    output="\$2"
    shift 2
  else
    shift
  fi
done
test -n "\$output"
ulimit -Sf unlimited 2>/dev/null || :
head -c 2097152 /dev/zero | tr '\0' x > "\$output"
code=\$?
wc -c < "\$output" > "$CASE_DIR/codex-capped-bytes"
exit "\$code"
SH
  chmod +x "$CASE_DIR/fake-codex"
  bind_executor "$CASE_DIR/request-codex.json" "$CASE_DIR/fake-codex" \
    "$CASE_DIR/request-fake-codex.json"
  set +e
  ADOC_RUN_DIR="$CASE_DIR/run" ADOC_BIN="$ADOC_BIN" \
    ADOC_PROVIDER_BIN="$CASE_DIR/fake-codex" INPUT_OPENAI_API_KEY=test-key \
    "$ROOT/scripts/invoke-semantic-executor.sh" codex \
      "$CASE_DIR/request-fake-codex.json" "$CASE_DIR/oversized-codex.json" \
      "$CASE_DIR/oversized-codex-assessment.json"
  code=$?
  set -e
  test "$code" = 2
  jq -e '.outcome == "failed" and .failure_code == "provider_output_too_large"' \
    "$CASE_DIR/oversized-codex.json" >/dev/null
  codex_capped_bytes="$(cat "$CASE_DIR/codex-capped-bytes")"
  test "$codex_capped_bytes" -gt 1048576
  test "$codex_capped_bytes" -le 1049600

  cat > "$CASE_DIR/fake-empty-codex" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$CASE_DIR/fake-empty-codex"
  bind_executor "$CASE_DIR/request-codex.json" "$CASE_DIR/fake-empty-codex" \
    "$CASE_DIR/request-empty-codex.json"
  set +e
  ADOC_RUN_DIR="$CASE_DIR/run" ADOC_BIN="$ADOC_BIN" \
    ADOC_PROVIDER_BIN="$CASE_DIR/fake-empty-codex" INPUT_OPENAI_API_KEY=test-key \
    "$ROOT/scripts/invoke-semantic-executor.sh" codex \
      "$CASE_DIR/request-empty-codex.json" "$CASE_DIR/empty-codex.json" \
      "$CASE_DIR/empty-codex-assessment.json"
  code=$?
  set -e
  test "$code" = 2
  jq -e '.outcome == "failed" and .failure_code == "provider_contract_failed"' \
    "$CASE_DIR/empty-codex.json" >/dev/null
fi

make_request generic customer-runtime local-model-v1 customer_hosted endpoint-1
cat > "$CASE_DIR/denied-policy.json" <<'JSON'
{"schema_version":"adoc.semantic_endpoint_policy.v0","endpoint_id":"other","endpoint_class":"customer_hosted","url":"https://executor.invalid/v1/assess","allowed":true}
JSON
cat > "$CASE_DIR/fake-curl" <<SH
#!/usr/bin/env bash
touch "$CASE_DIR/curl-was-called"
exit 1
SH
chmod +x "$CASE_DIR/fake-curl"
set +e
ADOC_RUN_DIR="$CASE_DIR/run" ADOC_BIN="$ADOC_BIN" \
  SEMANTIC_ENDPOINT_POLICY="$CASE_DIR/denied-policy.json" \
  SEMANTIC_ENDPOINT_URL='https://executor.invalid/v1/assess' CURL_BIN="$CASE_DIR/fake-curl" \
  "$ROOT/scripts/invoke-semantic-executor.sh" generic "$CASE_DIR/request-generic.json" \
    "$CASE_DIR/denied.json" "$CASE_DIR/denied-assessment.json"
code=$?
set -e
test "$code" = 2
test ! -e "$CASE_DIR/curl-was-called"

make_request generic customer-runtime local-model-v1 local endpoint-local
for url in 'https://executor.invalid/v1/assess' \
  'http://127.0.0.1:80@remote.invalid/v1/assess'; do
  jq -n --arg url "$url" '{
    schema_version:"adoc.semantic_endpoint_policy.v0",endpoint_id:"endpoint-local",
    endpoint_class:"local",url:$url,allowed:true
  }' > "$CASE_DIR/local-policy.json"
  rm -f "$CASE_DIR/curl-was-called"
  set +e
  ADOC_RUN_DIR="$CASE_DIR/run" ADOC_BIN="$ADOC_BIN" \
    SEMANTIC_ENDPOINT_POLICY="$CASE_DIR/local-policy.json" \
    SEMANTIC_ENDPOINT_URL="$url" CURL_BIN="$CASE_DIR/fake-curl" \
    "$ROOT/scripts/invoke-semantic-executor.sh" generic \
      "$CASE_DIR/request-generic.json" "$CASE_DIR/local-denied.json" \
      "$CASE_DIR/local-denied-assessment.json"
  code=$?
  set -e
  test "$code" = 2
  jq -e '.outcome == "failed" and .failure_code == "endpoint_url_invalid"' \
    "$CASE_DIR/local-denied.json" >/dev/null
  test ! -e "$CASE_DIR/curl-was-called"
done

local_url='https://localhost:8443/v1/assess'
jq --arg url "$local_url" '.url = $url' "$CASE_DIR/local-policy.json" \
  > "$CASE_DIR/local-policy-allowed.json"
set +e
ADOC_RUN_DIR="$CASE_DIR/run" ADOC_BIN="$ADOC_BIN" \
  SEMANTIC_ENDPOINT_POLICY="$CASE_DIR/local-policy-allowed.json" \
  SEMANTIC_ENDPOINT_URL="$local_url" CURL_BIN="$CASE_DIR/fake-curl" \
  "$ROOT/scripts/invoke-semantic-executor.sh" generic \
    "$CASE_DIR/request-generic.json" "$CASE_DIR/local-called.json" \
    "$CASE_DIR/local-called-assessment.json"
code=$?
set -e
test "$code" = 2
jq -e '.outcome == "failed" and .failure_code == "provider_failed"' \
  "$CASE_DIR/local-called.json" >/dev/null
test -e "$CASE_DIR/curl-was-called"

make_request generic customer-runtime local-model-v1 customer_hosted endpoint-1
cat > "$CASE_DIR/allowed-policy.json" <<'JSON'
{"schema_version":"adoc.semantic_endpoint_policy.v0","endpoint_id":"endpoint-1","endpoint_class":"customer_hosted","url":"https://executor.invalid/v1/assess","allowed":true}
JSON
cat > "$CASE_DIR/fake-curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$CASE_DIR/curl-args"
exit 63
SH
chmod +x "$CASE_DIR/fake-curl"
set +e
ADOC_RUN_DIR="$CASE_DIR/run" ADOC_BIN="$ADOC_BIN" \
  SEMANTIC_ENDPOINT_POLICY="$CASE_DIR/allowed-policy.json" \
  SEMANTIC_ENDPOINT_URL='https://executor.invalid/v1/assess' CURL_BIN="$CASE_DIR/fake-curl" \
  "$ROOT/scripts/invoke-semantic-executor.sh" generic "$CASE_DIR/request-generic.json" \
    "$CASE_DIR/oversized-generic.json" "$CASE_DIR/oversized-generic-assessment.json"
code=$?
set -e
test "$code" = 2
jq -e '.outcome == "failed" and .failure_code == "provider_output_too_large"' \
  "$CASE_DIR/oversized-generic.json" >/dev/null
grep -Fxq -- '--max-filesize' "$CASE_DIR/curl-args"
grep -Fxq '1048576' "$CASE_DIR/curl-args"
test "$(head -n 1 "$CASE_DIR/curl-args")" = --disable

grep -Fq -- '--ephemeral' "$ROOT/scripts/invoke-semantic-executor.sh"
grep -Fq -- '--sandbox read-only' "$ROOT/scripts/invoke-semantic-executor.sh"
grep -Fq -- 'web_search="disabled"' "$ROOT/scripts/invoke-semantic-executor.sh"
grep -Fq -- 'features.shell_tool=false' "$ROOT/scripts/invoke-semantic-executor.sh"
grep -Fq -- 'features.multi_agent=false' "$ROOT/scripts/invoke-semantic-executor.sh"
grep -Fq -- '--json-schema' "$ROOT/scripts/invoke-semantic-executor.sh"
grep -Fq -- '--kill-after=5s' "$ROOT/scripts/invoke-semantic-executor.sh"
grep -Fq -- 'ulimit -HSf 1025' "$ROOT/scripts/invoke-semantic-executor.sh"
jq -e '
  .properties.human_review["$ref"] == "#/$defs/humanReview"
  and .["$defs"].humanReview.required == [
    "authority","reviewing_principal_id","requesting_principal_id","independence"
  ]
  and .["$defs"].humanReview.properties.authority.const == "semantic_review"
  and .["$defs"].humanReview.properties.independence.enum
    == ["self_assessment","independent"]
' "$ROOT/schemas/adoc.semantic_assessment.v0.schema.json" >/dev/null

echo 'semantic executor adapter tests passed'
