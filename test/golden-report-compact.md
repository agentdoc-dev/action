<!-- adoc:pr-report -->
## AgentDoc PR Report

> ⚠️ **Review needed.** 1 uncovered path(s), 1 proof obligation(s), and 0 actionable semantic finding(s).

| Area | Result | Detail |
|---|---|---|
| Structure | ❌ Invalid | 1 error(s) · 1 warning(s) |
| Deterministic coverage | ⚠️ Needs attention | 1 covered · 1 provisional · 1 uncovered · 1 excluded |
| Human review | ⚠️ Required | 1 owner group(s) · 1 proof obligation(s) |
| Semantic review | — Not requested | 0 consistent · 0 actionable |
| Knowledge update | — Not requested | Proposal generation is disabled |

### Validation

- **Errors:** 1 total · 1 changed · 0 unchanged · 0 unattributed
- **Warnings:** 1

<details open><summary>Diagnostics 1–2 of 2</summary>

- **error** <code>schema.test</code> at <code>docs/billing.adoc</code>:12:1 — Unsafe &#124; &lt;!-- adoc:pr-report --&gt; marker
- **warning** <code>schema.warning</code> — Review evidence

</details>

### Deterministic assessment

- **Completeness:** <code>complete</code>
- **Outcome:** <code>uncovered</code>
- **Evaluation date:** <code>2026-07-22</code>

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

- Requested base: <code>1111111111111111111111111111111111111111</code>
- Comparison base: <code>2222222222222222222222222222222222222222</code>
- Head: <code>3333333333333333333333333333333333333333</code>
- Assessment receipt: <code>sha256:0000000000000000000000000000000000000000000000000000000000000009</code> · [workflow run](https://github.com/agentdoc/test/actions/runs/1)

<sub>adoc v0.3.3 · action v1.6.0-test · enforcement: advisory · scope: full</sub>

</details>
