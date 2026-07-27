def clipped($limit):
  tostring | if length > $limit then .[0:$limit] + "…" else . end;
def escaped($limit):
  clipped($limit)
  | gsub("[\u0000-\u001f\u007f]"; " ")
  | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")
  | gsub("\\|"; "&#124;");
def code($limit): "<code>" + escaped($limit) + "</code>";
def block($kind; $body): "<!-- adoc:block:" + $kind + " -->\n" + $body;
def details($open; $summary; $body):
  "<details" + (if $open then " open" else "" end) + "><summary>"
  + $summary + "</summary>\n\n" + $body + "\n\n</details>";
def chunks($size): [range(0; length; $size) as $i | .[$i:$i + $size]];
def range_label($index; $size; $total):
  (($index * $size) + 1) as $first
  | ([($first + $size - 1), $total] | min) as $last
  | if $first == $last then ($first | tostring)
    else ($first | tostring) + "–" + ($last | tostring)
    end;
def basename: split("/")[-1];
def url_path: split("/") | map(@uri) | join("/");
def class_rank:
  if . == "uncovered" then 0
  elif . == "provisional" then 1
  elif . == "covered" then 2
  else 3 end;
def severity_rank:
  if . == "error" then 0 elif . == "warning" then 1 else 2 end;
def finding_rank:
  if . == "contradicts_existing_knowledge" then 0
  elif . == "insufficient_evidence" then 1
  elif . == "extends_existing_knowledge" then 2
  else 3 end;
def finding_meta:
  if . == "consistent" then
    {icon:"✅", label:"Consistent with knowledge", actionable:false}
  elif . == "extends_existing_knowledge" then
    {icon:"📝", label:"Knowledge should be extended", actionable:true}
  elif . == "contradicts_existing_knowledge" then
    {icon:"⚠️", label:"Contradicts knowledge", actionable:true}
  else
    {icon:"❓", label:"Insufficient evidence", actionable:true}
  end;
def semantic_findings: $semantic[0].findings // [];
def path_dispositions: $semantic[0].path_dispositions // [];
def proposal_state: $proposal_status[0] // {};
def delivery_state: $delivery_status[0] // {};

