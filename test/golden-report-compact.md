<!-- adoc:pr-report -->
## AgentDoc PR Report

### Validation

- Errors: **1** total · 1 changed · 0 unchanged · 0 unattributed
- Warnings: **1**

<details><summary>Diagnostics (2)</summary>

- **error** <code>schema.test</code> at <code>docs/billing.adoc</code>:12:1 — Unsafe &#124; &lt;!-- adoc:pr-report --&gt; marker
- **warning** <code>schema.warning</code> — Review evidence

</details>

### Assessment

- Completeness: <code>complete</code>
- Deterministic outcome: <code>uncovered</code>
- Evaluation date: <code>2026-07-22</code>

### Changed paths

- covered: 1
- provisional: 1
- uncovered: 1
- excluded: 1

<details><summary>Classified paths (4)</summary>

- **covered** — <code>src/covered.rs</code>
- **provisional** — <code>src/provisional.rs</code>
- **uncovered** — <code>src/uncovered.rs</code>
- **excluded** — <code>dist/generated.js</code> · reason: <code>generated_output</code>

</details>

### Affected knowledge

- Affected Knowledge Objects: **3**

<details><summary>Knowledge Objects (3)</summary>

- <code>billing.provisional</code> — **not changed in this PR — human disposition required** · owner: <code>&lt;img src=x onerror=alert(1)&gt;</code>
- <code>billing.covered</code> — **changed in this PR** · owner: <code>team-billing</code>
- <code>billing.conflict</code> — **change status unknown — human disposition required**

</details>

### Knowledge signals

<details><summary>Lifecycle, evidence, and contradiction facts (4)</summary>

- **contradiction** — <code>billing.conflict</code> · open
- **evidence_quality** — <code>billing.covered</code> · high
- **evidence_quality** — <code>billing.provisional</code> · low
- **lifecycle** — <code>billing.provisional</code> · stale

</details>

### Required owners and proof obligations

- Required owners: <code>alice</code> (<code>billing.covered</code>)
- Proof obligations: **1**

<details><summary>Proof obligations (1)</summary>

- <code>billing.covered</code> — Review impacted authoritative claim.

</details>

### Assessment receipt

- Requested base: <code>1111111111111111111111111111111111111111</code>
- Comparison base: <code>2222222222222222222222222222222222222222</code>
- Head: <code>3333333333333333333333333333333333333333</code>
- Assessment receipt: <code>sha256:0000000000000000000000000000000000000000000000000000000000000009</code> · [workflow run](https://github.com/agentdoc/test/actions/runs/1)

<sub>adoc v0.3.1 · action v1.6.0-test · enforcement: advisory · scope: full</sub>
