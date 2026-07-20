#!/usr/bin/env bash
# Applies the validated drafts in $RUNNER_TEMP/valid.ndjson to the tree at
# $1 — shared by the propose sandbox and the deliver step so what was
# validated is exactly what ships.
set -uo pipefail

root="$1"

while IFS= read -r draft; do
  file="$(jq -r '.file' <<< "$draft")"
  content="$(jq -r '.content' <<< "$draft")"
  action="$(jq -r '.action // "create"' <<< "$draft")"
  ko_id="$(jq -r '.ko_id' <<< "$draft")"
  target="$root/$file"
  if [ "$action" = "update" ]; then
    # ENVIRON keeps the multi-line content verbatim (awk -v mangles escapes)
    KO_CONTENT="$content" awk -v id="$ko_id" '
      $0 == "::claim " id || $0 == "::task " id { print ENVIRON["KO_CONTENT"]; skip = 1; next }
      skip { if ($0 == "::") skip = 0; next }
      { print }' "$target" > "$target.tmp" && mv "$target.tmp" "$target"
  else
    mkdir -p "$root/$(dirname "$file")"
    [ -f "$target" ] || printf '# Proposed Knowledge Objects @doc(agentdoc.proposals)\n' > "$target"
    printf '\n%s\n' "$content" >> "$target"
  fi
done < "$RUNNER_TEMP/valid.ndjson"
