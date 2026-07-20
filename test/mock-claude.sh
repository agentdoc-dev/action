#!/usr/bin/env bash
# CI stand-in for `claude -p --output-format json`: records the prompt (for
# assertions) and emits one valid draft claim so the parse → render path
# runs offline.
cat > "${RUNNER_TEMP:-/tmp}/mock-prompt.txt"
proposals='{
  "proposals": [
    {
      "action": "create",
      "file": "proposals.adoc",
      "ko_id": "fixture.proposed.app",
      "content": "::claim fixture.proposed.app\nstatus: open\nowner: ci\nimpacts: [src/app.rs]\n--\nDraft claim proposed by the mock provider.\n::",
      "rationale": "mock draft for the CI fixture"
    }
  ]
}'
jq -n --arg r "$proposals" '{type: "result", result: $r}'
