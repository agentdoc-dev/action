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
printf '%s\n' '{"preflight":"pending","install":"pending","assessment":"pending","baseline":"pending","semantic_review":"pending","proposal":"pending","delivery":"pending","cloud_sync":"pending","finalize":"pending"}' \
  > "$ADOC_RUN_DIR/stages.json"
source "$(cd "$(dirname "$0")" && pwd)/state.sh"

ready=true
invalid() {
  adoc_fail preflight action.invalid_input "$1" 'Correct the Action inputs and rerun the workflow.'
  ready=false
}
unsupported_event() {
  adoc_fail preflight action.unsupported_event "$1" 'Run AgentDoc from a supported pull_request activity or default-branch bootstrap.'
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
one_of "${INPUT_SYNC_POLICY:-advisory}" sync-policy advisory required || :
one_of "${INPUT_BOOTSTRAP:-false}" bootstrap true false || :
one_of "$INPUT_COMMENT" comment true false || :
if [ "${INPUT_COMMENT_MAX_COMMENTS:-5}" != unlimited ]; then
  [[ "${INPUT_COMMENT_MAX_COMMENTS:-5}" =~ ^[1-9][0-9]*$ ]] \
    || invalid 'comment-max-comments must be a positive integer or unlimited'
fi
one_of "${INPUT_SEMANTIC_REVIEW:-false}" semantic-review true false || :
one_of "$INPUT_PROPOSE" propose true false || :
one_of "$INPUT_PROPOSE_PROVIDER" propose-provider claude-code || :
one_of "$INPUT_PROPOSE_DELIVERY" propose-delivery comment commit pr || :
one_of "$INPUT_PROPOSE_ON_ERROR" propose-on-error warn fail || :
one_of "${INPUT_PROPOSE_COVERAGE:-bounded}" propose-coverage bounded full || :
one_of "${INPUT_PROPOSE_AUTHORITY:-downgrade}" propose-authority downgrade preserve suggest || :
one_of "${INPUT_PROPOSE_CONTRADICTIONS:-suggest}" propose-contradictions suggest propose || :
one_of "${INPUT_PROPOSE_DELIVERY_POLICY:-atomic}" propose-delivery-policy atomic partial || :
if [ "${INPUT_SYNC_POLICY:-advisory}" = required ] || [ "${INPUT_BOOTSTRAP:-false}" = true ]; then
  [ "$INPUT_PROPOSE" = true ] \
    || invalid 'required sync and bootstrap require propose: true'
  [ "$INPUT_PROPOSE_DELIVERY" = pr ] \
    || invalid 'required sync and bootstrap require propose-delivery: pr'
  [ "$INPUT_PROPOSE_ON_ERROR" = fail ] \
    || invalid 'required sync and bootstrap require propose-on-error: fail'
  [ "${INPUT_PROPOSE_COVERAGE:-bounded}" = full ] \
    || invalid 'required sync and bootstrap require propose-coverage: full'
fi
[[ "$INPUT_PROPOSE_MAX_PATHS" =~ ^[0-9]+$ ]] \
  && [ "$INPUT_PROPOSE_MAX_PATHS" -ge 1 ] && [ "$INPUT_PROPOSE_MAX_PATHS" -le 50 ] \
  || invalid 'propose-max-paths must be an integer from 1 through 50'
[[ "${INPUT_PROVIDER_TIMEOUT_SECONDS:-}" =~ ^[0-9]+$ ]] \
  && [ "$INPUT_PROVIDER_TIMEOUT_SECONDS" -ge 60 ] \
  && [ "$INPUT_PROVIDER_TIMEOUT_SECONDS" -le 3600 ] \
  || invalid 'provider-timeout-seconds must be an integer from 60 through 3600'
[[ "$INPUT_ADOC_VERSION" =~ ^[A-Za-z0-9._@+-]{1,128}$ ]] \
  || invalid 'adoc-version contains unsupported characters or exceeds 128 bytes'
[[ "$INPUT_MODEL" =~ ^[A-Za-z0-9._@+-]{1,128}$ ]] \
  || invalid 'model contains unsupported characters or exceeds 128 bytes'
[ "$INPUT_CLAUDE_CODE_VERSION" = 2.1.215 ] \
  || invalid 'claude-code-version must be 2.1.215; upgrade the Action for another version'
cloud_inputs=0
for value in "${INPUT_CLOUD_WORK_REQUEST:-}" "${INPUT_CLOUD_UPLOAD_URL:-}" \
  "${INPUT_CLOUD_UPLOAD_TOKEN:-}"; do
  [ -z "$value" ] || cloud_inputs=$((cloud_inputs + 1))
done
[ "$cloud_inputs" -eq 0 ] || [ "$cloud_inputs" -eq 3 ] \
  || invalid 'cloud-work-request, cloud-upload-url, and cloud-upload-token must be configured together'
assessment_inputs=0
for value in "${INPUT_CLOUD_ASSESSMENT_URL:-}" \
  "${INPUT_CLOUD_ASSESSMENT_REPOSITORY_ID:-}" \
  "${INPUT_CLOUD_ASSESSMENT_TOKEN:-}"; do
  [ -z "$value" ] || assessment_inputs=$((assessment_inputs + 1))
done
[ "$assessment_inputs" -eq 0 ] || [ "$assessment_inputs" -eq 3 ] \
  || invalid 'cloud-assessment-url, cloud-assessment-repository-id, and cloud-assessment-token must be configured together'
trusted_inputs=0
for value in "${INPUT_TRUSTED_CHANGE_REQUEST:-}" \
  "${INPUT_TRUSTED_CHANGE_AUTHORIZATION:-}"; do
  [ -z "$value" ] || trusted_inputs=$((trusted_inputs + 1))
done
[ "$trusted_inputs" -eq 0 ] || [ "$trusted_inputs" -eq 2 ] \
  || invalid 'trusted-change-request and trusted-change-authorization must be configured together'
[ "$trusted_inputs" -eq 0 ] || [ "${INPUT_BOOTSTRAP:-false}" = false ] \
  || invalid 'trusted change processing and bootstrap are mutually exclusive'

base_sha='' head_sha='' comparison_base='' pr_number='' head_ref='' default_branch=''
base_repo='' head_repo='' sender='' author=''
trusted_phase=false
evaluation_date="$(date -u +%F)"
if [ "$trusted_inputs" -eq 2 ]; then
  trusted_phase=true
  base_repo="$(jq -r '.base_repository // empty' "$INPUT_TRUSTED_CHANGE_REQUEST" 2>/dev/null || true)"
  head_repo="$(jq -r '.head_repository // empty' "$INPUT_TRUSTED_CHANGE_REQUEST" 2>/dev/null || true)"
  base_sha="$(jq -r '.base_revision // empty' "$INPUT_TRUSTED_CHANGE_REQUEST" 2>/dev/null || true)"
  head_sha="$(jq -r '.head_revision // empty' "$INPUT_TRUSTED_CHANGE_REQUEST" 2>/dev/null || true)"
  pr_number="$(jq -r '.pull_request // empty' "$INPUT_TRUSTED_CHANGE_REQUEST" 2>/dev/null || true)"
  evaluation_date="$(jq -r '.evaluation_date // empty' "$INPUT_TRUSTED_CHANGE_REQUEST" 2>/dev/null || true)"
  prepared="$run_dir/trusted-prepared.env"
  set +e
  TRUSTED_CHANGE_REQUEST="$INPUT_TRUSTED_CHANGE_REQUEST" \
    TRUSTED_CHANGE_AUTHORIZATION="$INPUT_TRUSTED_CHANGE_AUTHORIZATION" \
    TRUSTED_PREPARED_ENV="$prepared" \
    TRUSTED_PHASE_STATUS_PATH="$run_dir/trusted-phase-status.json" \
    "$(cd "$(dirname "$0")" && pwd)/prepare-trusted-change.sh"
  trusted_code=$?
  set -e
  if [ "$trusted_code" -eq 0 ]; then
    base_repo="$(sed -n 's/^TRUSTED_BASE_REPOSITORY=//p' "$prepared")"
    head_repo="$(sed -n 's/^TRUSTED_HEAD_REPOSITORY=//p' "$prepared")"
    pr_number="$(sed -n 's/^TRUSTED_PULL_REQUEST=//p' "$prepared")"
    base_sha="$(sed -n 's/^TRUSTED_BASE_REVISION=//p' "$prepared")"
    head_sha="$(sed -n 's/^TRUSTED_HEAD_REVISION=//p' "$prepared")"
    head_ref="$(sed -n 's/^TRUSTED_HEAD_REF=//p' "$prepared")"
    evaluation_date="$(sed -n 's/^TRUSTED_EVALUATION_DATE=//p' "$prepared")"
  else
    adoc_fail preflight action.invalid_input \
      'Trusted change authorization or exact-head preparation failed.' \
      'Inspect the trusted-phase status, then authorize and run the current head.'
    ready=false
  fi
elif [ "${INPUT_BOOTSTRAP:-false}" = true ] && [ "${GITHUB_EVENT_NAME:-}" = workflow_dispatch ]; then
  [ -f "${GITHUB_EVENT_PATH:-}" ] \
    || unsupported_event 'bootstrap requires a workflow_dispatch event payload'
  base_repo="${GITHUB_REPOSITORY:-}"
  head_repo="$base_repo"
  sender="${GITHUB_ACTOR:-}"
  author="$sender"
  default_branch="$(jq -r '.repository.default_branch // empty' "$GITHUB_EVENT_PATH" 2>/dev/null || true)"
  git check-ref-format --branch "$default_branch" >/dev/null 2>&1 \
    || unsupported_event 'bootstrap repository default branch is missing or invalid'
  head_ref="$default_branch"
elif [ "${GITHUB_EVENT_NAME:-}" != pull_request ] || [ ! -f "${GITHUB_EVENT_PATH:-}" ]; then
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
  head_ref="$(jq -r '.pull_request.head.ref // empty' "$GITHUB_EVENT_PATH")"
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

if [ "${INPUT_BOOTSTRAP:-false}" = true ] && [ "$ready" = true ]; then
  head_sha="$(git -C "$workdir" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)"
  default_head="$(git -C "$workdir" rev-parse --verify \
    "refs/remotes/origin/${default_branch}^{commit}" 2>/dev/null || true)"
  base_sha="$head_sha"
  comparison_base="$head_sha"
  [[ "$base_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ \
    && "$head_sha" =~ ^[0-9a-f]{40}$ && "$head_sha" = "$default_head" ]] \
    || unsupported_event 'bootstrap requires a checked-out repository default branch'
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
untrusted=false
untrusted_source=none
if [ "$trusted_phase" = true ]; then
  untrusted=true
  untrusted_source="$(jq -r .untrusted_source "$INPUT_TRUSTED_CHANGE_REQUEST")"
elif [ "$head_repo" != "$base_repo" ] || [ "$sender" = 'dependabot[bot]' ] \
  || [ "$author" = 'dependabot[bot]' ] || [ "${GITHUB_ACTOR:-}" = 'dependabot[bot]' ]; then
  eligible=false
  untrusted=true
  if [ "$sender" = 'dependabot[bot]' ] || [ "$author" = 'dependabot[bot]' ] \
    || [ "${GITHUB_ACTOR:-}" = 'dependabot[bot]' ]; then
    untrusted_source=dependabot
  else
    untrusted_source=fork
  fi
  echo '::notice::AgentDoc: model provider and delivery disabled for fork or Dependabot pull request'
fi

[ "$ready" = true ] && adoc_set_stage preflight complete
{
  printf 'ADOC_RUN_DIR=%s\n' "$run_dir"
  printf 'ADOC_RETAINED_DIR=%s\n' "$retained_dir"
  printf 'ADOC_WORKING_DIRECTORY=%s\n' "$workdir"
  printf 'ADOC_INVOCATION_ID=%s\n' "$invocation_id"
  printf 'ADOC_EVALUATION_DATE=%s\n' "$evaluation_date"
  printf 'ADOC_REQUESTED_BASE=%s\n' "$base_sha"
  printf 'ADOC_COMPARISON_BASE=%s\n' "$comparison_base"
  if [ "${INPUT_BOOTSTRAP:-false}" = true ]; then
    printf 'ADOC_DIFF_BASE=4b825dc642cb6eb9a060e54bf8d69288fbee4904\n'
  else
    printf 'ADOC_DIFF_BASE=%s\n' "$comparison_base"
  fi
  printf 'ADOC_HEAD=%s\n' "$head_sha"
  printf 'ADOC_PR_NUMBER=%s\n' "$pr_number"
  printf 'ADOC_HEAD_REF=%s\n' "$head_ref"
  printf 'ADOC_HEAD_REPOSITORY=%s\n' "$head_repo"
  printf 'ADOC_PIPELINE_READY=%s\n' "$ready"
  printf 'ADOC_PROPOSE_ELIGIBLE=%s\n' "$eligible"
  printf 'ADOC_UNTRUSTED_CHANGE=%s\n' "$untrusted"
  printf 'ADOC_UNTRUSTED_SOURCE=%s\n' "$untrusted_source"
  printf 'ADOC_TRUSTED_PHASE=%s\n' "$trusted_phase"
  printf 'ADOC_BOOTSTRAP=%s\n' "${INPUT_BOOTSTRAP:-false}"
} >> "$GITHUB_ENV"
exit 0
