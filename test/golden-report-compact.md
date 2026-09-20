<!-- adoc:pr-report -->
Assessed `3333333` · time unavailable

> [!WARNING]
> **Knowledge review needed.** 1 changed path without knowledge coverage, 1 provisional path and 1 proof obligation need a decision.

### What to do

- **<code>alice</code>** — decide on [<code>billing.covered</code>](https://github.com/agentdoc/test/blob/3333333333333333333333333333333333333333/docs/billing.adoc#L4). Its source changed in this PR while <code>verified</code>. Review impacted authoritative claim. Required evidence <code>source_code</code>. Either re-verify (read the new code, then set <code>verified_at: 2026-07-22</code>) or set <code>status: draft</code> until reviewed. Push the edit to this branch.
- **Author** — <code>src/uncovered.rs</code> matches no Knowledge Object. Add <code>impacts: [src/uncovered.rs]</code> to the claim that describes them, or add a new <code>::claim</code> with <code>status: draft</code>. If the workflow owner enables <code>semantic-review</code>, AgentDoc drafts this.

| Area | Result |
|---|---|
| Structure | failed · 1 error (1 changed · 0 unchanged · 0 unattributed) · 1 warning |
| Coverage | needs attention · 1 uncovered · 1 provisional · 1 covered · 1 excluded |
| Human review | required · 1 owner · 1 proof obligation |
| Semantic review | not requested |
| Knowledge update | not requested |

<details open><summary>Coverage · 4 changed paths</summary>

| Path | Class | Knowledge |
|---|---|---|
| <code>src/uncovered.rs</code> | **uncovered** | — |
| <code>src/provisional.rs</code> | provisional | <code>billing.provisional</code> · matched by <code>source_path</code> only |
| <code>src/covered.rs</code> | covered | <code>billing.covered</code> |
| <code>dist/generated.js</code> | excluded | <code>generated_output</code> |

</details>

<details open><summary>Affected knowledge · 3 objects</summary>

| Decision | Object | Kind · status | Owner | Evidence |
|---|---|---|---|---|
| none | <code>billing.provisional</code> | claim · <code>stale</code> | <code>&lt;img src=x onerror=alert(1)&gt;</code> · <code>bob</code> | low |
| **owner decision needed** · source changed in this PR | <code>billing.covered</code> | claim · <code>verified</code> | <code>team-billing</code> · <code>alice</code> | high |
| none · open contradiction, change unknown | <code>billing.conflict</code> | contradiction · <code>open</code> | — | — |

*Source changed in this PR* means the object's source moved between the assessed revisions. It does not mean reviewed, re-verified, or approved.

</details>

<details open><summary>Diagnostics · 1 error · 1 warning</summary>

- **error** <code>schema.test</code> · <code>docs/billing.adoc:12:1</code> — Unsafe &#124; &lt;!-- adoc:pr-report --&gt; marker *changed in this PR*
- **warning** <code>schema.warning</code> — Review evidence

</details>

<details><summary>Run details and integrity</summary>

| Field | Value |
|---|---|
| Assessed head | <code>3333333333333333333333333333333333333333</code> |
| Comparison base | <code>2222222222222222222222222222222222222222</code> · merge base |
| Requested base | <code>1111111111111111111111111111111111111111</code> |
| Evaluation date | <code>2026-07-22</code> |
| Assessment | <code>complete / uncovered</code> · <code>sha256:c878b1573122178b5114ea8685b4c0f9ad7b57dcb3c5350f85093fe27ec030d1</code> |
| Receipt | <code>unavailable</code> · <code>sha256:0000000000000000000000000000000000000000000000000000000000000009</code> |
| Knowledge graph | <code>adoc.graph.v5</code> · <code>sha256:1111111111111111111111111111111111111111111111111111111111111111</code> · object set <code>sha256:2222222222222222222222222222222222222222222222222222222222222222</code> |

[Workflow run](https://github.com/agentdoc/test/actions/runs/1) · [retained artifacts](https://github.com/agentdoc/test/actions/runs/1#artifacts) · The receipt, not this comment, is the record.

</details>

<sub>adoc v0.3.4 · action v1.6.0-test · enforcement advisory · scope full · Lifecycle, evidence and contradiction facts are copied from the deterministic Change Assessment.</sub>
