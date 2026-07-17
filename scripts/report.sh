#!/usr/bin/env bash
# Runs Strict Mode validation and the Impacted Query, composes the PR report
# body, and records the gate exit code. Never fails the job itself —
# enforcement is a separate, final action step so the comment always posts.
set -uo pipefail

OUT="$RUNNER_TEMP"
BASE_REF="${GITHUB_BASE_REF:-}"

# --- Strict Mode validation -------------------------------------------------
# stdout: PR-comment body; stderr: file:line:col diagnostics (problem matcher)
adoc check --format markdown > "$OUT/check.md" 2> "$OUT/check.diag"
check_code=$?
cat "$OUT/check.diag" >&2

# --- Gate -------------------------------------------------------------------
# Fail-closed: the gate only relaxes below check's own exit code when every
# step of the diff-attribution proves the errors live outside this PR.
# check exit >= 2 is an environment/tool failure, never a scoping question.
gate_code=$check_code
if [ "${SCOPE:-full}" = "diff" ] && [ "$check_code" -eq 1 ] && [ -n "$BASE_REF" ] \
  && git rev-parse --verify -q "origin/${BASE_REF}" > /dev/null; then
  git_root="$(git rev-parse --show-toplevel)"
  # Diagnostic paths are absolute; normalize both sides to absolute paths.
  sed -nE 's/^(.+):[0-9]+:[0-9]+: error\[.*$/\1/p' "$OUT/check.diag" \
    | sed 's|/\./|/|g' | sort -u > "$OUT/error-paths"
  if [ -s "$OUT/error-paths" ] \
    && git diff --name-only "origin/${BASE_REF}...HEAD" \
      | sed "s|^|${git_root}/|" > "$OUT/changed-paths" \
    && ! grep -Fxf "$OUT/changed-paths" "$OUT/error-paths" -q; then
    gate_code=0
  fi
  # Spanless errors, a failed git diff, or path-normalization misses keep
  # the gate at check's exit code — never silently open it.
fi
echo "$gate_code" > "$OUT/adoc-gate-code"

# --- Impacted Query + Proposed Knowledge Objects ----------------------------
echo '_Impacted Query unavailable — see the job log for diagnostics (requires `fetch-depth: 0`, a pull request base, and a built Graph Artifact)._' > "$OUT/impacted.md"
: > "$OUT/proposed.md"
if [ -n "$BASE_REF" ] && git rev-parse --verify -q "origin/${BASE_REF}" > /dev/null; then
  if adoc impacted-by --ref "origin/${BASE_REF}" --format markdown > "$OUT/impacted.md.tmp" 2> "$OUT/impacted.diag"; then
    mv "$OUT/impacted.md.tmp" "$OUT/impacted.md"
    adoc impacted-by --ref "origin/${BASE_REF}" --format json 2> /dev/null \
      | jq -r '
          ((.changed_paths // []) - ([.impacted[]?.reasons[]?.matched_path] | unique))
          | map(select((endswith(".adoc") or endswith("agentdoc.config.yaml")) | not))[]
          | "- `\(.)`"' > "$OUT/proposed.md" || : > "$OUT/proposed.md"
  fi
  cat "$OUT/impacted.diag" >&2
fi

# --- Compose the PR report --------------------------------------------------
{
  echo '<!-- adoc:pr-report -->'
  echo '## AgentDoc PR Report'
  echo
  echo '### Validation'
  echo
  cat "$OUT/check.md"
  echo
  echo '### Impacted Knowledge'
  echo
  cat "$OUT/impacted.md"
  echo
  echo '### Proposed Knowledge Objects'
  echo
  if [ -s "$OUT/proposed.md" ]; then
    echo 'This PR touches source paths no Knowledge Object claims impact over:'
    echo
    cat "$OUT/proposed.md"
    echo
    echo 'Consider authoring a Knowledge Object with an `impacts:` field for each.'
  else
    echo '_None — all changed paths are covered._'
  fi
  echo
  echo "<sub>adoc ${ADOC_VERSION:-?} · enforcement: ${ENFORCEMENT:-advisory} · scope: ${SCOPE:-full}</sub>"
} > "$OUT/report.md"

cat "$OUT/report.md" >> "$GITHUB_STEP_SUMMARY"
exit 0
