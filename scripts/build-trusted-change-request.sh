#!/usr/bin/env bash
# Builds the secret-free hand-off data consumed by a separately authorized,
# base-controlled trusted run. Contributor files are never executed here.
set -euo pipefail
umask 077

for secret_name in CLOUD_UPLOAD_TOKEN ANTHROPIC_API_KEY \
  CLAUDE_CODE_OAUTH_TOKEN SUPABASE_SECRET_KEY ACTIONS_ID_TOKEN_REQUEST_TOKEN; do
  if [ -n "${!secret_name:-}" ]; then
    echo "::error::trusted.untrusted_secret_present: ${secret_name} is unavailable in the untrusted phase" >&2
    exit 1
  fi
done

assessment="${ADOC_ASSESSMENT_PATH:?}"
destination="${ADOC_TRUSTED_REQUEST_PATH:?}"
working="${ADOC_WORKING_DIRECTORY:?}"
base_repo="${GITHUB_REPOSITORY:?}"
head_repo="${ADOC_HEAD_REPOSITORY:?}"
base_ref="${ADOC_BASE_REF:?}"
base="${ADOC_REQUESTED_BASE:?}"
head="${ADOC_HEAD:?}"
pr="${ADOC_PR_NUMBER:?}"
untrusted_source="${ADOC_UNTRUSTED_SOURCE:-}"
[[ "$base_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ \
  && "$head_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ \
  && "$base" =~ ^[0-9a-f]{40}$ && "$head" =~ ^[0-9a-f]{40}$ \
  && "$pr" =~ ^[1-9][0-9]*$ \
  && "$untrusted_source" =~ ^(fork|dependabot)$ ]] || {
  echo '::error::trusted.request_invalid: exact repository, PR, and revision bindings are required' >&2
  exit 1
}
git check-ref-format "refs/heads/$base_ref" >/dev/null 2>&1 || {
  echo '::error::trusted.request_invalid: exact pull-request base ref is required' >&2
  exit 1
}
prefix="$(git -C "$working" rev-parse --show-prefix 2>/dev/null)" || {
  echo '::error::trusted.request_invalid: working directory is outside the repository' >&2
  exit 1
}

if ! jq -e --arg base "$base" --arg head "$head" '
  .schema_version == "adoc.change_assessment.v0"
  and .snapshots.requested_base.resolved_commit == $base
  and .snapshots.head.resolved_commit == $head
  and (.evaluation_date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
  and .paths.status == "available" and (.paths.value | type == "array")
  and all(.paths.value[];
    .path as $path
    | ($path | type) == "string" and ($path | length) > 0
    and (($path | startswith("/")) | not)
    and (($path | test("(^|/)\\.\\.(/|$)")) | not)
    and (($path | test("[\u0000-\u001f\u007f]")) | not))
' "$assessment" >/dev/null 2>&1; then
  echo '::error::trusted.request_invalid: validated exact-head assessment is required' >&2
  exit 1
fi

context="$(jq -cS --arg repository "$base_repo" --arg prefix "$prefix" '
  [.paths.value[] | {repository:$repository,path:($prefix + .path)}]
  | sort_by(.repository,.path)
  | if length == (unique_by(.repository,.path) | length) then . else error("duplicate path") end
' "$assessment")" || {
  echo '::error::trusted.request_invalid: semantic context request is not canonical' >&2
  exit 1
}
context_digest="sha256:$(printf '%s\n' "$context" | sha256sum | awk '{print $1}')"
assessment_digest="sha256:$(sha256sum "$assessment" | awk '{print $1}')"
evaluation_date="$(jq -r .evaluation_date "$assessment")"
directory="$(dirname "$destination")"
mkdir -p "$directory"
temporary="$directory/.trusted-change-request.$$"
trap 'rm -f -- "$temporary"' EXIT

jq -cnS --arg base_repo "$base_repo" --arg head_repo "$head_repo" \
  --argjson pr "$pr" --arg base_ref "$base_ref" \
  --arg base "$base" --arg head "$head" \
  --arg untrusted_source "$untrusted_source" \
  --arg date "$evaluation_date" --arg assessment "$assessment_digest" \
  --argjson context "$context" --arg context_digest "$context_digest" '{
    version:1,base_repository:$base_repo,head_repository:$head_repo,
    untrusted_source:$untrusted_source,
    pull_request:$pr,base_ref:$base_ref,
    base_revision:$base,head_revision:$head,
    evaluation_date:$date,assessment_digest:$assessment,
    context_request:$context,context_request_digest:$context_digest
  }' > "$temporary"
request_digest="sha256:$(sha256sum "$temporary" | awk '{print $1}')"
jq -S --arg digest "$request_digest" '. + {request_digest:$digest}' \
  "$temporary" > "$destination"
if [ -n "${ADOC_TRUSTED_STATUS_PATH:-}" ]; then
  jq '{
    state:"awaiting_authorization",reason_code:null,remediation:null,
    head_revision:.head_revision,request_digest:.request_digest,
    authorizer:null,policy:null,workload:null,executor:null,
    context_request_digest:.context_request_digest,
    context_digest:null,result_digest:null,workflow:null
  }' "$destination" > "$ADOC_TRUSTED_STATUS_PATH"
fi
rm -f -- "$temporary"
trap - EXIT
