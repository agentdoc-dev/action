# AgentDoc Action

Runs one deterministic [AgentDoc](https://github.com/agentdoc-dev/adoc) Change
Assessment against the pull request's exact base and head commits. It posts an
in-place-updated **AgentDoc PR Report** comment series and exposes a retained,
machine-readable assessment plus `adoc.pr_assessment_receipt.v4` receipt.
The receipt binds each run to GitHub's workflow, repository, and actor context;
event payload identity fields are never used as caller identity.

The deterministic receipt and advisory knowledge disposition report shipped
through V9.2. V9.3.1 added cited semantic review, V9.3.2 added canonical
patches, and V9.3.3 adds human-governed same-PR or follow-up-PR delivery.
The current prerelease can create draft objects, update exact-head objects,
and report a disposition for every reviewed path. Pilot gates and the later
managed/on-prem boundaries remain in the
[AgentDoc V9 roadmap](https://github.com/agentdoc-dev/adoc/blob/main/docs/roadmap/ROADMAP-V9.md).

## Usage

```yaml
name: AgentDoc PR Report
on: pull_request
permissions:
  contents: read
  pull-requests: write   # sticky comment; omit → job-summary-only mode
concurrency:
  group: agentdoc-${{ github.event.pull_request.number }}
  cancel-in-progress: true
jobs:
  report:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0   # required for the exact base/head comparison
          persist-credentials: false
      - id: agentdoc
        uses: agentdoc-dev/action@v2.0.0-alpha.15
        with:
          claude-code-oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      - name: Retain the exact assessment and receipt
        if: always() && steps.agentdoc.outputs.assessment-receipt-path != ''
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
        with:
          name: agentdoc-${{ steps.agentdoc.outputs.assessment-invocation-id }}
          path: |
            ${{ steps.agentdoc.outputs.assessment-path }}
            ${{ steps.agentdoc.outputs.proposal-record-path }}
            ${{ steps.agentdoc.outputs.assessment-receipt-path }}
```

Start in the default `advisory` mode; flip to `enforcement: strict` after a
clean week. Without a token the action still posts the full report — the
optional semantic/proposal section is omitted.

To use your Claude subscription for drafting, run `claude setup-token` on a
machine with a browser (Pro/Max/Team/Enterprise plan; the token is valid for
about a year) and store the printed token as the `CLAUDE_CODE_OAUTH_TOKEN`
repository secret. An `anthropic-api-key` works too and wins when both are
set — configure only one.

Experimental cited semantic review is available only from the V9.3 `v2`
prerelease and requires an explicit opt-in:

```yaml
- id: agentdoc
  uses: agentdoc-dev/action@<full-v2-prerelease-commit>
  with:
    semantic-review: true
    propose: false
    claude-code-oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

This sends a bounded exact-revision code diff and selected Knowledge Object
bodies to Claude Code. The result is model-assisted and advisory; it is never
part of the deterministic Change Assessment.

## Inputs

| Input | Default | Description |
|---|---|---|
| `enforcement` | `advisory` | `advisory` reports structural invalidity without failing; `strict` gates on structural errors in the selected scope. |
| `scope` | `full` | `full` gates on every error in the knowledge base; `diff` gates only on errors in files changed by the pull request. The full report is always posted. |
| `report-style` | `compact` | Disposition layout: concise bullets, Markdown `table`, or `detailed` records with source and content hashes. Counts and conclusions are identical in every layout. |
| `adoc-version` | pinned tag | adoc release to install — each action release is tested against exactly its pinned default. `latest` is accepted but not recommended for pinning. |
| `sync-policy` | `advisory` | `advisory` reports baseline/drift state; `required` fails until the repository baseline is ready and any delivered knowledge PR is merged. |
| `bootstrap` | `false` | On `workflow_dispatch`, inventory the checked-out default branch and maintain one `adoc/bootstrap/<assessed-head>` draft PR. |
| `working-directory` | `.` | Directory from which `agentdoc.config.yaml` discovery starts. |
| `comment` | `true` | Set `false` to skip the sticky comment (annotations and job summary remain). Use when several jobs in one workflow run the action, so only one comments. |
| `comment-max-comments` | `5` | Maximum AgentDoc report comments, including the primary sticky comment. Use a positive integer or `unlimited`. |
| `github-token` | `${{ github.token }}` | Ephemeral token used to download adoc, update the sticky report, and perform an explicitly selected delivery. |
| `cloud-work-request` | — | Path to one canonical, expiring `adoc.work_request.v0`; empty disables Cloud hand-off. |
| `cloud-upload-url` | — | Exact HTTPS Workspace external-work result endpoint. Configure together with the request and token. |
| `cloud-upload-token` | — | Scoped, expiring Workspace upload credential, distinct from GitHub and provider credentials. |
| `trusted-change-request` | — | Secret-free exact-head request from the untrusted phase. Use only in a separately dispatched workflow committed on the protected base branch. |
| `trusted-change-authorization` | — | Expiring authorization for the exact request/head, policy, workload, eligible executor, and allowed paths. Configure with `trusted-change-request`. |
| `trusted-executor-qualification-id` | — | Base-controlled qualification ID for the direct cited executor. Required for trusted semantic or proposal runs without a fallback policy; do not derive it from the authorization being checked. |
| `semantic-review` | `false` | Experimental cited review of PR diff against selected exact-head knowledge. Explicit opt-in because code and Knowledge Object bodies leave the runner. |
| `semantic-fallback-policy` | — | Runner-temporary Cloud-authorized fallback policy path. Setting it selects the provider-neutral assessment path instead of cited review. |
| `semantic-primary-request` | — | Runner-temporary primary `adoc.semantic_executor_request.v0` path; required with a fallback policy. |
| `semantic-fallback-request` | `-` | Runner-temporary fallback request path, or `-` when the policy has no fallback. |
| `propose` | `true` | Generate cited create/update candidates and construct canonical `adoc.patch.v0` drafts. Skips when credentials are unavailable; set `false` to disable. |
| `propose-provider` | `claude-code` | Proposal engine. Only `claude-code` is accepted. |
| `propose-delivery` | `comment` | `comment` renders patches only; `commit` fast-forwards the same-repository source PR; `pr` maintains one owned follow-up proposal PR. |
| `propose-on-error` | `warn` | `warn` keeps semantic/proposal failure advisory; `fail` fails the explicitly requested optional operation after the report and receipt are finalized. |
| `propose-max-paths` | `10` | Maximum selected changed paths sent in the bounded model call. |
| `propose-coverage` | `bounded` | `bounded` reviews up to `propose-max-paths`; `full` reviews every non-excluded changed path. |
| `propose-authority` | `downgrade` | `downgrade` returns updated authoritative objects to a reviewable lifecycle, `preserve` keeps their status, and `suggest` does not construct existing-object patches. |
| `propose-contradictions` | `suggest` | `suggest` keeps contradiction lifecycle changes advisory; `propose` permits cited `resolved`/`dismissed` patches. |
| `propose-delivery-policy` | `atomic` | `atomic` withholds the set when any candidate fails; `partial` delivers validated candidates and reports every rejection. |
| `provider-timeout-seconds` | `600` | Maximum optional provider wall time, from `60` through `3600` seconds. The caller's job timeout must leave additional time for preparation, delivery, and finalization; use at least 15 minutes for the default. |
| `model` | Sonnet (pinned) | Model used for cited findings and patch candidates. |
| `claude-code-version` | pinned | Claude Code native package version. Only the bundled version with its pinned SHA-512 integrity is accepted. |
| `claude-code-oauth-token` | — | Subscription token from `claude setup-token`, stored as a repo secret. |
| `anthropic-api-key` | — | API-key alternative; takes precedence over the OAuth token when both are set. |

## Outputs and retention

| Output | Meaning |
|---|---|
| `connector-capability-manifest-path` / `connector-capability-manifest-sha256` | Version-exact `agentdoc.connector_capabilities.v0` bytes for the GitHub Action adapter and their digest. |
| `assessment-outcome` | `pass`, `review_required`, `uncovered`, `invalid`, or `not_evaluated`. |
| `assessment-completeness` | `complete`, `partial`, or `error`. |
| `assessment-invocation-id` | Collision-resistant identity used in retained filenames. |
| `assessment-path` / `assessment-sha256` | Exact validated `adoc.change_assessment.v0` bytes and digest; empty when no valid envelope exists. |
| `assessment-receipt-path` / `assessment-receipt-sha256` | Completed or failed `adoc.pr_assessment_receipt.v4` and its digest. |
| `semantic-review-path` / `semantic-review-sha256` | Complete validated `adoc.semantic_review.v0` and its digest; empty for disabled, skipped, partial, or error states. |
| `semantic-assessment-status` | Durable `required`, `completed`, `skipped`, `fell_back`, or `failed`; `completed`/`fell_back` require validator-accepted assessment evidence. |
| `baseline-status` / `baseline-path` / `baseline-sha256` | Repository-wide readiness plus the exact validated `adoc.repository_baseline.v0` artifact and digest. |
| `proposal-record-status` / `proposal-record-path` / `proposal-record-sha256` | `complete`, `skipped`, or `error` plus the exact retained `adoc.proposal.v0` record and its digest; the record binds validated patches to the assessed revisions, the pull request number, and the semantic executor receipt digests. Path and digest are empty unless `complete`. |
| `trusted-change-request-path` / `trusted-change-request-digest` | Secret-free request data for a separately authorized trusted run; present only for fork or Dependabot PR assessment. |

The composite Action does not upload workflow artifacts or receive Cloud
assessment credentials. The workflow owns retention with the separately
pinned `actions/upload-artifact` step shown above. Upload only the explicit
output paths, not the private Action directory. The canonical schemas are
[`adoc.pr_assessment_receipt.v4`](schemas/adoc.pr_assessment_receipt.v4.schema.json)
and [`adoc.semantic_review.v0`](schemas/adoc.semantic_review.v0.schema.json).
The shared semantic boundary is implemented by
`scripts/invoke-semantic-executor.sh`; `scripts/invoke-semantic-fallback.sh`
adds exactly one optional, independently eligible fallback and writes the
same durable semantic status consumed by receipt finalization.
The composite Action invokes that chain when the three semantic execution
inputs are configured. Control files must be prepared beneath `RUNNER_TEMP` by
trusted workflow code; this path emits a typed assessment, not proposal
candidates. A trusted authorization selects exactly one configured candidate;
when it selects the fallback, the primary is recorded as policy-ineligible and
is not invoked. For a generic adapter, `adapter.config_digest` is the SHA-256 of
canonical JSON containing `endpoint_policy_sha256` and `url`; the Action
recomputes it from the current policy bytes and destination before dispatch.

### Cloud assessment ingestion

Install the following second workflow on the protected default branch. GitHub
starts it on a fresh hosted runner after the PR workflow. The job checks out
the authenticated exact head as data, reruns only the deterministic assessment,
and passes its same-job outputs to the credentialed sub-action. Do not add
steps that execute pull-request code before ingestion.

```yaml
name: AgentDoc Cloud Ingestion
on:
  workflow_run:
    workflows: [AgentDoc PR Report]
    types: [completed]
permissions:
  contents: read
jobs:
  ingest:
    if: github.event.workflow_run.event == 'pull_request'
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: Checkout authenticated exact head as data
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7
        with:
          ref: ${{ github.event.workflow_run.pull_requests[0].head.sha }}
          fetch-depth: 0
          persist-credentials: false
      - id: assess
        uses: agentdoc-dev/action@<full-v2-prerelease-commit>
        with:
          comment: false
          propose: false
          semantic-review: false
          github-token: ${{ github.token }}
      - id: ingest
        uses: agentdoc-dev/action/cloud-assessment@<full-v2-prerelease-commit>
        with:
          assessment-path: ${{ steps.assess.outputs.assessment-path }}
          assessment-receipt-path: ${{ steps.assess.outputs.assessment-receipt-path }}
          github-token: ${{ github.token }}
          cloud-assessment-url: ${{ vars.ADOC_CLOUD_ASSESSMENT_URL }}
          cloud-assessment-repository-id: ${{ vars.ADOC_CLOUD_REPOSITORY_ID }}
          cloud-assessment-token: ${{ secrets.ADOC_CLOUD_ASSESSMENT_TOKEN }}
```

The sub-action reports `status`, `disposition`, `code`, `request-digest`,
`idempotency-key`, and `submission-path`. Cloud failures remain fail-honest and
cannot change the completed local assessment.

The bundled [connector capability manifest](connector-capabilities.json) is
published on every invocation. Its overall `Beta` stage is display-only;
per-capability maturity, dependencies, limitations, and contract ranges are
the configuration-policy inputs. Cloud-connected features remain Beta even
when a qualified standalone capability is GA.

## What it does

1. Installs the pinned `adoc` binary from GitHub Releases (sha256-verified).
2. Reads the event's exact base and head SHAs, requires their unique merge
   base, and captures one UTC evaluation date.
3. Runs `adoc assess-changes` exactly once. It validates the schema, tuple,
   date, revisions, availability, and required counters before retaining and
4. Emits source-located structural diagnostics as annotations and renders the
   validated assessment as a review brief followed by expanded deterministic
   evidence and collapsed audit metadata. Large lists are split only between
   complete Markdown records.
5. With `semantic-review: true`, rebuilds the exact head in an isolated
   worktree, requires graph/object-set digest parity, derives bounded hunks and
   graph-only lexical context, and accepts only strictly cited Claude Code
   findings with bounded judgment headlines and linked code evidence. This
   stage is advisory and separate from the assessment.
6. When `propose: true`, the same provider call may return private candidates
   correlated to validated actionable findings. The Action constructs
   `create_object`, `update_fields`, and `replace_body` `adoc.patch.v0`
   documents, applies the configured lifecycle policy, rejects
   authority-bearing fields and invented placement, then proves each candidate
   with `patch --check`, `patch --apply`, `check`, and a fresh no-embeddings
   build in one disposable exact-head worktree. Only canonical, non-authoritative
   patches appear in the report. Multi-patch updates validate atomically.
   When the installed `adoc` provides `proposal-record` and the semantic
   executor receipt completed, the validated patch set is bound into one
   canonical `adoc.proposal.v0` record whose `proposal_set_digest` is the
   reported proposal identity; otherwise (including `propose-authority:
   preserve` edits that retain non-reviewable authority) the record is
   honestly skipped.
7. For explicit `commit` or `pr` delivery, repeats that complete validation
   loop at the live assessed head, commits only AgentDoc-written `.adoc`
   sources, and performs one credential-bounded fast-forward or exact-lease
   push. The model never receives GitHub credentials or Git authority.
8. When all three Cloud hand-off inputs are present, binds the local assessment
   digest into an `adoc.work_result.v0` for the exact request/head and uploads
   it with the separate Workspace credential. Failure records
   `action.cloud_sync_failed` without changing local assessment or gate state.
9. For a fork or Dependabot change, emits a secret-free semantic-context request. A separately authorized protected-base run verifies its exact head, policy, workload, executor qualification, and allowed paths before any provider call; a later head change expires the result.
10. Finalizes semantic/proposal/delivery status, receipt, outputs, report, job
   summary, and a stale-head-safe owned comment series. The receipt records
   the assessed head separately from the delivery commit, branch, and
   follow-up PR URL.
11. Exits once from the final gate according to the deterministic assessment
   and `propose-on-error` policy.

## Reading the report

The report distinguishes source-diff facts from human governance. **Changed in
this PR** means the Knowledge Object's source changed between the assessed
revisions; it does not mean reviewed, reverified, approved, or semantically
correct. An affected object not changed in the PR is labeled as requiring human
disposition. Lifecycle, evidence-quality, and contradiction entries are
advisory facts copied from the deterministic Change Assessment.

Each comment stays below 60,000 characters. The primary comment always keeps
the review brief; complete records overflow into numbered owned comments.
`comment-max-comments` defaults to five. At that ceiling AgentDoc keeps
warnings, uncovered paths, obligations, actionable semantic findings, and the
proposal outcome before lower-priority detail, and reports exact omissions.
Set it to `unlimited` to retain every bounded record.

Semantic findings put the judgment before evidence. Actionable findings open
by default; consistent findings and hashes remain collapsed. Full reviews also
show one create/update/no-change/insufficient-evidence disposition per path.
`propose-delivery: pr` creates a draft follow-up PR only when at least one
canonical proposal validates.
When no eligible candidate exists, the report says that no update was proposed
and no follow-up PR was expected.

With `sync-policy: required`, “green” means the baseline is ready, the model
disposed every selected path, and no validated knowledge update is waiting.
When drift exists, AgentDoc creates or refreshes the follow-up PR and keeps the
source check red with `action.knowledge_sync_pending`; merging that follow-up
into the source branch triggers a rerun that can turn green. A consistent PR
does not create an empty follow-up PR.

## Assessment failure semantics

`complete` outcomes are advisory knowledge facts and stay green. A
`partial/not_evaluated` or `error/not_evaluated` assessment, malformed output,
missing exact commit, ambiguous comparison base, install failure, or more than
5,000 changed paths is non-green in every mode. `error/invalid` follows the
existing structural policy: advisory remains green; strict/full gates on all
errors; strict/diff gates on changed plus unattributed errors.

A valid nonzero assessment still receives a completed receipt. A failed
receipt means no valid assessment envelope was established. Receipt
finalization failure leaves receipt outputs empty and is always non-green.
Semantic failure never changes assessment bytes or meaning. It stays advisory
with `propose-on-error: warn`; `fail` makes failure of the explicitly requested
optional operation non-green after finalization.

## Fork pull requests and permissions

On PRs from forks `GITHUB_TOKEN` is read-only, so the comment cannot be posted.
The action detects the cross-repository head from the event payload and forces
all provider execution and draft delivery off even if a credential was
deliberately supplied. Dependabot PRs receive the same treatment. Annotations
and the job summary still work, and a workflow notice explains the skip.

| Situation | `comment` | `commit` | `pr` |
|---|---|---|---|
| Same-repo PR | ✅ report only | ✅ fast-forward source branch | ✅ owned stacked proposal PR |
| Fork or Dependabot PR | deterministic report + secret-free trusted request | refused with `delivery.fork_branch_read_only` | only from the separately authorized protected-base workflow; targets the base repository |

`pull_request_target` is unsupported by design: it runs untrusted PR content
with secrets and write permissions in scope, which is exactly the blast
radius the propose step avoids (it only runs on `pull_request` events).
Repositories accepting untrusted PRs should keep the default `comment`
delivery or set `propose: false`.

### Trusted fork and Dependabot processing

Keep the `pull_request` workflow secret-free. Retain `trusted-change-request-path` as an artifact, have the Cloud/controller record explicit authorization for its digest and exact head, then dispatch a separate workflow whose file and checkout come from the protected base branch. That workflow retrieves the request and authorization as data and passes their local paths to the Action:

```yaml
on:
  workflow_dispatch:
jobs:
  trusted-review:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
      id-token: write
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
          persist-credentials: false
      # A base-controlled step uses short-lived identity to write the exact
      # request and authorization to $RUNNER_TEMP without executing them.
      - uses: agentdoc-dev/action@<full-v2-prerelease-commit>
        with:
          trusted-change-request: ${{ runner.temp }}/trusted-change-request.json
          trusted-change-authorization: ${{ runner.temp }}/trusted-change-authorization.json
          trusted-executor-qualification-id: ${{ vars.ADOC_EXECUTOR_QUALIFICATION_ID }}
          semantic-review: true
          propose-delivery: pr
          propose-on-error: fail
          claude-code-oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

The authorization issuer must populate `.policy` and `.workload` from the same protected job using `scripts/trusted-run-bindings.sh`; the helper hashes the effective semantic/proposal/delivery settings, optional Cloud request digest and upload destination, and GitHub's workflow/run identity without reading credentials. The protected run binds those values, the workflow checkout, and regenerated assessment bytes to the authenticated pull-request base branch and revision. Before provider dispatch it requires every changed or selected Knowledge Object source path, every configured semantic-context handle and its content bytes, and every proposal destination to be authorized. Authorized paths use repository-root coordinates even when `working-directory` selects a subdirectory. It fetches public external fork heads without credentials and uses the scoped GitHub token only for private forks or same-repository Dependabot heads, never mutating `FETCH_HEAD` or running contributor packages, build hooks, scripts, actions, or workflow code. Commit delivery to a fork is impossible; follow-up PR delivery pushes only to the base repository. The Action rechecks authorization expiry immediately before each provider call and rechecks both expiry and the exact pull-request head immediately before each push, PR mutation, or Cloud upload. `pull_request_target` remains unsupported.

### Governed write modes

Keep `comment` as the default. For `commit`, grant `contents: write` and
`pull-requests: write`, retain the checkout settings from the usage example,
and opt in explicitly:

```yaml
permissions:
  contents: write
  pull-requests: write
concurrency:
  group: agentdoc-${{ github.event.pull_request.number }}
  cancel-in-progress: true
steps:
  - uses: actions/checkout@v7
    with:
      fetch-depth: 0
      persist-credentials: false
  - uses: agentdoc-dev/action@v2.0.0-alpha.15
    with:
      propose-delivery: commit
      claude-code-oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

`commit` works only when GitHub still reports the exact assessed SHA as the
same-repository PR head. It creates one child commit and performs a normal
fast-forward push; branch protection or a race wins and the canonical drafts
remain comment-only.

Use the same permissions and checkout for `propose-delivery: pr`. Also enable
**Allow GitHub Actions to create and approve pull requests** in repository
Actions settings. AgentDoc uses only the create capability: it never approves
anything. The deterministic branch is `adoc/proposals/pr-<source-number>`,
and its PR is stacked on the source branch. Updates require matching ownership
markers in both the prior commit and PR body plus an exact
`--force-with-lease`; an unowned or human-diverged branch is left untouched.
A human-closed proposal stays closed for the same assessed SHA. If the source
PR later changes, AgentDoc uses
`adoc/proposals/pr-<source-number>-<assessed-sha>` for the fresh proposal.
Follow-up proposal PRs are created and maintained as drafts.

For a full post-change knowledge sync with partial delivery of independently
validated candidates:

```yaml
with:
  sync-policy: required
  semantic-review: true
  propose: true
  propose-coverage: full
  propose-max-paths: 50
  propose-authority: downgrade
  propose-contradictions: propose
  propose-delivery-policy: atomic
  propose-delivery: pr
  propose-on-error: fail
  claude-code-oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

### One-time repository bootstrap

Run the same Action manually against the default branch before enabling
required sync on pull requests:

```yaml
name: AgentDoc bootstrap
on: workflow_dispatch
permissions:
  contents: write
  pull-requests: write
jobs:
  bootstrap:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
          persist-credentials: false
      - uses: agentdoc-dev/action@v2.0.0-alpha.15
        with:
          bootstrap: true
          sync-policy: required
          propose: true
          propose-coverage: full
          propose-delivery: pr
          propose-on-error: fail
          claude-code-oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

The baseline always inventories every tracked path. Bootstrap reviews the
next `propose-max-paths` uncovered paths and maintains the owned
`adoc/bootstrap/<assessed-head>` draft PR; merge it and rerun until `baseline-status` is
`ready`. Candidates that cover none of the selected uncovered paths are
rejected, as are updates that remove existing impacts. Model-selected
`no_durable_knowledge` paths remain visible
dispositions; the model cannot add assessment exclusions.

Both write modes degrade to the report with a stable receipt reason when the
head is stale, permission is missing, protection rejects a push, checkout
credentials were persisted, or proposal ownership cannot be proved. They
never approve, merge, dismiss review, change CODEOWNERS, bypass protection, or
alter repository settings.

## Supported runners

Linux x86_64 and arm64 (`ubuntu-latest`, `ubuntu-24.04-arm`). Other platforms
fail with a clear error.

## Security

- The `adoc` binary is downloaded only from the adoc repository's GitHub
  Releases and verified against its published sha256 checksum.
- Assessment uses only exact event SHAs and one verified merge base. Missing
  history fails with remediation instead of falling back to a branch name or
  GitHub's synthetic merge checkout.
- Unvalidated CLI stderr is private. Only source-located diagnostics from the
  validated envelope can reach the problem matcher.
- Retained assessment, semantic review, and receipt files contain metadata,
  citations, bounded rationale, and digests—not raw diffs, Knowledge Object
  bodies, prompts, provider output, or credentials.
- No third-party actions are used inside this action.
- The GitHub token is used for the authenticated release download, PR APIs,
  and only the explicitly selected bounded delivery. The Action refuses
  persisted checkout credentials, disables credential helpers, uses a
  temporary askpass script for Git network operations, and removes it after
  the step. The model never receives the token.
- Cloud hand-off accepts only a scoped HTTPS Workspace credential and rejects
  reuse of the GitHub token or either provider credential. Its request must
  bind the authenticated repository ID, pull request, and exact assessed head.
- Cloud assessment ingestion runs only in a fresh GitHub-hosted
  `workflow_run` job whose workflow file comes from the protected default
  branch. The pull-request Action never receives that operation-scoped
  credential. The privileged job reruns the deterministic assessment from the
  authenticated exact head without executing contributor code, then validates
  the pinned Action and current job identity before exposing the credential.
- The allowlisted native Claude Code archive is downloaded in an empty
  environment, checked against the Action's pinned SHA-512, and installed
  before a provider credential is selected. API keys take precedence when
  both inputs are present; only that one credential reaches the provider.
- With semantic review explicitly enabled, bounded coverage selects up to 10
  paths by default (50 maximum); full coverage can disposition up to the
  assessment limit of 500 paths. In both modes at most 20 hunks per path,
  32 KiB per hunk, 256 KiB total diff, and 50 Knowledge Object bodies of at
  most 16 KiB each may leave the runner. Claude
  Code provider-side processing, retention, and training terms are controlled
  by the consumer's Anthropic account and are not promised by AgentDoc.
- PR diff and selected knowledge flow into the LLM prompt fenced as untrusted data; the
  provider receives an empty temporary home and working directory with all
  settings, hooks, plugins, MCP servers, commands, and tools disabled. Its
  output must match a strict bounded JSON contract; authority-bearing fields
  and non-allowlisted placement are rejected; and every canonical patch must
  pass the exact-head sequential AgentDoc validation loop before it appears.
  Provider output, stderr, prompts, and temporary config are removed after the
  optional model stage.
- Semantic context is compiled in an isolated exact-head worktree. Its graph
  and canonical object-set digests must match the deterministic assessment;
  lexical retrieval receives only that graph and cannot load embeddings or a
  tracked search artifact.
- Proposal input/output and report sizes are bounded. Patch bytes, check
  results, ordered patch digests, and the proposal-set digest are computed by
  the Action; provider failures never change the deterministic assessment.
- Pin the full Action commit SHA in security-sensitive repositories.

## Releasing (maintainers)

Stable v1 maintenance tags continue to move the floating `v1` tag:

```sh
git tag v1.x.y && git push origin v1.x.y
git tag -f v1 && git push -f origin v1
```

Publish a GitHub Release from the tag (required for the Marketplace listing).
Bump the `adoc-version` default in `action.yml` when a new adoc release is
validated.

V9.3 dogfood releases use prerelease tags such as `v2.0.0-alpha.3`. Do not
create or move floating `v2`, and do not move `v1` to V9.3 behavior until the
V9.3.2–V9.3.3 release gates are complete.

## License

MIT
