#!/usr/bin/env bash
set -euo pipefail

invalid() {
  echo "::error::action.invalid_input: $1" >&2
  exit 1
}

unsupported_event() {
  echo "::error::action.unsupported_event: $1" >&2
  exit 1
}

one_of() { # value, input name, allowed values...
  local value="$1" name="$2"
  shift 2
  for allowed in "$@"; do
    [ "$value" = "$allowed" ] && return
  done
  invalid "${name} must be one of: $*"
}

one_of "$INPUT_ENFORCEMENT" enforcement advisory strict
one_of "$INPUT_SCOPE" scope full diff
one_of "$INPUT_REPORT_STYLE" report-style compact table detailed
one_of "$INPUT_COMMENT" comment true false
one_of "$INPUT_PROPOSE" propose true false
one_of "$INPUT_PROPOSE_PROVIDER" propose-provider claude-code
one_of "$INPUT_PROPOSE_DELIVERY" propose-delivery comment commit pr
one_of "$INPUT_PROPOSE_ON_ERROR" propose-on-error warn fail

[[ "$INPUT_PROPOSE_MAX_PATHS" =~ ^[0-9]+$ ]] \
  && [ "$INPUT_PROPOSE_MAX_PATHS" -ge 1 ] \
  && [ "$INPUT_PROPOSE_MAX_PATHS" -le 50 ] \
  || invalid 'propose-max-paths must be an integer from 1 through 50'
[[ "$INPUT_ADOC_VERSION" =~ ^[A-Za-z0-9._@+-]{1,128}$ ]] \
  || invalid 'adoc-version contains unsupported characters or exceeds 128 bytes'
[[ "$INPUT_MODEL" =~ ^[A-Za-z0-9._@+-]{1,128}$ ]] \
  || invalid 'model contains unsupported characters or exceeds 128 bytes'
[ "$INPUT_CLAUDE_CODE_VERSION" = 2.1.215 ] \
  || invalid 'claude-code-version must be 2.1.215; upgrade the Action to use another pinned version'

[ "$GITHUB_EVENT_NAME" = pull_request ] \
  || unsupported_event "${GITHUB_EVENT_NAME:-missing}; V9 supports pull_request only"
[ -f "$GITHUB_EVENT_PATH" ] || unsupported_event 'pull request payload is missing'
event_action="$(jq -er '.action | strings' "$GITHUB_EVENT_PATH" 2> /dev/null)" \
  || unsupported_event 'pull request activity is missing'
case "$event_action" in
  opened | synchronize | reopened | ready_for_review) ;;
  *) unsupported_event "pull request activity ${event_action} is unsupported" ;;
esac
jq -e '.repository.full_name | strings | length > 0' "$GITHUB_EVENT_PATH" > /dev/null 2>&1 \
  || unsupported_event 'repository identity is missing from the pull request payload'
jq -e '.pull_request.head.repo.full_name | strings | length > 0' "$GITHUB_EVENT_PATH" > /dev/null 2>&1 \
  || unsupported_event 'head repository identity is missing from the pull request payload'

[ "$(printf %s "$INPUT_WORKING_DIRECTORY" | wc -c | tr -d ' ')" -le 4096 ] \
  || invalid 'working-directory exceeds 4096 bytes'
case "$INPUT_WORKING_DIRECTORY" in
  '' | /* | *\\* | *$'\n'* | *$'\r'* | *$'\t'*) invalid 'working-directory must be a safe repository-relative directory' ;;
esac
workspace="$(realpath "$GITHUB_WORKSPACE")" \
  || invalid 'GitHub workspace cannot be resolved'
workdir="$(realpath "$workspace/$INPUT_WORKING_DIRECTORY")" \
  || invalid 'working-directory does not exist'
case "$workdir" in
  "$workspace" | "$workspace"/*) ;;
  *) invalid 'working-directory resolves outside the GitHub workspace' ;;
esac

run_dir="$(mktemp -d "$RUNNER_TEMP/agentdoc.XXXXXX")"
chmod 700 "$run_dir"
eligible=true
head_repo="$(jq -r '.pull_request.head.repo.full_name' "$GITHUB_EVENT_PATH")"
base_repo="$(jq -r '.repository.full_name' "$GITHUB_EVENT_PATH")"
sender="$(jq -r '.sender.login // ""' "$GITHUB_EVENT_PATH")"
author="$(jq -r '.pull_request.user.login // ""' "$GITHUB_EVENT_PATH")"
if [ "$head_repo" != "$base_repo" ] \
  || [ "$sender" = 'dependabot[bot]' ] || [ "$author" = 'dependabot[bot]' ] \
  || [ "${GITHUB_ACTOR:-}" = 'dependabot[bot]' ]; then
  eligible=false
  echo '::notice::AgentDoc: proposal provider and delivery disabled for fork or Dependabot pull request'
fi

{
  printf 'ADOC_RUN_DIR=%s\n' "$run_dir"
  printf 'ADOC_WORKING_DIRECTORY=%s\n' "$workdir"
  printf 'ADOC_PROPOSE_ELIGIBLE=%s\n' "$eligible"
} >> "$GITHUB_ENV"
