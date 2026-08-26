#!/usr/bin/env bash
set -euo pipefail

manifest="${GITHUB_ACTION_PATH:?}/connector-capabilities.json"
jq -e '
  .schema_version == "agentdoc.connector_capabilities.v0"
  and .adapter.name == "github-action"
  and .adapter.version == "2.0.0-alpha.20"
  and .publisher == {id:"agentdoc-dev/action",kind:"agentdoc"}
  and (.capabilities | type == "object" and length > 0)
' "$manifest" >/dev/null

printf 'path=%s\n' "$manifest" >> "${GITHUB_OUTPUT:?}"
printf 'sha256=sha256:%s\n' "$(sha256sum "$manifest" | awk '{print $1}')" \
  >> "$GITHUB_OUTPUT"
