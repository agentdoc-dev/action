#!/usr/bin/env bash
# Invokes one provider-neutral semantic adapter and validates its candidate
# through the coordinated AgentDoc runtime before any downstream consumer.
set -uo pipefail

# Authorization helpers need source access, never provider credentials.
semantic_anthropic_key="${INPUT_ANTHROPIC_API_KEY:-}"
semantic_claude_token="${INPUT_CLAUDE_CODE_OAUTH_TOKEN:-}"
semantic_openai_key="${INPUT_OPENAI_API_KEY:-}"
semantic_endpoint_token="${SEMANTIC_ENDPOINT_TOKEN:-}"
export -n semantic_anthropic_key semantic_claude_token semantic_openai_key \
  semantic_endpoint_token credential token
unset INPUT_ANTHROPIC_API_KEY INPUT_CLAUDE_CODE_OAUTH_TOKEN INPUT_OPENAI_API_KEY \
  ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY SEMANTIC_ENDPOINT_TOKEN

kind="${1:?adapter kind is required}"
request="${2:?semantic executor request is required}"
receipt="${3:?semantic executor receipt path is required}"
validated="${4:?validated assessment path is required}"
OUT="${ADOC_RUN_DIR:-${RUNNER_TEMP:?}}"
ROOT="${GITHUB_ACTION_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
ADOC_BIN="${ADOC_BIN:-$(command -v adoc)}"
candidate="$OUT/semantic-adapter-candidate.json"
raw="$OUT/semantic-adapter-raw.json"
prompt="$OUT/semantic-adapter-prompt.md"
provider_home="$OUT/semantic-adapter-home"
provider_cwd="$OUT/semantic-adapter-cwd"
native_home="$OUT/semantic-adapter-native-home"
schema="$ROOT/schemas/adoc.semantic_assessment.v0.schema.json"
empty_mcp="$OUT/semantic-adapter-empty-mcp.json"
trusted_human_args=()

cleanup() {
  rm -rf -- "$provider_home" "$provider_cwd" "$native_home"
  rm -f -- "$candidate" "$raw" "$prompt" "$empty_mcp"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
rm -f -- "$candidate" "$raw" "$receipt" "$validated"
rm -rf -- "$native_home"
mkdir -m 700 -- "$native_home" || exit 2

run_native() {
  env -i HOME="$native_home" PATH=/usr/bin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    "$ADOC_BIN" "$@"
}

record_failure() {
  printf '{}\n' > "$candidate"
  run_native semantic-executor --request "$request" --assessment "$candidate" \
    --failure-code "$1" --receipt "$receipt" \
    --validated-assessment "$validated" >/dev/null 2>&1 || :
  printf '::warning::AgentDoc: semantic adapter failed (%s)\n' "$1" >&2
  return 2
}

record_provider_failure() {
  case "$1" in
    28 | 124 | 137) record_failure provider_timeout ;;
    63 | 153) record_failure provider_output_too_large ;;
    *) record_failure provider_failed ;;
  esac
  exit $?
}

verify_provider() {
  local provider="$1" expected actual
  [ -x "$provider" ] || { record_failure provider_unavailable; return $?; }
  expected="$(jq -er '.adapter.executor_digest' "$request")" || return 2
  actual="sha256:$(sha256sum "$provider" | awk '{print $1}')"
  [ "$actual" = "$expected" ] \
    || { record_failure executor_digest_mismatch; return $?; }
}

trusted_authorization_current() {
  [ "${ADOC_TRUSTED_PHASE:-false}" != true ] \
    || "$ROOT/scripts/trusted-authorization-current.sh"
}

[ -f "$request" ] || { echo '::error::semantic executor request is missing' >&2; exit 2; }
adapter="$(jq -er '.adapter.kind' "$request" 2>/dev/null)" || exit 2
[ "$adapter" = "$kind" ] || { echo '::error::semantic adapter kind does not match request' >&2; exit 2; }
timeout_seconds="$(jq -er '.timeout_seconds' "$request")" || exit 2
if [ "$kind" = human ]; then
  reviewing_principal_id="${HUMAN_REVIEWING_PRINCIPAL_ID:-}"
  requesting_principal_id="${HUMAN_REQUESTING_PRINCIPAL_ID:-}"
  if [ -z "$reviewing_principal_id" ] || [ -z "$requesting_principal_id" ]; then
    record_failure human_identity_unavailable
    exit $?
  fi
  trusted_human_args=(
    --reviewing-principal-id "$reviewing_principal_id"
    --requesting-principal-id "$requesting_principal_id"
  )
