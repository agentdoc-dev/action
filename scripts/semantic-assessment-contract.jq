def nonempty: type == "string" and test("^\\S(?:.*\\S)?$");
def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
def unique_array: type == "array" and length == (unique | length);
def finding:
  type == "object"
  and keys == ["affected_objects","candidate_updates","citations",
    "classification","explanation","finding_id","materiality",
    "proposed_disposition","unresolved_questions"]
  and (.finding_id | nonempty)
  and (.classification | IN("consistent","extends_existing_knowledge",
    "contradicts_existing_knowledge","insufficient_evidence"))
  and (.affected_objects | unique_array and all(.[];
    keys == ["content_hash","object_id"]
    and (.object_id | test("^[a-z0-9]+(?:-[a-z0-9]+)*(?:[.][a-z0-9]+(?:-[a-z0-9]+)*)+$"))
    and (.content_hash | digest)))
  and (.citations | unique_array and length > 0 and all(.[]; nonempty))
  and (.materiality | IN("material","immaterial","undetermined"))
  and (.proposed_disposition | IN("no_change_required","update_existing",
    "create_knowledge","needs_human_review"))
  and (.candidate_updates | type == "array" and all(.[];
    keys == ["body","fields","object_id"]
    and (.object_id | test("^[a-z0-9]+(?:-[a-z0-9]+)*(?:[.][a-z0-9]+(?:-[a-z0-9]+)*)+$"))
    and (.fields | type == "object")
    and ((.body | type == "string" and length > 0) or .body == null)
    and ((.body | type == "string" and length > 0) or (.fields | length > 0))))
  and (.unresolved_questions | type == "array" and all(.[]; nonempty))
  and (.explanation | nonempty);
type == "object"
and (del(.human_review) | keys == ["base_revision","context_digest",
  "findings","head_revision","identity","materiality_policy_version",
  "schema_version","scope"])
and .schema_version == "adoc.semantic_assessment.v0"
and .context_digest == $context and ($context | digest)
and .base_revision == {system:"git",value:$base}
and .head_revision == {system:"git",value:$head}
and .identity == {provider:$winner.provider,model:$winner.model}
and .materiality_policy_version == "adoc.materiality.v0"
and (.scope | keys == ["handle_ids"]
  and (.handle_ids | unique_array and all(.[]; nonempty)))
and (.findings | type == "array" and length > 0 and all(.[]; finding)
  and (map(.finding_id) | unique_array))
and (if has("human_review") then
  .identity.provider == "human"
  and (.human_review | keys == ["authority","independence",
    "requesting_principal_id","reviewing_principal_id"]
    and .authority == "semantic_review"
    and (.independence | IN("self_assessment","independent"))
    and (.requesting_principal_id | nonempty)
    and (.reviewing_principal_id | nonempty))
  else true end)