def knowledge_update_result:
  (proposal_state) as $proposal
  | (delivery_state) as $delivery
  | if $delivery.status == "complete" and $delivery.mode == "pr" then
      "✅ PR created | [Follow-up PR](" + ($delivery.url | escaped(2048)) + ")"
    elif $delivery.status == "complete" and $delivery.mode == "commit" then
      "✅ Committed | Knowledge update delivered to the source branch"
    elif $proposal.status == "partial" then
      "⚠️ Partial | " + (($proposal.count // 0) | tostring) + " validated patch(es); omissions reported below"
    elif $proposal.status == "complete" then
      "📝 Drafted | " + (($proposal.count // 0) | tostring) + " validated patch(es)"
    elif $proposal.status == "error" or $delivery.status == "error" then
      "⚠️ Unavailable | Inspect the proposal or delivery diagnostics"
    elif $proposal.reason == "no_candidate_scope" then
      "— None | No eligible update; no follow-up PR created"
    elif $propose_enabled != "true" then
      "— Not requested | Proposal generation is disabled"
    else
      "— None | No validated knowledge update was delivered"
    end;

def report_brief:
  (semantic_findings) as $findings
  | ($findings | map(select(.classification != "consistent")) | length) as $actionable
  | (.validation.errors_full // 0) as $errors
  | (.validation.warnings // 0) as $warnings
  | (.summary.uncovered // 0) as $uncovered
  | (.summary.provisional // 0) as $provisional
  | (.proof_obligations // [] | length) as $obligations
  | (.required_reviewers // [] | length) as $owner_groups
  | block("summary";
      "<!-- adoc:pr-report -->\n## AgentDoc PR Report\n\n"
      + (if ($errors + $warnings + $uncovered + $provisional + $obligations + $actionable) > 0 then
          "> ⚠️ **Review needed.** "
          + ($uncovered | tostring) + " uncovered path(s), "
          + ($obligations | tostring) + " proof obligation(s), and "
          + ($actionable | tostring) + " actionable semantic finding(s)."
        else
          "> ✅ **No review concerns identified.** The assessed change is covered and has no actionable findings."
        end)
      + "\n\n| Area | Result | Detail |\n|---|---|---|\n"
      + "| Structure | "
      + (if $errors > 0 then "❌ Invalid" elif $warnings > 0 then "⚠️ Warning" else "✅ Valid" end)
      + " | " + ($errors | tostring) + " error(s) · " + ($warnings | tostring) + " warning(s) |\n"
      + "| Deterministic coverage | "
      + (if ($uncovered + $provisional) > 0 then "⚠️ Needs attention" else "✅ Covered" end)
      + " | " + ((.summary.covered // 0) | tostring) + " covered · "
      + ($provisional | tostring) + " provisional · " + ($uncovered | tostring)
      + " uncovered · " + ((.summary.excluded // 0) | tostring) + " excluded |\n"
      + "| Human review | "
      + (if ($obligations + $owner_groups) > 0 then "⚠️ Required" else "✅ None" end)
      + " | " + ($owner_groups | tostring) + " owner group(s) · "
      + ($obligations | tostring) + " proof obligation(s) |\n"
      + "| Semantic review | "
      + (if $semantic_requested != "true" then "— Not requested"
         elif ($semantic | length) == 0 then "⚠️ Unavailable"
         elif $actionable > 0 then "⚠️ Actionable"
         else "✅ Consistent" end)
      + " | " + (($findings | map(select(.classification == "consistent")) | length) | tostring)
      + " consistent · " + ($actionable | tostring) + " actionable |\n"
      + "| Knowledge update | " + knowledge_update_result + " |");

def validation:
  (.diagnostics // [] | sort_by([(.severity | severity_rank), (.source.path // ""), (.object_id // ""), .code])) as $all
  | block("validation";
      "### Validation\n\n"
      + "- **Errors:** \(.validation.errors_full // 0) total · \(.validation.errors_changed // 0) changed · \(.validation.errors_unchanged // 0) unchanged · \(.validation.errors_unattributed // 0) unattributed\n"
      + "- **Warnings:** \(.validation.warnings // 0)")
  + (if ($all | length) == 0 then ""
     else "\n\n" + ($all | chunks(10) | to_entries | map(
       .key as $index | .value as $items
       | block("diagnostic";
           details(true;
             "Diagnostics " + range_label($index; 10; ($all | length)) + " of " + (($all | length) | tostring);
             (if $style == "table" then
                "| Severity | Code | Source | Message |\n|---|---|---|---|\n"
                + ($items | map("| " + (.severity | escaped(16)) + " | " + (.code | code(128)) + " | "
                    + (if .source then ((.source.path | code(300)) + ":" + (.source.line | tostring) + ":" + (.source.column | tostring)) else "—" end)
                    + " | " + (.message | escaped(512)) + " |") | join("\n"))
              else
                ($items | map("- **" + (.severity | escaped(16)) + "** " + (.code | code(128))
                  + (if .source then " at " + (.source.path | code(300)) + ":" + (.source.line | tostring) + ":" + (.source.column | tostring) else "" end)
                  + " — " + (.message | escaped(512))
                  + (if $style == "detailed" and .object_id then
                      "\n  - Object: " + (.object_id | code(128)) + "\n  - Changed in PR: " + (.changed_in_pr | code(16))
                    else "" end)) | join("\n"))
              end)))
     ) | join("\n\n"))
     end);

def assessment:
  block("assessment";
    "### Deterministic assessment\n\n"
    + (if .completeness == "partial" then "> ⚠️ **Assessment incomplete.** AgentDoc could not establish a complete deterministic result.\n\n"
       elif .completeness == "error" and .outcome == "not_evaluated" then "> ❌ **Assessment not evaluated.** Inspect the workflow failure and rerun.\n\n"
       elif .completeness == "error" then "> ❌ **Knowledge structure invalid.** The final gate follows the configured structural enforcement mode.\n\n"
       else "" end)
    + "- **Completeness:** " + (.completeness | code(32)) + "\n"
    + "- **Outcome:** " + (.outcome | code(32)) + "\n"
    + "- **Evaluation date:** " + (.evaluation_date | code(32)));

def changed_paths:
  (.paths.value // [] | sort_by([(.classification | class_rank), .path])) as $all
  | block("changed-path-summary";
      "### Changed paths\n\n"
      + "- **Uncovered:** \(.summary.uncovered // 0)\n"
      + "- **Provisional:** \(.summary.provisional // 0)\n"
      + "- **Covered:** \(.summary.covered // 0)\n"
      + "- **Excluded:** \(.summary.excluded // 0)"
      + (if .paths.status != "available" then "\n\n> ⚠️ Path classification unavailable." else "" end))
  + (if ($all | length) == 0 then ""
     else "\n\n" + ($all | chunks(20) | to_entries | map(
       .key as $index | .value as $items
       | block("changed-path";
           details(true;
             "Classified paths " + range_label($index; 20; ($all | length)) + " of " + (($all | length) | tostring);
             (if $style == "table" then
                "| Classification | Path | Evidence |\n|---|---|---|\n"
                + ($items | map("| " + (.classification | escaped(32)) + " | " + (.path | code(300)) + " | "
                    + (if .classification == "excluded" then (.exclusion_reason // "unspecified" | escaped(128))
                       elif (.matches | length) > 0 then ([.matches[].object_id | code(128)] | join(", ")) else "—" end) + " |") | join("\n"))
              else
                ($items | map("- **" + (.classification | escaped(32)) + "** — " + (.path | code(300))
                  + (if .classification == "excluded" then "\n  - Reason: " + (.exclusion_reason // "unspecified" | code(128))
                     elif $style == "detailed" and (.matches | length) > 0 then
                       "\n  - Knowledge: " + ([.matches[].object_id | code(128)] | join(", "))
                     else "" end)) | join("\n"))
              end)))
     ) | join("\n\n"))
     end);

def disposition:
  if .changed_in_pr == "yes" then "changed in this PR"
  elif .changed_in_pr == "no" then "not changed in this PR — human disposition required"
  else "change status unknown — human disposition required" end;
def owner_record:
  "- **" + (.owner | escaped(160)) + "**\n"
  + (.object_ids | map("  - " + (. | code(128))) | join("\n"));
def obligation_record:
  "- **" + (.object_id | escaped(128)) + "** — " + (.reason | escaped(512))
  + (if $style == "detailed" then
      "\n  - Required evidence: " + ([.required_evidence[]? | code(64)] | join(", "))
    else "" end);

def owners_and_obligations:
  (.required_reviewers // [] | sort_by(.owner)) as $owners
  | (.proof_obligations // [] | sort_by([.object_id, .kind, .reason])) as $obligations
  | block("owner-summary";
      "### Required owners and proof obligations\n\n"
      + "- **Required owner groups:** " + (($owners | length) | tostring) + "\n"
      + "- **Proof obligations:** " + (($obligations | length) | tostring))
  + (if ($owners | length) == 0 then ""
     else "\n\n" + ($owners | chunks(10) | to_entries | map(
       .key as $index | .value as $items
       | block("owner";
           details(true;
             "Required owners " + range_label($index; 10; ($owners | length)) + " of " + (($owners | length) | tostring);
             ($items | map(owner_record) | join("\n"))))
     ) | join("\n\n"))
     end)
  + (if ($obligations | length) == 0 then ""
     else "\n\n" + ($obligations | chunks(10) | to_entries | map(
       .key as $index | .value as $items
       | block("proof-obligation";
           details(true;
             "Proof obligations " + range_label($index; 10; ($obligations | length)) + " of " + (($obligations | length) | tostring);
             ($items | map(obligation_record) | join("\n"))))
     ) | join("\n\n"))
     end);

def evidence_link:
  . as $e
  | ($e.new_range | split(",") | map(tonumber)) as $new
  | ($e.old_range | split(",") | map(tonumber)) as $old
  | (if $new[1] > 0 then {sha:$head, range:$new} else {sha:$comparison_base, range:$old} end) as $target
  | ($target.range[0]) as $first
  | ($first + $target.range[1] - 1) as $last
  | "[" + ($e.path | basename | escaped(160)) + "]("
    + ($server_url | rtrimstr("/")) + "/" + ($repository | escaped(300))
    + "/blob/" + $target.sha + "/" + ($e.path | url_path)
    + "#L" + ($first | tostring)
    + (if $last > $first then "-L" + ($last | tostring) else "" end) + ")"
    + " · " + (if $last > $first then "lines " + ($first | tostring) + "–" + ($last | tostring)
               else "line " + ($first | tostring) end);

def finding($open):
  . as $finding
  | ($finding.classification | finding_meta) as $meta
  | details($open;
      $meta.icon + " " + $meta.label + " — "
      + (($finding.headline // $meta.label) | escaped(120));
      "**Conclusion**\n\n"
      + ($finding.rationale | escaped(1000))
      + "\n\n**Code evidence**\n\n"
      + ($finding.code_evidence | map("- " + evidence_link) | join("\n"))
      + "\n\n**Knowledge checked**\n\n"
      + (if ($finding.knowledge_evidence | length) == 0 then "_None cited._"
         else ($finding.knowledge_evidence | map("- " + (.id | code(128))) | join("\n")) end)
      + (if $finding.proposal_expected then
          "\n\n> 📝 A knowledge proposal is expected for this finding."
        else "" end)
      + "\n\n"
      + details(false; "Audit metadata";
          "- Finding: " + ($finding.finding_id | code(64)) + "\n"
          + "- Classification: " + ($finding.classification | code(64)) + "\n"
          + "- Proposal expected: **" + (if $finding.proposal_expected then "yes" else "no" end) + "**\n"
          + "- Code citations:\n"
          + ($finding.code_evidence | map("  - " + (.path | code(4096)) + " · "
              + (.hunk_id | code(64)) + " · old " + (.old_range | code(32))
              + " · new " + (.new_range | code(32)) + " · " + (.hunk_sha256 | code(80))) | join("\n"))
          + "\n- Knowledge citations:"
          + (if ($finding.knowledge_evidence | length) == 0 then " none"
             else "\n" + ($finding.knowledge_evidence | map("  - " + (.id | code(128))
               + " · " + (.content_hash | code(80))) | join("\n")) end)));

def semantic_review:
  (semantic_findings | sort_by([(.classification | finding_rank), .finding_id])) as $all
  | ($all | map(select(.classification != "consistent"))) as $actionable
  | ($all | map(select(.classification == "consistent"))) as $consistent
  | if $semantic_requested != "true" then ""
    elif ($semantic | length) == 0 then
      block("semantic-summary";
        "### Semantic review\n\n"
        + "> ⚠️ **Model-assisted review unavailable.** The deterministic assessment remains authoritative.")
    else
      block("semantic-summary";
        "### Semantic review\n\n"
        + "> 🤖 **Model-assisted, advisory.** Findings are cited suggestions, not AgentDoc compiler output, verification, approval, or a merge gate.\n\n"
        + "- **Actionable:** " + (($actionable | length) | tostring) + "\n"
        + "- **Consistent:** " + (($consistent | length) | tostring))
      + (if ($actionable | length) == 0 then ""
         else "\n\n" + ($actionable | map(block("semantic-actionable"; finding(true))) | join("\n\n"))
         end)
      + (if ($consistent | length) == 0 then ""
         else "\n\n" + block("semantic-consistent-heading"; "#### Consistent findings")
           + "\n\n" + ($consistent | map(block("semantic-consistent"; finding(false))) | join("\n\n"))
         end)
    end;

def semantic_coverage:
  (path_dispositions | sort_by([.disposition,.path])) as $all
  | if ($all | length) == 0 then ""
    else
      block("semantic-coverage";
        "#### Knowledge sync coverage\n\n"
        + "- **Paths reviewed:** " + (($all | length) | tostring) + "\n"
        + "- **Create knowledge:** " + (($all | map(select(.disposition == "create_knowledge")) | length) | tostring) + "\n"
        + "- **Update knowledge:** " + (($all | map(select(.disposition == "update_knowledge")) | length) | tostring) + "\n"
        + "- **No knowledge change:** " + (($all | map(select(.disposition == "covered_no_change" or .disposition == "no_durable_knowledge")) | length) | tostring) + "\n"
        + "- **Insufficient evidence:** " + (($all | map(select(.disposition == "insufficient_evidence")) | length) | tostring)
        + "\n\n"
        + details(false; "Path dispositions";
            "| Path | Disposition | Rationale |\n|---|---|---|\n"
            + ($all | map("| " + (.path | code(300)) + " | "
                + (.disposition | code(64)) + " | "
                + (.rationale | escaped(500)) + " |") | join("\n"))))
    end;

def affected_knowledge:
  (.objects.value // [] | sort_by([(.owner // "\uffff"), .id])) as $all
  | block("knowledge-summary";
      "### Affected knowledge\n\n- **Affected Knowledge Objects:** \(.summary.impacted_objects // 0)"
      + (if .objects.status != "available" then "\n\n> ⚠️ Affected knowledge unavailable." else "" end))
  + (if ($all | length) == 0 then "\n\n_None._"
     else "\n\n" + ($all | chunks(10) | to_entries | map(
       .key as $index | .value as $items
       | block("knowledge-object";
           details(true;
             "Knowledge Objects " + range_label($index; 10; ($all | length)) + " of " + (($all | length) | tostring);
             (if $style == "table" then
                "| Object | Owner | Disposition |\n|---|---|---|\n"
                + ($items | map("| " + (.id | code(128)) + " | "
                    + (if .owner then (.owner | code(160)) else "—" end)
                    + " | " + (disposition | escaped(128)) + " |") | join("\n"))
              else
                ($items | map("- " + (.id | code(128)) + " — **" + (disposition | escaped(128)) + "**"
                  + (if .owner then "\n  - Owner: " + (.owner | code(160)) else "" end)
                  + (if $style == "detailed" then
                      "\n  - Kind: " + (.kind | code(64))
                      + "\n  - Source: " + (.source.path | code(300)) + ":" + (.source.line | tostring)
                      + "\n  - Content: " + (.content_hash | code(80))
                    else "" end)) | join("\n"))
              end)))
     ) | join("\n\n"))
     end);

def knowledge_signals:
  ([.signals[]? | {object_id, kind, value:.signal}]
   + [.objects.value[]? | select(.evidence_quality != null) | {object_id:.id, kind:"evidence_quality", value:.evidence_quality}]
   + [.objects.value[]? | select(.kind == "contradiction") | {object_id:.id, kind:"contradiction", value:(.effective_status // .authored_status // "present")}]
   | unique_by([.kind, .object_id, .value]) | sort_by([.kind, .object_id, .value])) as $all
  | block("signal-summary"; "### Knowledge signals\n\n- **Lifecycle, evidence, and contradiction facts:** " + (($all | length) | tostring))
  + (if ($all | length) == 0 then "\n\n_None._"
     else "\n\n" + ($all | chunks(20) | to_entries | map(
       .key as $index | .value as $items
       | block("knowledge-signal";
           details(true;
             "Knowledge signals " + range_label($index; 20; ($all | length)) + " of " + (($all | length) | tostring);
             (if $style == "table" then
                "| Kind | Object | Value |\n|---|---|---|\n"
                + ($items | map("| " + (.kind | escaped(64)) + " | " + (.object_id | code(128))
                    + " | " + (.value | escaped(128)) + " |") | join("\n"))
              else
                ($items | map("- **" + (.kind | escaped(64)) + "** — " + (.object_id | code(128))
                  + "\n  - Value: " + (.value | escaped(128))) | join("\n"))
              end)))
     ) | join("\n\n"))
     end);

def proposal:
  (proposal_state) as $status
  | (delivery_state) as $delivery
  | if $propose_enabled != "true" and ($proposal | length) == 0 then ""
    else block("proposal-summary";
      "### Knowledge proposal\n\n"
      + (if $delivery.status == "complete" and $delivery.mode == "pr" then
          "> ✅ **Follow-up pull request created:** [" + ($delivery.url | escaped(2048)) + "](" + ($delivery.url | escaped(2048)) + ")"
        elif $delivery.status == "complete" and $delivery.mode == "commit" then
          "> ✅ **Knowledge update delivered** to the source branch."
        elif $status.reason == "no_candidate_scope" then
          "> ℹ️ **No knowledge update was proposed.** No eligible semantic finding required one, so no follow-up pull request was created."
        elif $status.status == "error" then
          "> ⚠️ **Knowledge proposal unavailable.** The deterministic assessment remains available."
        elif $status.status == "partial" then
          "> ⚠️ **Partial knowledge update.** "
          + (($status.count // 0) | tostring)
          + " canonical patch(es) passed validation; rejected candidates are listed below."
        elif $status.reason == "atomic_candidate_rejection" then
          "> ⚠️ **Knowledge update withheld.** Atomic delivery was requested and at least one candidate failed validation."
        elif $status.status == "complete" then
          "> 📝 **Human review required.** " + (($status.count // 0) | tostring) + " canonical patch(es) passed validation."
        else
          "> ℹ️ **No validated knowledge update was delivered.**"
        end)
      + (if ($proposal | length) > 0 and $status.reason != "no_candidate_scope" then
          "\n\n" + $proposal
        else "" end)
      + "\n\n" + details(false; "Proposal audit metadata";
          "- Proposal status: " + (($status.status // "unavailable") | code(64)) + "\n"
          + "- Proposal reason: " + (($status.reason // "unavailable") | code(128)) + "\n"
          + "- Delivery status: " + (($delivery.status // "unavailable") | code(64)) + "\n"
          + "- Delivery mode: " + (($delivery.mode // $propose_delivery) | code(64))
          + (if $delivery.reason then "\n- Delivery reason: " + ($delivery.reason | code(128)) else "" end)))
    end;

def receipt:
  block("audit";
    details(false; "Run details and integrity";
      "- Requested base: " + (.snapshots.requested_base.resolved_commit // $requested_base | code(40)) + "\n"
      + "- Comparison base: " + (.snapshots.comparison_base.resolved_commit // $comparison_base | code(40)) + "\n"
      + "- Head: " + (.snapshots.head.resolved_commit // $head | code(40)) + "\n"
      + "- Assessment receipt: " + ($receipt_sha | code(80)) + " · [workflow run](" + $run_url + ")\n\n"
      + "<sub>adoc " + ($adoc_version | escaped(128)) + " · action " + ($action_ref | escaped(128))
      + " · enforcement: " + ($enforcement | escaped(16)) + " · scope: " + ($scope | escaped(16)) + "</sub>"));

report_brief + "\n\n"
+ validation + "\n\n"
+ assessment + "\n\n"
+ changed_paths + "\n\n"
+ owners_and_obligations + "\n\n"
+ semantic_review + (if semantic_review == "" then "" else "\n\n" end)
+ proposal + (if proposal == "" then "" else "\n\n" end)
+ semantic_coverage + (if semantic_coverage == "" then "" else "\n\n" end)
+ affected_knowledge + "\n\n"
+ knowledge_signals + "\n\n"
+ receipt
