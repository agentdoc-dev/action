#!/usr/bin/env bash
# Invokes one provider-neutral semantic adapter and validates its candidate
# through the coordinated AgentDoc runtime before any downstream consumer.
set -uo pipefail

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
schema="$ROOT/schemas/adoc.semantic_assessment.v0.schema.json"
empty_mcp="$OUT/semantic-adapter-empty-mcp.json"
trusted_human_args=()

cleanup() {
  rm -rf -- "$provider_home" "$provider_cwd"
  rm -f -- "$candidate" "$raw" "$prompt" "$empty_mcp"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
rm -f -- "$candidate" "$raw" "$validated"

record_failure() {
  printf '{}\n' > "$candidate"
  "$ADOC_BIN" semantic-executor --request "$request" --assessment "$candidate" \
    --failure-code "$1" --receipt "$receipt" \
    --validated-assessment "$validated" >/dev/null 2>&1 || :
  printf '::warning::AgentDoc: semantic adapter failed (%s)\n' "$1" >&2
  return 2
}

record_provider_failure() {
  case "$1" in
    28 | 124) record_failure provider_timeout ;;
    *) record_failure provider_failed ;;
  esac
  exit $?
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

if [ -n "${TEST_ADAPTER_COMMAND:-}" ]; then
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
      [ -x "$provider" ] || record_failure provider_unavailable || exit $?
      credential_name=''
      credential=''
      if [ -n "${INPUT_ANTHROPIC_API_KEY:-}" ]; then
        credential_name=ANTHROPIC_API_KEY
        credential="$INPUT_ANTHROPIC_API_KEY"
      elif [ -n "${INPUT_CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        credential_name=CLAUDE_CODE_OAUTH_TOKEN
        credential="$INPUT_CLAUDE_CODE_OAUTH_TOKEN"
      else
        record_failure credentials_unavailable
        exit $?
      fi
      unset INPUT_ANTHROPIC_API_KEY INPUT_CLAUDE_CODE_OAUTH_TOKEN \
        ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
      (cd "$provider_cwd" && env -i \
        HOME="$provider_home" XDG_CONFIG_HOME="$provider_home" \
        PATH=/usr/bin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 \
        "$credential_name=$credential" \
        /usr/bin/timeout "$timeout_seconds" "$provider" -p \
        --model "$(jq -r '.adapter.model' "$request")" --output-format json \
        --json-schema "$(cat "$schema")" --safe-mode --setting-sources "" \
        --settings '{}' --strict-mcp-config --mcp-config "$empty_mcp" \
        --disable-slash-commands --tools "" --permission-mode dontAsk \
        --no-session-persistence --no-chrome < "$prompt" > "$raw")
      provider_code=$?
      if [ "$provider_code" -ne 0 ]; then
        record_provider_failure "$provider_code"
      fi
      credential=''
      [ "$(wc -c < "$raw" | tr -d ' ')" -le 1048576 ] \
        || { record_failure provider_output_too_large; exit $?; }
      jq -e '.structured_output | objects' "$raw" > "$candidate" 2>/dev/null \
        || { record_failure provider_contract_failed; exit $?; }
      ;;
    codex)
      provider="${ADOC_PROVIDER_BIN:-$OUT/provider/codex}"
      [ -x "$provider" ] || record_failure provider_unavailable || exit $?
      credential="${INPUT_OPENAI_API_KEY:-}"
      [ -n "$credential" ] || { record_failure credentials_unavailable; exit $?; }
      unset INPUT_OPENAI_API_KEY OPENAI_API_KEY
      (cd "$provider_cwd" && env -i \
        HOME="$provider_home" CODEX_HOME="$provider_home" \
        PATH=/usr/bin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 OPENAI_API_KEY="$credential" \
        /usr/bin/timeout "$timeout_seconds" "$provider" exec \
        --ephemeral --ignore-user-config --ignore-rules --strict-config \
        --sandbox read-only --skip-git-repo-check --color never \
        --model "$(jq -r '.adapter.model' "$request")" \
        --output-schema "$schema" --output-last-message "$candidate" \
        -c 'approval_policy="never"' -c 'web_search="disabled"' \
        -c 'features.shell_tool=false' -c 'agents.enabled=false' - < "$prompt" \
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
      case "$endpoint_class:$url" in
        customer_hosted:https://* | public_provider:https://* \
          | local:http://127.0.0.1:* | local:http://localhost:* | local:https://*) ;;
        *) record_failure endpoint_url_invalid; exit $? ;;
      esac
      curl_bin="${CURL_BIN:-curl}"
      token="${SEMANTIC_ENDPOINT_TOKEN:-}"
      unset SEMANTIC_ENDPOINT_TOKEN
      curl_args=(--fail --silent --show-error --max-time "$timeout_seconds"
        --header 'content-type: application/json' --data-binary "@$request" --output "$candidate")
      [ -z "$token" ] || curl_args+=(--header "authorization: Bearer $token")
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
      install -m 600 "$source" "$candidate" \
        || { record_failure human_submission_unreadable; exit $?; }
      ;;
    *)
      record_failure adapter_unknown
      exit $?
      ;;
  esac
fi

if [ "$kind" = human ]; then
  "$ADOC_BIN" semantic-executor --request "$request" --assessment "$candidate" \
    --receipt "$receipt" --validated-assessment "$validated" \
    "${trusted_human_args[@]}" >/dev/null
else
  "$ADOC_BIN" semantic-executor --request "$request" --assessment "$candidate" \
    --receipt "$receipt" --validated-assessment "$validated" >/dev/null
fi
exit $?
