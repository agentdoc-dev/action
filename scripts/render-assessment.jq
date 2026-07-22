def clipped($limit):
  tostring | if length > $limit then .[0:$limit] + "…" else . end;
def escaped($limit):
  clipped($limit)
  | gsub("[\u0000-\u001f\u007f]"; " ")
  | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")
  | gsub("\\|"; "&#124;");
def code($limit): "<code>" + escaped($limit) + "</code>";
def severity_rank:
  if . == "error" then 0 elif . == "warning" then 1 else 2 end;
def class_rank:
  if . == "covered" then 0
  elif . == "provisional" then 1
  elif . == "uncovered" then 2
  else 3 end;
def omitted($count):
  if $count > 0 then "\n\n_" + ($count|tostring) + " more record(s) omitted; use the retained assessment for the complete list._" else "" end;
def details($summary; $body):
  "<details><summary>" + $summary + "</summary>\n\n" + $body + "\n\n</details>";

def validation:
  (.diagnostics // [] | sort_by([(.severity|severity_rank), (.source.path // ""), (.object_id // ""), .code])) as $all
  | ($all[0:10]) as $shown
  | "### Validation\n\n"
    + "- Errors: **\(.validation.errors_full // 0)** total · \(.validation.errors_changed // 0) changed · \(.validation.errors_unchanged // 0) unchanged · \(.validation.errors_unattributed // 0) unattributed\n"
    + "- Warnings: **\(.validation.warnings // 0)**"
    + (if ($all|length) == 0 then ""
       elif $style == "table" then
         "\n\n" + details("Diagnostics (\($all|length))";
           "| Severity | Code | Source | Message |\n|---|---|---|---|\n"
           + ($shown | map("| " + (.severity|escaped(16)) + " | " + (.code|code(128)) + " | "
               + (if .source then ((.source.path|code(300)) + ":" + (.source.line|tostring) + ":" + (.source.column|tostring)) else "—" end)
               + " | " + (.message|escaped(512)) + " |") | join("\n"))
           + omitted(($all|length)-($shown|length)))
       else
         "\n\n" + details("Diagnostics (\($all|length))";
           ($shown | map("- **" + (.severity|escaped(16)) + "** " + (.code|code(128))
             + (if .source then " at " + (.source.path|code(300)) + ":" + (.source.line|tostring) + ":" + (.source.column|tostring) else "" end)
             + " — " + (.message|escaped(512))
             + (if $style == "detailed" and .object_id then " · object " + (.object_id|code(128)) + " · changed: " + (.changed_in_pr|code(16)) else "" end)) | join("\n"))
           + omitted(($all|length)-($shown|length)))
       end);

def assessment:
  "### Assessment\n\n"
  + (if .completeness == "partial" then "> ⚠️ **Assessment incomplete.** AgentDoc could not establish a complete deterministic result.\n\n"
     elif .completeness == "error" and .outcome == "not_evaluated" then "> ❌ **Assessment not evaluated.** Inspect the workflow failure and rerun.\n\n"
     elif .completeness == "error" then "> ❌ **Knowledge structure invalid.** The final gate follows the configured structural enforcement mode.\n\n"
     else "" end)
  + "- Completeness: " + (.completeness|code(32)) + "\n"
  + "- Deterministic outcome: " + (.outcome|code(32)) + "\n"
  + "- Evaluation date: " + (.evaluation_date|code(32));

def changed_paths:
  (.paths.value // [] | sort_by([(.classification|class_rank), .path])) as $all
  | ($all[0:40]) as $shown
  | "### Changed paths\n\n"
    + "- covered: \(.summary.covered // 0)\n- provisional: \(.summary.provisional // 0)\n- uncovered: \(.summary.uncovered // 0)\n- excluded: \(.summary.excluded // 0)"
    + (if .paths.status != "available" then "\n\n> ⚠️ Path classification unavailable."
       elif ($all|length) == 0 then ""
       elif $style == "table" then
         "\n\n" + details("Classified paths (\($all|length))";
           "| Classification | Path | Evidence |\n|---|---|---|\n"
           + ($shown | map("| " + (.classification|escaped(32)) + " | " + (.path|code(300)) + " | "
             + (if .classification == "excluded" then (.exclusion_reason // "unspecified" | escaped(128))
                elif (.matches|length) > 0 then ([.matches[].object_id|code(128)]|join(", ")) else "—" end) + " |") | join("\n"))
           + omitted(($all|length)-($shown|length)))
       else
         "\n\n" + details("Classified paths (\($all|length))";
           ($shown | map("- **" + (.classification|escaped(32)) + "** — " + (.path|code(300))
             + (if .classification == "excluded" then " · reason: " + (.exclusion_reason // "unspecified" | code(128))
                elif $style == "detailed" and (.matches|length) > 0 then " · objects: " + ([.matches[0:5][].object_id|code(128)]|join(", "))
                else "" end)) | join("\n"))
           + omitted(($all|length)-($shown|length)))
       end);

def disposition:
  if .changed_in_pr == "yes" then "changed in this PR"
  elif .changed_in_pr == "no" then "not changed in this PR — human disposition required"
  else "change status unknown — human disposition required" end;
def affected_knowledge:
  (.objects.value // [] | sort_by([(.owner // "\uffff"), .id])) as $all
  | ($all[0:20]) as $shown
  | "### Affected knowledge\n\n- Affected Knowledge Objects: **\(.summary.impacted_objects // 0)**"
    + (if .objects.status != "available" then "\n\n> ⚠️ Affected knowledge unavailable."
       elif ($all|length) == 0 then "\n\n_None._"
       elif $style == "table" then
         "\n\n" + details("Knowledge Objects (\($all|length))";
           "| Object | Owner | Disposition |\n|---|---|---|\n"
           + ($shown | map("| " + (.id|code(128)) + " | " + (if .owner then (.owner|code(160)) else "—" end) + " | " + (disposition|escaped(128)) + " |") | join("\n"))
           + omitted(($all|length)-($shown|length)))
       else
         "\n\n" + details("Knowledge Objects (\($all|length))";
           ($shown | map("- " + (.id|code(128)) + " — **" + (disposition|escaped(128)) + "**"
             + (if .owner then " · owner: " + (.owner|code(160)) else "" end)
             + (if $style == "detailed" then " · kind: " + (.kind|code(64)) + " · source: " + (.source.path|code(300)) + ":" + (.source.line|tostring) + " · " + (.content_hash|code(80)) else "" end)) | join("\n"))
           + omitted(($all|length)-($shown|length)))
       end);

def knowledge_signals:
  ([.signals[]? | {object_id, kind, value:.signal}]
   + [.objects.value[]? | select(.evidence_quality != null) | {object_id:.id, kind:"evidence_quality", value:.evidence_quality}]
   + [.objects.value[]? | select(.kind == "contradiction") | {object_id:.id, kind:"contradiction", value:(.effective_status // .authored_status // "present")}]
   | unique_by([.kind,.object_id,.value]) | sort_by([.kind,.object_id,.value])) as $all
  | ($all[0:20]) as $shown
  | "### Knowledge signals\n\n"
    + (if ($all|length) == 0 then "_None._"
       elif $style == "table" then
         details("Lifecycle, evidence, and contradiction facts (\($all|length))";
           "| Kind | Object | Value |\n|---|---|---|\n"
           + ($shown | map("| " + (.kind|escaped(64)) + " | " + (.object_id|code(128)) + " | " + (.value|escaped(128)) + " |") | join("\n"))
           + omitted(($all|length)-($shown|length)))
       else
         details("Lifecycle, evidence, and contradiction facts (\($all|length))";
           ($shown | map("- **" + (.kind|escaped(64)) + "** — " + (.object_id|code(128)) + " · " + (.value|escaped(128))) | join("\n"))
           + omitted(($all|length)-($shown|length)))
       end);

def owners_and_obligations:
  (.required_reviewers // [] | sort_by(.owner)) as $owners
  | (.proof_obligations // [] | sort_by([.object_id,.kind,.reason])) as $obligations
  | "### Required owners and proof obligations\n\n"
    + (if ($owners|length) == 0 then "- Required owners: none\n" else
       "- Required owners: " + ($owners[0:20] | map((.owner|code(160)) + " (" + ([.object_ids[0:5][]|code(128)]|join(", ")) + ")") | join(", "))
       + (if ($owners|length) > 20 then " · \(($owners|length)-20) omitted" else "" end) + "\n" end)
    + (if ($obligations|length) == 0 then "- Proof obligations: none"
       else "- Proof obligations: **\($obligations|length)**\n\n"
         + details("Proof obligations (\($obligations|length))";
           ($obligations[0:20] | map("- " + (.object_id|code(128)) + " — " + (.reason|escaped(512))
             + (if $style == "detailed" then " · evidence: " + ([.required_evidence[0:5][]|code(64)]|join(", ")) else "" end)) | join("\n"))
           + omitted(($obligations|length)-([ $obligations[0:20][] ]|length)))
       end);

def receipt:
  "### Assessment receipt\n\n"
  + "- Requested base: " + (.snapshots.requested_base.resolved_commit // $requested_base | code(40)) + "\n"
  + "- Comparison base: " + (.snapshots.comparison_base.resolved_commit // $comparison_base | code(40)) + "\n"
  + "- Head: " + (.snapshots.head.resolved_commit // $head | code(40)) + "\n"
  + "- Assessment receipt: " + ($receipt_sha|code(80)) + " · [workflow run](" + $run_url + ")\n\n"
  + "<sub>adoc " + ($adoc_version|escaped(128)) + " · action " + ($action_ref|escaped(128)) + " · enforcement: " + ($enforcement|escaped(16)) + " · scope: " + ($scope|escaped(16)) + "</sub>";

"<!-- adoc:pr-report -->\n## AgentDoc PR Report\n\n"
+ validation + "\n\n"
+ assessment + "\n\n"
+ changed_paths + "\n\n"
+ affected_knowledge + "\n\n"
+ knowledge_signals + "\n\n"
+ owners_and_obligations + "\n\n"
+ (if ($proposal|length) > 0 or ($delivery|length) > 0 then
    "<!-- adoc:optional-start -->\n### Proposed Knowledge Objects\n\n"
    + "> **Legacy advisory drafts:** these proposals are partial, unreviewed, and non-canonical.\n\n"
    + $proposal + (if ($delivery|length) > 0 then "\n" + $delivery else "" end)
    + "\n<!-- adoc:optional-end -->\n\n"
   else "" end)
+ receipt