fi
if [ "${ADOC_TRUSTED_PHASE:-false}" = true ]; then
  assessment_path="$(cat "$OUT/assessment-path" 2>/dev/null || true)"
  expected_assessment="${ADOC_TRUSTED_ASSESSMENT_DIGEST:-}"
  actual_assessment="sha256:$(sha256sum "$assessment_path" 2>/dev/null | awk '{print $1}')"
  if [ "$actual_assessment" != "$expected_assessment" ] \
    || ! jq -e --arg assessment "$expected_assessment" \
    --slurpfile request "$request" '
      .state == "authorized"
      and .executor.provider == $request[0].adapter.provider
      and .executor.model == $request[0].adapter.model
      and .executor.config_digest == $request[0].adapter.config_digest
      and $request[0].context.basis.assessment_digest == $assessment
    ' "$OUT/trusted-phase-status.json" >/dev/null 2>&1 \
    || ! "$ROOT/scripts/trusted-context-authorized.sh" "$request"; then
    record_failure policy_ineligible
    exit $?
  fi
fi

if [ -n "${TEST_ADAPTER_COMMAND:-}" ]; then
  trusted_authorization_current \
    || { record_failure policy_ineligible; exit $?; }
  env -i PATH=/usr/bin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    MOCK_MODE="${MOCK_MODE:-valid}" \
    "$TEST_ADAPTER_COMMAND" "$kind" "$request" "$candidate"
  provider_code=$?
  if [ "$provider_code" -ne 0 ]; then
    record_provider_failure "$provider_code"
  fi
