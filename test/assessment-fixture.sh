# Shared retained artifacts from assessment-ingestion.sh; sourced with its fixture environment.
assessment="$CASE_DIR/outputs/assessment-$ADOC_INVOCATION_ID.json"
receipt="$CASE_DIR/outputs/receipt-$ADOC_INVOCATION_ID.json"
graph="$CASE_DIR/outputs/knowledge-graph-$ADOC_INVOCATION_ID.json"
semantic_context="$CASE_DIR/outputs/semantic-context-$ADOC_INVOCATION_ID.json"
semantic_assessment="$CASE_DIR/outputs/semantic-assessment-$ADOC_INVOCATION_ID.json"
semantic_executor="$CASE_DIR/outputs/semantic-executor-$ADOC_INVOCATION_ID.json"
semantic_executor_request="$CASE_DIR/outputs/semantic-executor-request-$ADOC_INVOCATION_ID.json"
jq -n '{schema_version:"adoc.graph.v6",nodes:[],edges:[],diagnostics:[]}' > "$graph"
graph_digest="sha256:$(sha256sum "$graph" | awk '{print $1}')"
jq -cn --arg base "$ADOC_REQUESTED_BASE" --arg head "$ADOC_HEAD" \
  --arg graph "$graph_digest" '{
  schema_version:"adoc.change_assessment.v0",completeness:"complete",outcome:"pass",
  snapshots:{requested_base:{resolved_commit:$base},head:{resolved_commit:$head}},
  knowledge_snapshot:{status:"available",graph_schema_version:"adoc.graph.v6",
    graph_sha256:$graph,object_set_sha256:("sha256:" + ("1" * 64))}
}' > "$assessment"
assessment_digest="sha256:$(sha256sum "$assessment" | awk '{print $1}')"
context_digest="sha256:$(printf semantic-context | sha256sum | awk '{print $1}')"
jq -n --arg context "$context_digest" --arg assessment "$assessment_digest" \
  --arg graph "$graph_digest" --arg head "$ADOC_HEAD" '{
    schema_version:"adoc.semantic_context.v0",context_digest:$context,
    subject_revision:{system:"git",value:$head},
    basis:{assessment_digest:$assessment,
      knowledge_basis:{kind:"graph_artifact",digest:$graph}},
    items:[{handle_id:"hunk-1",handle:{kind:"diff_hunk"}}]
  }' > "$semantic_context"
jq -n --arg context "$context_digest" --arg base "$ADOC_REQUESTED_BASE" \
  --arg head "$ADOC_HEAD" '{
    schema_version:"adoc.semantic_assessment.v0",context_digest:$context,
    base_revision:{system:"git",value:$base},
    head_revision:{system:"git",value:$head},
    identity:{provider:"test",model:"test-v1"},
    materiality_policy_version:"adoc.materiality.v0",
    scope:{handle_ids:["hunk-1"]},findings:[{
      finding_id:"finding-001",classification:"extends_existing_knowledge",
      affected_objects:[],citations:["hunk-1"],materiality:"material",
      proposed_disposition:"create_knowledge",candidate_updates:[],
      unresolved_questions:[],explanation:"A synthetic knowledge change is required."
    }]
  }' > "$semantic_assessment"
semantic_assessment_digest="sha256:$(sha256sum "$semantic_assessment" | awk '{print $1}')"
executor_config_digest="sha256:$(printf executor-config | sha256sum | awk '{print $1}')"
executor_prompt_digest="sha256:$(jq -cjn \
  '{contract_version:"test-v1",instructions:"Assess the exact context."}' \
  | sha256sum | awk '{print $1}')"
jq -cjn --arg config "$executor_config_digest" --arg prompt "$executor_prompt_digest" \
  --slurpfile context "$semantic_context" '{
    schema_version:"adoc.semantic_executor_request.v0",request_id:"primary",
    capability:"code_change_assessment",
    adapter:{kind:"generic",provider:"test",model:"test-v1",
      endpoint_class:"local",endpoint_id:"test",
      executor_digest:("sha256:" + ("5" * 64)),
      model_digest:("sha256:" + ("6" * 64)),config_digest:$config},
    task_digest:("sha256:" + ("3" * 64)),
    prompt:{contract_version:"test-v1",digest:$prompt,
      instructions:"Assess the exact context."},
    timeout_seconds:60,context:$context[0]
  }' > "$semantic_executor_request"
executor_request_digest="sha256:$(sha256sum "$semantic_executor_request" | awk '{print $1}')"
jq -n --arg context "$context_digest" --arg digest "$semantic_assessment_digest" \
  --arg request "$executor_request_digest" --slurpfile selected "$semantic_executor_request" '{
    schema_version:"adoc.semantic_executor_receipt.v0",request_id:"primary",
    request_digest:$request,capability:"code_change_assessment",
    outcome:"completed",assessment_digest:$digest,context_digest:$context,
    task_digest:$selected[0].task_digest,prompt_digest:$selected[0].prompt.digest,
    adapter:$selected[0].adapter
  }' > "$semantic_executor"
