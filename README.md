# AgentDoc Action

Runs one deterministic [AgentDoc](https://github.com/agentdoc-dev/adoc) Change
Assessment against the pull request's exact base and head commits. It posts one
in-place-updated **AgentDoc PR Report** and exposes a retained, machine-readable
assessment plus `adoc.pr_assessment_receipt.v0` receipt.

The deterministic receipt and advisory knowledge disposition report are
shipped through V9.2. Cited semantic review, canonical AgentDoc patches, pilot
gates, and the later managed/on-prem boundaries remain planned in the
[AgentDoc V9 roadmap](https://github.com/agentdoc-dev/adoc/blob/main/docs/roadmap/ROADMAP-V9.md).

## Usage

```yaml
name: AgentDoc PR Report
on: pull_request
permissions:
  contents: read
  pull-requests: write   # sticky comment; omit → job-summary-only mode
jobs:
  report:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0   # required for the exact base/head comparison
      - id: agentdoc
        uses: agentdoc-dev/action@v1
        with:
          claude-code-oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      - name: Retain the exact assessment and receipt
        if: always() && steps.agentdoc.outputs.assessment-receipt-path != ''
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
        with:
          name: agentdoc-${{ steps.agentdoc.outputs.assessment-invocation-id }}
          path: |
            ${{ steps.agentdoc.outputs.assessment-path }}
            ${{ steps.agentdoc.outputs.assessment-receipt-path }}
```

Start in the default `advisory` mode; flip to `enforcement: strict` after a
clean week. Without a token the action still posts the full report — the
optional legacy proposal section is omitted.

To use your Claude subscription for drafting, run `claude setup-token` on a
machine with a browser (Pro/Max/Team/Enterprise plan; the token is valid for
about a year) and store the printed token as the `CLAUDE_CODE_OAUTH_TOKEN`
repository secret. An `anthropic-api-key` works too and wins when both are
set — configure only one.

## Inputs

| Input | Default | Description |
|---|---|---|
| `enforcement` | `advisory` | `advisory` reports structural invalidity without failing; `strict` gates on structural errors in the selected scope. |
| `scope` | `full` | `full` gates on every error in the knowledge base; `diff` gates only on errors in files changed by the pull request. The full report is always posted. |
| `report-style` | `compact` | Disposition layout: concise bullets, Markdown `table`, or `detailed` records with source and content hashes. Counts and conclusions are identical in every layout. |
| `adoc-version` | pinned tag | adoc release to install — each action release is tested against exactly its pinned default. `latest` is accepted but not recommended for pinning. |
| `working-directory` | `.` | Directory from which `agentdoc.config.yaml` discovery starts. |
| `comment` | `true` | Set `false` to skip the sticky comment (annotations and job summary remain). Use when several jobs in one workflow run the action, so only one comments. |
| `github-token` | `${{ github.token }}` | Token used to download the adoc release, upsert the sticky pull request comment, and (for `commit`/`pr` delivery) push drafts. |
| `propose` | `true` | Draft Knowledge Objects with an LLM. Skips with a notice when no credentials are configured; set `false` to disable entirely. |
| `propose-provider` | `claude-code` | Proposal engine. Only `claude-code` is accepted. |
| `propose-delivery` | `comment` | `comment` renders drafts in the sticky report; `commit` also pushes them to the PR branch; `pr` maintains a follow-up `adoc/proposals/pr-<n>` pull request. `commit`/`pr` need `contents: write` (+ `pull-requests: write` for `pr`) and degrade to `comment` on forks or missing permissions. |
| `propose-on-error` | `warn` | `warn` falls back to the mechanical path list and keeps the job green; `fail` fails the job after the comment posts. |
| `propose-max-paths` | `10` | Cap per proposal scope sent to the LLM; the remainder is listed mechanically in the report. |
| `model` | Sonnet (pinned) | Model passed to the provider. |
| `claude-code-version` | pinned | Claude Code native package version. Only the bundled version with its pinned SHA-512 integrity is accepted. |
| `claude-code-oauth-token` | — | Subscription token from `claude setup-token`, stored as a repo secret. |
| `anthropic-api-key` | — | API-key alternative; takes precedence over the OAuth token when both are set. |

## Outputs and retention

| Output | Meaning |
|---|---|
| `assessment-outcome` | `pass`, `review_required`, `uncovered`, `invalid`, or `not_evaluated`. |
| `assessment-completeness` | `complete`, `partial`, or `error`. |
| `assessment-invocation-id` | Collision-resistant identity used in retained filenames. |
| `assessment-path` / `assessment-sha256` | Exact validated `adoc.change_assessment.v0` bytes and digest; empty when no valid envelope exists. |
| `assessment-receipt-path` / `assessment-receipt-sha256` | Completed or failed `adoc.pr_assessment_receipt.v0` and its digest. |
| `semantic-review-path` / `semantic-review-sha256` | Reserved and empty until V9.3. |

The composite Action does not upload artifacts. The workflow owns retention
with the separately pinned `actions/upload-artifact` step shown above. Upload
only the two output paths, not the private Action directory. The canonical
receipt schema is [`schemas/adoc.pr_assessment_receipt.v0.schema.json`](schemas/adoc.pr_assessment_receipt.v0.schema.json).

## What it does

1. Installs the pinned `adoc` binary from GitHub Releases (sha256-verified).
2. Reads the event's exact base and head SHAs, requires their unique merge
   base, and captures one UTC evaluation date.
3. Runs `adoc assess-changes` exactly once. It validates the schema, tuple,
   date, revisions, availability, and required counters before retaining and
   hashing the exact JSON bytes. It never reconstructs coverage in shell.
4. Emits source-located structural diagnostics as annotations and renders the
   validated assessment as stable Validation, Assessment, Changed paths,
   Affected knowledge, Knowledge signals, owner/obligation, and receipt
   sections. Large lists are collapsed and bounded; the retained assessment
   remains the complete machine-readable record.
5. When credentials are configured, drafts legacy Knowledge Objects with headless
   Claude Code across three scopes: `create` drafts for uncovered changed
   paths, and `update` drafts for Knowledge Objects whose governed code
   changed or whose fields are expired/overdue. Every draft is applied to a
   sandbox copy of the tree and must pass `adoc check` there; failures are
   listed as rejected. Receipts mark this output `partial` and
   `legacy_proposal_not_canonical` until V9.3.
6. Finalizes proposal/delivery status, receipt, outputs, report, job summary,
   and a stale-head-safe sticky comment.
7. Exits once from the final gate according to the deterministic assessment
   and `propose-on-error` policy.

## Reading the report

The report distinguishes source-diff facts from human governance. **Changed in
this PR** means the Knowledge Object's source changed between the assessed
revisions; it does not mean reviewed, reverified, approved, or semantically
correct. An affected object not changed in the PR is labeled as requiring human
disposition. Lifecycle, evidence-quality, and contradiction entries are
advisory facts copied from the deterministic Change Assessment.

The comment is capped at 60,000 characters. Counts and the deterministic
outcome always remain visible; bounded details point to the retained assessment
and receipt. Optional legacy model drafts are removed as one section before any
deterministic report content is omitted.

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

## Fork pull requests and permissions

On PRs from forks `GITHUB_TOKEN` is read-only, so the comment cannot be posted.
The action detects the cross-repository head from the event payload and forces
both provider execution and draft delivery off even if a credential was
deliberately supplied. Dependabot PRs receive the same treatment. Annotations
and the job summary still work, and a workflow notice explains the skip.

| Situation | `comment` | `commit` | `pr` |
|---|---|---|---|
| Same-repo PR, `contents: write` (+ `pull-requests: write` for `pr`) | ✅ | ✅ | ✅ |
| Same-repo PR, default read token | ✅ (comment needs `pull-requests: write`) | ⚠️ warns, comment only | ⚠️ warns, comment only |
| Fork PR (no secrets) | drafting skipped, deterministic report only | same | same |

`pull_request_target` is unsupported by design: it runs untrusted PR content
with secrets and write permissions in scope, which is exactly the blast
radius the propose step avoids (it only runs on `pull_request` events).
Repositories accepting untrusted PRs should keep the default `comment`
delivery or set `propose: false`.

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
- Retained assessment and receipt files contain metadata and digests, not raw
  diffs, Knowledge Object bodies, prompts, provider output, or credentials.
- No third-party actions are used inside this action.
- The GitHub token is used for the authenticated release download, the PR
  comment API call, and — only in `commit`/`pr` delivery — the draft push.
- The allowlisted native Claude Code archive is downloaded in an empty
  environment, checked against the Action's pinned SHA-512, and installed
  before a provider credential is selected. API keys take precedence when
  both inputs are present; only that one credential reaches the provider.
- PR diff content flows into the LLM prompt fenced as untrusted data; the
  provider receives an empty temporary home and working directory with all
  settings, hooks, plugins, MCP servers, commands, and tools disabled. Its
  output must match a strict bounded JSON contract; paths are canonicalized
  inside the checkout with symlinks rejected; authority-bearing fields are
  rejected; and every draft must pass `adoc check` in a copy before it appears
  anywhere. Provider output, stderr, prompts, and temporary config are removed
  after the proposal step.
- Proposal input/output, diagnostic, and report sizes are bounded. Sandbox
  checks compare complete error identities, so a new error in an already
  invalid file still rejects its draft. Provider failures never change the
  deterministic validation result.
- Pin the full commit SHA instead of `@v1` in security-sensitive repositories.

## Releasing (maintainers)

Tag semver releases and move the floating major tag:

```sh
git tag v1.x.y && git push origin v1.x.y
git tag -f v1 && git push -f origin v1
```

Publish a GitHub Release from the tag (required for the Marketplace listing).
Bump the `adoc-version` default in `action.yml` when a new adoc release is
validated.

## License

MIT
