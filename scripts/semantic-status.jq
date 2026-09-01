def exact($keys): type == "object" and (keys | sort) == ($keys | sort);
def identity:
  exact(["request_id","provider","model","outcome","failure_code"])
  and (.request_id | type == "string" and length > 0)
  and (.provider | type == "string" and length > 0)
  and (.model | type == "string" and length > 0)
  and (.outcome | IN("not_invoked","completed","failed"))
  and (if .outcome == "completed" then .failure_code == null
    elif .outcome == "failed" then
      (.failure_code | type == "string" and length > 0)
    else .failure_code == null
      or (.failure_code | type == "string" and length > 0) end);

exact(["status","failure_code","assessment_sha256","primary","fallback"])
and (.status | IN("required","completed","skipped","fell_back","failed"))
and (if .status == "failed" then .failure_code == "action.semantic_review_failed"
  else .failure_code == null end)
and (.primary == null or (.primary | identity))
and (.fallback == null or (.fallback | identity))
and if .status == "completed" then
  (.assessment_sha256 | type == "string" and test("^sha256:[0-9a-f]{64}$"))
  and .primary.outcome == "completed" and .fallback == null
elif .status == "fell_back" then
  (.assessment_sha256 | type == "string" and test("^sha256:[0-9a-f]{64}$"))
  and .primary.outcome == "failed" and .fallback.outcome == "completed"
elif .status == "failed" then
  .assessment_sha256 == null
  and (.primary == null or .primary.outcome != "completed")
  and (.fallback == null or .fallback.outcome != "completed")
else
  .assessment_sha256 == null and .primary == null and .fallback == null
end
