#!/usr/bin/env bash
# Runs Strict Mode validation and the Impacted Query, records the gate exit
# code, and leaves the artifacts compose.sh assembles into the report. Never
# fails the job itself — enforcement is a separate, final action step so the
# comment always posts.
set -uo pipefail

OUT="$RUNNER_TEMP"
BASE_REF="${GITHUB_BASE_REF:-}"

write_impact_status() {
  local status="$1" stage="${2:-}" reason="${3:-}" code="${4:-null}"
  jq -cn --arg status "$status" --arg stage "$stage" --arg reason "$reason" \
    --argjson exit_code "$code" \
    '{status: $status}
     + (if $stage == "" then {} else {stage: $stage, reason: $reason, exit_code: $exit_code} end)' \
    > "$OUT/adoc-impact-status.json.tmp"
  mv "$OUT/adoc-impact-status.json.tmp" "$OUT/adoc-impact-status.json"
}

impact_failure() {
  local status="$1" stage="$2" reason="$3" code="$4" message="$5"
  write_impact_status "$status" "$stage" "$reason" "$code"
  echo "AgentDoc impact analysis [$stage] failed (exit $code): $message" >&2
}

# Fail closed if the script is interrupted before assessment completes.
write_impact_status error status-read incomplete null

# --- Strict Mode validation -------------------------------------------------
# stdout: PR-comment body; stderr: file:line:col diagnostics (problem matcher)
adoc check --format markdown --style "${REPORT_STYLE:-compact}" \
  > "$OUT/check.md" 2> "$OUT/check.diag"
check_code=$?
echo "$check_code" > "$OUT/adoc-check-code"
cat "$OUT/check.diag" >&2

# --- Gate -------------------------------------------------------------------
# Fail-closed: the gate only relaxes below check's own exit code when every
# step of the diff-attribution proves the errors live outside this PR.
# check exit >= 2 is an environment/tool failure, never a scoping question.
gate_code=$check_code
if [ "${SCOPE:-full}" = "diff" ] && [ "$check_code" -eq 1 ] && [ -n "$BASE_REF" ] \
  && git rev-parse --verify -q "origin/${BASE_REF}" > /dev/null; then
  # Diagnostic paths are relative to the working directory (adoc v0.1.1);
  # `git diff --name-only` is repo-root-relative. Re-root the diagnostics
  # with this directory's repo prefix so both sides compare exactly.
  git_prefix="$(git rev-parse --show-prefix)"
  sed -nE 's/^(.+):[0-9]+:[0-9]+: error\[.*$/\1/p' "$OUT/check.diag" \
    | sed "s|^|${git_prefix}|" | sort -u > "$OUT/error-paths"
  if [ -s "$OUT/error-paths" ] \
    && git diff --name-only "origin/${BASE_REF}...HEAD" > "$OUT/changed-paths" \
    && ! grep -Fxf "$OUT/changed-paths" "$OUT/error-paths" -q; then
    gate_code=0
  fi
  # Spanless errors, absolute fallback paths, a failed git diff, or
  # path-normalization misses keep the gate at check's exit code — never
  # silently open it.
fi
echo "$gate_code" > "$OUT/adoc-gate-code"

