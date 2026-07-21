#!/usr/bin/env bash
# Mock provider emitting an `update` draft for the clean fixture's claim —
# exercises the stale-KO scope and the block-replacement apply path.
cat > "${RUNNER_TEMP:-/tmp}/mock-prompt.txt"
proposals='{
  "proposals": [
    {
      "action": "update",
      "file": "index.adoc",
      "ko_id": "fixture.ci.green",
      "content": "::claim fixture.ci.green\nstatus: open\nowner: ci\nexpires_at: 2125-01-01\nsource: this fixture\ntest: exercised by the action integration workflow\nimpacts: [src/app.rs]\n--\nRefreshed by the mock provider after its governed code changed.\n::",
      "rationale": "governed code changed; refresh this draft"
    }
  ]
}'
jq -n --arg r "$proposals" '{type: "result", result: $r}'
