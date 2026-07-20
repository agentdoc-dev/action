#!/usr/bin/env bash
# Mock provider emitting a draft with a dangling depends_on — the sandbox
# `adoc check` must reject it and the report must fall back to the
# mechanical path list.
cat > /dev/null
proposals='{
  "proposals": [
    {
      "action": "create",
      "file": "proposals.adoc",
      "ko_id": "fixture.proposed.dangling",
      "content": "::claim fixture.proposed.dangling\nstatus: open\nowner: ci\ndepends_on: fixture.does-not-exist\nimpacts: [src/app.rs]\n--\nDraft with a dangling dependency.\n::",
      "rationale": "must be rejected by sandbox validation"
    }
  ]
}'
jq -n --arg r "$proposals" '{type: "result", result: $r}'
