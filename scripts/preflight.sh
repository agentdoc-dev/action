#!/usr/bin/env bash
set -euo pipefail

random="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
job="$(printf '%s' "${GITHUB_JOB:-local}" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-64)"
[ -n "$job" ] || job=local
invocation_id="inv_${GITHUB_RUN_ID:-local}_${GITHUB_RUN_ATTEMPT:-1}_${job}_${random}"
run_dir="${RUNNER_TEMP:?}/agentdoc-private-${invocation_id}"
retained_dir="$RUNNER_TEMP/agentdoc-retained-${invocation_id}"
mkdir -m 700 "$run_dir" "$retained_dir"

export ADOC_RUN_DIR="$run_dir"
printf '%s\n' '{"preflight":"pending","install":"pending","assessment":"pending","semantic_review":"pending","proposal":"pending","delivery":"pending","finalize":"pending"}' \
  > "$ADOC_RUN_DIR/stages.json"
source "$(cd "$(dirname "$0")" && pwd)/state.sh"

ready=true
invalid() {
  adoc_fail preflight action.invalid_input "$1" 'Correct the Action inputs and rerun the workflow.'
  ready=false
}
unsupported_event() {
  adoc_fail preflight action.unsupported_event "$1" 'Run AgentDoc from a supported pull_request activity.'
  ready=false
}
one_of() {
  local value="$1" name="$2"
  shift 2
  for allowed in "$@"; do [ "$value" = "$allowed" ] && return 0; done
  invalid "${name} must be one of: $*"
  return 1
}

one_of "$INPUT_ENFORCEMENT" enforcement advisory strict || :
one_of "$INPUT_SCOPE" scope full diff || :
one_of "$INPUT_REPORT_STYLE" report-style compact table detailed || :
one_of "$INPUT_COMMENT" comment true false || :
one_of "${INPUT_SEMANTIC_REVIEW:-false}" semantic-review true false || :
one_of "$INPUT_PROPOSE" propose true false || :
one_of "$INPUT_PROPOSE_PROVIDER" propose-provider claude-code || :
one_of "$INPUT_PROPOSE_DELIVERY" propose-delivery comment commit pr || :
one_of "$INPUT_PROPOSE_ON_ERROR" propose-on-error warn fail || :
[[ "$INPUT_PROPOSE_MAX_PATHS" =~ ^[0-9]+$ ]] \
  && [ "$INPUT_PROPOSE_MAX_PATHS" -ge 1 ] && [ "$INPUT_PROPOSE_MAX_PATHS" -le 50 ] \
  || invalid 'propose-max-paths must be an integer from 1 through 50'
[[ "$INPUT_ADOC_VERSION" =~ ^[A-Za-z0-9._@+-]{1,128}$ ]] \
  || invalid 'adoc-version contains unsupported characters or exceeds 128 bytes'
[[ "$INPUT_MODEL" =~ ^[A-Za-z0-9._@+-]{1,128}$ ]] \
  || invalid 'model contains unsupported characters or exceeds 128 bytes'
[ "$INPUT_CLAUDE_CODE_VERSION" = 2.1.215 ] \
  || invalid 'claude-code-version must be 2.1.215; upgrade the Action for another version'

base_sha='' head_sha='' comparison_base='' pr_number=''
base_repo='' head_repo='' sender='' author=''
if [ "${GITHUB_EVENT_NAME:-}" != pull_request ] || [ ! -f "${GITHUB_EVENT_PATH:-}" ]; then
  unsupported_event "${GITHUB_EVENT_NAME:-missing}; V9 supports pull_request only"
else
  event_action="$(jq -er '.action | strings' "$GITHUB_EVENT_PATH" 2>/dev/null || true)"
  case "$event_action" in
    opened | synchronize | reopened | ready_for_review) ;;
    *) unsupported_event "pull request activity ${event_action:-missing} is unsupported" ;;
  esac
  base_repo="$(jq -r '.repository.full_name // empty' "$GITHUB_EVENT_PATH")"
  head_repo="$(jq -r '.pull_request.head.repo.full_name // empty' "$GITHUB_EVENT_PATH")"
  base_sha="$(jq -r '.pull_request.base.sha // empty' "$GITHUB_EVENT_PATH")"
  head_sha="$(jq -r '.pull_request.head.sha // empty' "$GITHUB_EVENT_PATH")"
  pr_number="$(jq -r '.pull_request.number // empty' "$GITHUB_EVENT_PATH")"
  sender="$(jq -r '.sender.login // empty' "$GITHUB_EVENT_PATH")"
  author="$(jq -r '.pull_request.user.login // empty' "$GITHUB_EVENT_PATH")"
  [ -n "$base_repo" ] && [ -n "$head_repo" ] \
    || unsupported_event 'repository identity is missing from the pull request payload'
  [[ "$base_sha" =~ ^[0-9a-f]{40}$ && "$head_sha" =~ ^[0-9a-f]{40}$ ]] \
    || unsupported_event 'exact pull request base or head SHA is missing'
  [[ "$pr_number" =~ ^[0-9]+$ ]] || unsupported_event 'pull request number is missing'