else
  mkdir -m 700 "$provider_home" "$provider_cwd"
  {
    jq -r '.prompt.instructions' "$request"
    echo '<trusted-assessment-identity>'
    jq -c '.adapter | {provider,model}' "$request"
    echo '</trusted-assessment-identity>'
    echo '<untrusted-semantic-context>'
    jq -c '.context' "$request"
    echo '</untrusted-semantic-context>'
  } > "$prompt"
  chmod 600 "$prompt"
  printf '{"mcpServers":{}}\n' > "$empty_mcp"
  chmod 600 "$empty_mcp"

  case "$kind" in
    claude_code)
      provider="${ADOC_PROVIDER_BIN:-$OUT/provider/claude}"
      verify_provider "$provider" || exit $?
      credential_name=''
      credential=''
      if [ -n "${semantic_anthropic_key:-}" ]; then
        credential_name=ANTHROPIC_API_KEY
        credential="$semantic_anthropic_key"
      elif [ -n "${semantic_claude_token:-}" ]; then
        credential_name=CLAUDE_CODE_OAUTH_TOKEN
        credential="$semantic_claude_token"
      else
        record_failure credentials_unavailable
        exit $?
      fi
      trusted_authorization_current \
        || { record_failure policy_ineligible; exit $?; }
      (cd "$provider_cwd" && env -i \
        HOME="$provider_home" XDG_CONFIG_HOME="$provider_home" \
        PATH=/usr/bin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 \
        "$credential_name=$credential" \
        /usr/bin/timeout --kill-after=5s "$timeout_seconds" "$provider" -p \
        --model "$(jq -r '.adapter.model' "$request")" --output-format json \
        --json-schema "$(cat "$schema")" --safe-mode --setting-sources "" \
        --settings '{}' --strict-mcp-config --mcp-config "$empty_mcp" \
        --disable-slash-commands --tools "" --permission-mode dontAsk \
        --no-session-persistence --no-chrome < "$prompt" \
        | head -c 1048577 > "$raw")
      provider_code=$?
      credential=''
      [ "$(wc -c < "$raw" | tr -d ' ')" -le 1048576 ] \
        || { record_failure provider_output_too_large; exit $?; }
      if [ "$provider_code" -ne 0 ]; then
        record_provider_failure "$provider_code"
      fi
      jq -e '.structured_output | objects' "$raw" > "$candidate" 2>/dev/null \
        || { record_failure provider_contract_failed; exit $?; }
      ;;
    codex)
      provider="${ADOC_PROVIDER_BIN:-$OUT/provider/codex}"
      verify_provider "$provider" || exit $?
      credential="${semantic_openai_key:-}"
      [ -n "$credential" ] || { record_failure credentials_unavailable; exit $?; }
      trusted_authorization_current \
        || { record_failure policy_ineligible; exit $?; }
      (ulimit -HSf 1025 && cd "$provider_cwd" && env -i \
        HOME="$provider_home" CODEX_HOME="$provider_home" \
        PATH=/usr/bin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 OPENAI_API_KEY="$credential" \
        /usr/bin/timeout --kill-after=5s "$timeout_seconds" "$provider" exec \
        --ephemeral --ignore-user-config --ignore-rules --strict-config \
        --sandbox read-only --skip-git-repo-check --color never \
        --model "$(jq -r '.adapter.model' "$request")" \
        --output-schema "$schema" --output-last-message "$candidate" \
        -c 'approval_policy="never"' -c 'web_search="disabled"' \
        -c 'features.shell_tool=false' -c 'features.multi_agent=false' - < "$prompt" \
        > /dev/null 2> "$OUT/semantic-adapter-stderr.log")
      provider_code=$?
      if [ "$provider_code" -ne 0 ]; then
        record_provider_failure "$provider_code"
      fi
      credential=''
      ;;
    generic)
      policy="${SEMANTIC_ENDPOINT_POLICY:-}"
      url="${SEMANTIC_ENDPOINT_URL:-}"
      endpoint_id="$(jq -er '.adapter.endpoint_id' "$request")" || exit 2
      endpoint_class="$(jq -er '.adapter.endpoint_class' "$request")" || exit 2
      [ -f "$policy" ] && jq -e --arg id "$endpoint_id" --arg class "$endpoint_class" \
        --arg url "$url" '
          type == "object"
          and keys == ["allowed","endpoint_class","endpoint_id","schema_version","url"]
          and .schema_version == "adoc.semantic_endpoint_policy.v0"
          and .allowed == true and .endpoint_id == $id
          and .endpoint_class == $class and .url == $url
        ' "$policy" >/dev/null 2>&1 \
        || { record_failure endpoint_policy_denied; exit $?; }
      if [ "$endpoint_class" = local ]; then
        loopback_url='^https?://(localhost|127[.]0[.]0[.]1)(:[0-9]{1,5})?([/?#]|$)'
        [[ "$url" =~ $loopback_url ]] \
          || { record_failure endpoint_url_invalid; exit $?; }
      else
        case "$endpoint_class:$url" in
          customer_hosted:https://?* | public_provider:https://?*) ;;
          *) record_failure endpoint_url_invalid; exit $? ;;
        esac
      fi
      endpoint_policy_digest="sha256:$(sha256sum "$policy" | awk '{print $1}')"
      endpoint_config="$(jq -cnS --arg policy "$endpoint_policy_digest" \
        --arg url "$url" '{endpoint_policy_sha256:$policy,url:$url}')"
      expected_config="$(jq -r '.adapter.config_digest' "$request")"
      [ "sha256:$(printf '%s' "$endpoint_config" | sha256sum | awk '{print $1}')" \
        = "$expected_config" ] \
        || { record_failure endpoint_policy_denied; exit $?; }
      curl_bin="${CURL_BIN:-curl}"
      case "$curl_bin" in
        */*) : ;;
        *) curl_bin="$(command -v "$curl_bin")" \
          || { record_failure provider_unavailable; exit $?; } ;;
      esac
      token="${semantic_endpoint_token:-}"
      curl_args=(--disable --fail --silent --show-error --max-time "$timeout_seconds" \
        --max-filesize 1048576
        --header 'content-type: application/json' --data-binary "@$request" --output "$candidate")
      [ -z "$token" ] || curl_args+=(--header "authorization: Bearer $token")
      trusted_authorization_current \
        || { record_failure policy_ineligible; exit $?; }
      env -i PATH=/usr/bin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 \
        "$curl_bin" "${curl_args[@]}" "$url"
      provider_code=$?
      if [ "$provider_code" -ne 0 ]; then
        record_provider_failure "$provider_code"
      fi
      token=''
      ;;
    human)
      source="${HUMAN_ASSESSMENT_PATH:-}"
      [ -f "$source" ] || { record_failure human_submission_missing; exit $?; }
      trusted_authorization_current \
        || { record_failure policy_ineligible; exit $?; }
      install -m 600 "$source" "$candidate" \
        || { record_failure human_submission_unreadable; exit $?; }
      ;;
    *)
      record_failure adapter_unknown
      exit $?
      ;;
  esac
fi

[ -s "$candidate" ] || { record_failure provider_contract_failed; exit $?; }
[ "$(wc -c < "$candidate" | tr -d ' ')" -le 1048576 ] \
  || { record_failure provider_output_too_large; exit $?; }

if [ "$kind" = human ]; then
  run_native semantic-executor --request "$request" --assessment "$candidate" \
    --receipt "$receipt" --validated-assessment "$validated" \
    "${trusted_human_args[@]}" >/dev/null
else
  run_native semantic-executor --request "$request" --assessment "$candidate" \
    --receipt "$receipt" --validated-assessment "$validated" >/dev/null
fi
exit $?
