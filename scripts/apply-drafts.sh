#!/usr/bin/env bash
# Applies the validated drafts in the invocation state to the tree at
# $1 — shared by the propose sandbox and the deliver step so what was
# validated is exactly what ships.
set -euo pipefail

root="$1"
OUT="${ADOC_RUN_DIR:-$RUNNER_TEMP}"
source "$(dirname "$0")/path.sh"

# Validate the private plan again against the delivery checkout before the
# first write; the branch may have moved since sandbox validation.
while IFS= read -r draft; do
  file="$(jq -er '.file | strings' <<< "$draft")"
  action="$(jq -er '.action | strings' <<< "$draft")"
  case "$action" in create | update) ;; *) exit 1 ;; esac
  adoc_require_target "$root" "$file"
  if [ "$action" = update ] && [ ! -f "$ADOC_SAFE_PATH" ]; then
    echo '::error::action.proposal_rejected: update target is no longer a regular file' >&2
    exit 1
  fi
done < "$OUT/valid.ndjson"

while IFS= read -r draft; do
  file="$(jq -r '.file' <<< "$draft")"
  content="$(jq -r '.content' <<< "$draft")"
  action="$(jq -r '.action // "create"' <<< "$draft")"
  ko_id="$(jq -r '.ko_id' <<< "$draft")"
  adoc_require_target "$root" "$file" || exit 1
  target="$ADOC_SAFE_PATH"
  if [ "$action" = "update" ]; then
    # ENVIRON keeps the multi-line content verbatim (awk -v mangles escapes)
    tmp="$(mktemp "$OUT/apply.XXXXXX")"
    KO_CONTENT="$content" awk -v id="$ko_id" '
      $0 == "::claim " id || $0 == "::task " id { print ENVIRON["KO_CONTENT"]; skip = 1; next }
      skip { if ($0 == "::") skip = 0; next }
      { print }' "$target" > "$tmp" && mv "$tmp" "$target"
  else
    mkdir -p "$(dirname "$target")"
    adoc_require_target "$root" "$file" || exit 1
    target="$ADOC_SAFE_PATH"
    [ -f "$target" ] || printf '# Proposed Knowledge Objects @doc(agentdoc.proposals)\n' > "$target"
    printf '\n%s\n' "$content" >> "$target"
  fi
done < "$OUT/valid.ndjson"