# --- Impacted Query + uncovered paths ---------------------------------------
# uncovered-paths: changed source paths no Knowledge Object claims impact
# over — input to the propose step, rendered by compose.sh either way.
: > "$OUT/impacted.json"
: > "$OUT/review.json"
: > "$OUT/uncovered-paths"
assess_impact() {
  local impact_code build_code reason status
  if [ -z "$BASE_REF" ]; then
    impact_failure unavailable base-ref missing-base null \
      'pull request base is missing; run on pull_request with fetch-depth: 0'
    return
  fi
  if ! git rev-parse --verify -q "origin/${BASE_REF}" > /dev/null; then
    impact_failure unavailable base-ref unresolvable-base null \
      'base ref cannot be resolved; checkout the full history with fetch-depth: 0'
    return
  fi

  if adoc impacted-by --ref "origin/${BASE_REF}" --format json \
    > "$OUT/impacted.json.tmp" 2> "$OUT/impacted.diag"; then
    impact_code=0
  else
    impact_code=$?
  fi
  cat "$OUT/impacted.diag" >&2
  if ! jq -e '
      .schema_version == "adoc.impacted.v0"
      and (.changed_paths | type == "array")
      and (.impacted | type == "array")
      and (.proof_obligations | type == "array")
      and (.diagnostics | type == "array")' "$OUT/impacted.json.tmp" > /dev/null 2>&1; then
    impact_failure error impacted-json-parse malformed-output "$impact_code" \
      'adoc impacted-by did not return a valid adoc.impacted.v0 envelope'
    return
  fi
  if [ "$impact_code" -ne 0 ]; then
    build_code="$(cat "$OUT/adoc-build-code" 2>/dev/null || echo invalid)"
    reason=command-failed
    if [ "$build_code" = 1 ] && [ "$check_code" = 1 ] \
      && jq -e '.diagnostics | length > 0 and all(.[]; .code == "io.artifact_missing")' \
        "$OUT/impacted.json.tmp" > /dev/null; then
      reason=head-invalid
    fi
    jq -r '.diagnostics[]? | "\(.severity)[\(.code)] \(.message)"' \
      "$OUT/impacted.json.tmp" >&2
    impact_failure unavailable impacted-json "$reason" "$impact_code" \
      'adoc impacted-by could not establish impact; inspect its diagnostics'
    return
  fi
  if ! jq -e 'all(.diagnostics[]?; .severity != "error")' \
    "$OUT/impacted.json.tmp" > /dev/null; then
    impact_failure error impacted-json invalid-envelope 0 \
      'a successful impacted envelope contained error diagnostics'
    return
  fi

  if ! jq -r '
      ((.changed_paths // []) - ([.impacted[]?.reasons[]?.matched_path] | unique))
      | map(select((endswith(".adoc") or endswith("agentdoc.config.yaml")) | not))[]' \
      "$OUT/impacted.json.tmp" > "$OUT/uncovered-paths.tmp"; then
    impact_failure error uncovered-derivation derivation-failed 0 \
      'could not derive uncovered paths from the impacted envelope'
    return
  fi
  if ! adoc impacted-by --ref "origin/${BASE_REF}" --format markdown \
    > "$OUT/impacted.md.tmp" 2> "$OUT/impacted-markdown.diag"; then
    impact_code=$?
    cat "$OUT/impacted-markdown.diag" >&2
    impact_failure error impacted-markdown command-failed "$impact_code" \
      'could not render the validated impact result'
    return
  fi
  cat "$OUT/impacted-markdown.diag" >&2
  mv "$OUT/impacted.json.tmp" "$OUT/impacted.json"
  mv "$OUT/uncovered-paths.tmp" "$OUT/uncovered-paths"
  mv "$OUT/impacted.md.tmp" "$OUT/impacted.md"

  if jq -e '
      [.changed_paths[] | select((endswith(".adoc") or endswith("agentdoc.config.yaml")) | not)]
      | length == 0' "$OUT/impacted.json" > /dev/null; then
    status=no_changes
  else
    status=complete
  fi
  write_impact_status "$status"

  # Diff-changed KO ids let compose.sh badge impacted objects the PR did or
  # did not touch. Fail-open: no review envelope, no badges.
  if ! adoc review "origin/${BASE_REF}" --format json \
    > "$OUT/review.json" 2> "$OUT/review.diag"; then
    echo 'AgentDoc optional review stage failed; drift badges are unavailable' >&2
    cat "$OUT/review.diag" >&2
    : > "$OUT/review.json"
  fi
}
assess_impact

# --- Contradictions ----------------------------------------------------------
# Read-time signal over the Graph Artifact; report-only — never feeds the
# gate. Empty output (none authored, missing artifact) omits the section.
: > "$OUT/contradictions.md"
if adoc contradictions --format json \
  > "$OUT/contradictions.json" 2> "$OUT/contradictions.diag"; then
  if ! jq -r '
    .contradictions | select(length > 0)
    | "**\(length) unresolved contradiction(s)** in the knowledge base:\n",
      (.[] | "- `\(.id)` — \(.severity)"
        + (if .owner then ", owner: \(.owner)" else "" end)
        + " — claims: " + (.claims | map("`\(.)`") | join(", "))
        + (if .summary == "" then "" else "\n  \(.summary)" end))
  ' "$OUT/contradictions.json" > "$OUT/contradictions.md"; then
    echo 'AgentDoc optional contradictions parse failed; section omitted' >&2
    : > "$OUT/contradictions.md"
  fi
else
  echo 'AgentDoc optional contradictions stage failed; section omitted' >&2
  cat "$OUT/contradictions.diag" >&2
fi
exit 0
