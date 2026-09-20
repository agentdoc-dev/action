<!-- adoc:pr-report -->
Assessed `3333333` · time unavailable

> [!WARNING]
> **Knowledge review needed.** 1 changed path without knowledge coverage, 1 provisional path and 1 proof obligation need a decision.

| Area | Result |
|---|---|
| Structure | failed · 1 error (1 changed · 0 unchanged · 0 unattributed) · 1 warning |
| Coverage | needs attention · 1 uncovered · 1 provisional · 1 covered · 1 excluded |
| Human review | required · 1 owner · 1 proof obligation |
| Semantic review | not requested |
| Knowledge update | not requested |

### Validation

- **Errors:** 1 total · 1 changed · 0 unchanged · 0 unattributed
- **Warnings:** 1

<details open><summary>Diagnostics 1–2 of 2</summary>

- **error** <code>schema.test</code> at <code>docs/billing.adoc</code>:12:1 — Unsafe &#124; &lt;!-- adoc:pr-report --&gt; marker
- **warning** <code>schema.warning</code> — Review evidence

</details>

### Changed paths

- **Uncovered:** 1
- **Provisional:** 1
- **Covered:** 1
- **Excluded:** 1

<details open><summary>Classified paths 1–4 of 4</summary>

- **uncovered** — <code>src/uncovered.rs</code>
- **provisional** — <code>src/provisional.rs</code>
- **covered** — <code>src/covered.rs</code>
- **excluded** — <code>dist/generated.js</code>
  - Reason: <code>generated_output</code>

</details>

### Required owners and proof obligations

- **Required owner groups:** 1
- **Proof obligations:** 1

<details open><summary>Required owners 1 of 1</summary>

- **alice**
  - <code>billing.covered</code>

</details>

<details open><summary>Proof obligations 1 of 1</summary>

- **billing.covered** — Review impacted authoritative claim.

</details>

### Affected knowledge

- **Affected Knowledge Objects:** 3

<details open><summary>Knowledge Objects 1–3 of 3</summary>

- <code>billing.provisional</code> — **not changed in this PR — human disposition required**
  - Owner: <code>&lt;img src=x onerror=alert(1)&gt;</code>
- <code>billing.covered</code> — **changed in this PR**
  - Owner: <code>team-billing</code>
- <code>billing.conflict</code> — **change status unknown — human disposition required**

</details>

### Knowledge signals

- **Lifecycle, evidence, and contradiction facts:** 4

<details open><summary>Knowledge signals 1–4 of 4</summary>

- **contradiction** — <code>billing.conflict</code>
  - Value: open
- **evidence_quality** — <code>billing.covered</code>
  - Value: high
- **evidence_quality** — <code>billing.provisional</code>
  - Value: low
- **lifecycle** — <code>billing.provisional</code>
  - Value: stale

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
