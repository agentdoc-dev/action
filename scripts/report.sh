#!/usr/bin/env bash
# Runs Strict Mode validation and the Impacted Query, records the gate exit
# code, and leaves the artifacts compose.sh assembles into the report. Never
# fails the job itself — enforcement is a separate, final action step so the
# comment always posts.
set -uo pipefail

OUT="$RUNNER_TEMP"
BASE_REF="${GITHUB_BASE_REF:-}"

# --- Strict Mode validation -------------------------------------------------
# stdout: PR-comment body; stderr: file:line:col diagnostics (problem matcher)
adoc check --format markdown --style "${REPORT_STYLE:-compact}" \
  > "$OUT/check.md" 2> "$OUT/check.diag"
check_code=$?
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
echo '_Impacted Query unavailable — see the job log for diagnostics (requires `fetch-depth: 0`, a pull request base, and a built Graph Artifact)._' > "$OUT/impacted.md"
: > "$OUT/impacted.json"
: > "$OUT/review.json"
: > "$OUT/uncovered-paths"
if [ -n "$BASE_REF" ] && git rev-parse --verify -q "origin/${BASE_REF}" > /dev/null; then
  if adoc impacted-by --ref "origin/${BASE_REF}" --format markdown > "$OUT/impacted.md.tmp" 2> "$OUT/impacted.diag"; then
    mv "$OUT/impacted.md.tmp" "$OUT/impacted.md"
    adoc impacted-by --ref "origin/${BASE_REF}" --format json > "$OUT/impacted.json" 2> /dev/null \
      || : > "$OUT/impacted.json"
    jq -r '
        ((.changed_paths // []) - ([.impacted[]?.reasons[]?.matched_path] | unique))
        | map(select((endswith(".adoc") or endswith("agentdoc.config.yaml")) | not))[]' \
      "$OUT/impacted.json" > "$OUT/uncovered-paths" || : > "$OUT/uncovered-paths"
    # Diff-changed KO ids let compose.sh badge impacted objects the PR did or
    # did not touch. Fail-open: no review envelope, no badges.
    adoc review "origin/${BASE_REF}" --format json > "$OUT/review.json" 2>> "$OUT/impacted.diag" \
      || : > "$OUT/review.json"
  fi
  cat "$OUT/impacted.diag" >&2
fi

# --- Contradictions ----------------------------------------------------------
# Read-time signal over the Graph Artifact; report-only — never feeds the
# gate. Empty output (none authored, missing artifact) omits the section.
: > "$OUT/contradictions.md"
if adoc contradictions --format json > "$OUT/contradictions.json"; then
  jq -r '
    .contradictions | select(length > 0)
    | "**\(length) unresolved contradiction(s)** in the knowledge base:\n",
      (.[] | "- `\(.id)` — \(.severity)"
        + (if .owner then ", owner: \(.owner)" else "" end)
        + " — claims: " + (.claims | map("`\(.)`") | join(", "))
        + (if .summary == "" then "" else "\n  \(.summary)" end))
  ' "$OUT/contradictions.json" > "$OUT/contradictions.md" \
    || : > "$OUT/contradictions.md"
fi
exit 0