fi

workdir="${GITHUB_WORKSPACE:-}"
if [ "$(printf %s "$INPUT_WORKING_DIRECTORY" | wc -c | tr -d ' ')" -gt 4096 ]; then
  invalid 'working-directory exceeds 4096 bytes'
elif [[ "$INPUT_WORKING_DIRECTORY" == '' || "$INPUT_WORKING_DIRECTORY" == /* \
  || "$INPUT_WORKING_DIRECTORY" == *\\* || "$INPUT_WORKING_DIRECTORY" == *$'\n'* \
  || "$INPUT_WORKING_DIRECTORY" == *$'\r'* || "$INPUT_WORKING_DIRECTORY" == *$'\t'* ]]; then
  invalid 'working-directory must be a safe repository-relative directory'
elif workspace="$(realpath "${GITHUB_WORKSPACE:-}" 2>/dev/null)" \
  && candidate="$(realpath "$workspace/$INPUT_WORKING_DIRECTORY" 2>/dev/null)"; then
  case "$candidate" in
    "$workspace" | "$workspace"/*) workdir="$candidate" ;;
    *) invalid 'working-directory resolves outside the GitHub workspace' ;;
  esac
else
  invalid 'working-directory does not exist'
fi

if [ "$ready" = true ]; then
  if ! git -C "$workdir" cat-file -e "${base_sha}^{commit}" 2>/dev/null \
    || ! git -C "$workdir" cat-file -e "${head_sha}^{commit}" 2>/dev/null; then
    adoc_fail snapshot action.assessment_ref_failed \
      'The exact pull request commits are unavailable in the checkout.' \
      'Use actions/checkout with fetch-depth: 0, then rerun.'
    ready=false
  else
    merge_bases="$(git -C "$workdir" merge-base --all "$base_sha" "$head_sha")"
    merge_base_count="$(printf '%s\n' "$merge_bases" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [ "$merge_base_count" -ne 1 ] || ! [[ "$merge_bases" =~ ^[0-9a-f]{40}$ ]]; then
      adoc_fail snapshot action.assessment_ref_failed \
        'AgentDoc could not establish one comparison base for the exact commits.' \
        'Fetch complete pull request history and rerun.'
      ready=false
    else
      comparison_base="$merge_bases"
    fi
  fi
fi

eligible=true
if [ "$head_repo" != "$base_repo" ] || [ "$sender" = 'dependabot[bot]' ] \
  || [ "$author" = 'dependabot[bot]' ] || [ "${GITHUB_ACTOR:-}" = 'dependabot[bot]' ]; then
  eligible=false
  echo '::notice::AgentDoc: model provider and delivery disabled for fork or Dependabot pull request'
fi

[ "$ready" = true ] && adoc_set_stage preflight complete
{
  printf 'ADOC_RUN_DIR=%s\n' "$run_dir"
  printf 'ADOC_RETAINED_DIR=%s\n' "$retained_dir"
  printf 'ADOC_WORKING_DIRECTORY=%s\n' "$workdir"
  printf 'ADOC_INVOCATION_ID=%s\n' "$invocation_id"
  printf 'ADOC_EVALUATION_DATE=%s\n' "$(date -u +%F)"
  printf 'ADOC_REQUESTED_BASE=%s\n' "$base_sha"
  printf 'ADOC_COMPARISON_BASE=%s\n' "$comparison_base"
  printf 'ADOC_HEAD=%s\n' "$head_sha"
  printf 'ADOC_PR_NUMBER=%s\n' "$pr_number"
  printf 'ADOC_PIPELINE_READY=%s\n' "$ready"
  printf 'ADOC_PROPOSE_ELIGIBLE=%s\n' "$eligible"
} >> "$GITHUB_ENV"
exit 0