semantic_executor_digest="sha256:$(sha256sum "$semantic_executor" | awk '{print $1}')"
semantic_executor_request_digest="sha256:$(sha256sum "$semantic_executor_request" | awk '{print $1}')"
jq -cn --arg base "$ADOC_REQUESTED_BASE" --arg head "$ADOC_HEAD" \
  --arg digest "$assessment_digest" --arg semantic "$semantic_assessment_digest" \
  --arg graph "$graph_digest" --arg config "$executor_config_digest" '{
  schema_version:"adoc.pr_assessment_receipt.v4",run_status:"completed",
  action:{repository:"agentdoc-dev/action",requested_ref:("8" * 40),
    resolved_commit:("8" * 40),provenance:"full_sha"},
  revisions:{requested_base:$base,comparison_base:$base,head:$head},
  assessment:{schema_version:"adoc.change_assessment.v0",sha256:$digest,
    completeness:"complete",outcome:"pass"},
  knowledge_snapshot:{graph_schema_version:"adoc.graph.v6",graph_sha256:$graph,
    object_set_sha256:("sha256:" + ("1" * 64))},
  semantic_assessment:{status:"completed",failure_code:null,
    assessment_sha256:$semantic,
    primary:{request_id:"primary",provider:"test",model:"test-v1",
      outcome:"completed",failure_code:null},fallback:null},
  trusted_phase:{executor:{qualification_id:"internal-synthetic-qualified-test-v1",
    provider:"test",model:"test-v1",config_digest:$config}},
  ci:{provider:"github",repository:"agentdoc/test",pull_request:801,
    run_id:"202",run_attempt:3,job:"cloud_ingest",
    invocation_id:"inv_801_2_agentdoc_0123456789abcdef0123456789abcdef",
    actor:"alice",workload_identity:{provider:"github_actions",
    repository_id:"99",actor_id:"42",triggering_actor:"alice",
    workflow_ref:"agentdoc/test/.github/workflows/cloud-ingestion.yml@refs/heads/main",
    workflow_sha:("7" * 40)}}
}' > "$receipt"
receipt_digest="sha256:$(sha256sum "$receipt" | awk '{print $1}')"
proposal="$CASE_DIR/outputs/proposal-record-$ADOC_INVOCATION_ID.json"
patch="$CASE_DIR/proposal-patch.json"
jq -cnS --arg assessment "$assessment_digest" '{
  schema_version:"adoc.patch.v0",op:"create_object",
  target:"internal.synthetic.claim",
  changes:{body:"Synthetic internal tracer proposal.",kind:"claim",
    placement:{page_id:"internal.synthetic"},status:"draft"},
  reason:("AgentDoc assessment " + $assessment + " finding finding-001."),
  proposer:{type:"agent",id:"agentdoc-action/internal-synthetic@qualified-test-v1"}
}' > "$patch"
patch_digest="sha256:$(sha256sum "$patch" | awk '{print $1}')"
proposal_set_digest="sha256:$(printf '[\"%s\"]\n' "$patch_digest" | sha256sum | awk '{print $1}')"
jq -n --arg set "$proposal_set_digest" --arg base "$ADOC_REQUESTED_BASE" \
  --arg head "$ADOC_HEAD" --arg assessment "$assessment_digest" \
  --arg context "$context_digest" --arg semantic "$semantic_assessment_digest" \
  --arg patch_digest "$patch_digest" --slurpfile patch "$patch" '{
  schema_version:"adoc.proposal.v0",proposal_set_digest:$set,supersedes:null,
  bindings:{base_revision:{system:"git",value:$base},
    head_revision:{system:"git",value:$head},
    change_request:{system:"github_pull_request",id:"801"},
    assessment_digest:$assessment,semantic_context_digest:$context,
    semantic_assessment_digest:$semantic},
  content_bindings:[],patches:[{finding_id:"finding-001",
    placement_path:"docs/internal.adoc",page_id:"internal.synthetic",
    target:"internal.synthetic.claim",operation:"create_object",
    patch_digest:$patch_digest,patch:$patch[0]}]
}' > "$proposal"
proposal_digest="sha256:$(sha256sum "$proposal" | awk '{print $1}')"
jq --arg set "$proposal_set_digest" \
  '.proposals = {status:"complete",count:1,sha256:$set,reason:"validated"}' \
  "$receipt" > "$receipt.tmp"
mv "$receipt.tmp" "$receipt"
receipt_digest="sha256:$(sha256sum "$receipt" | awk '{print $1}')"
