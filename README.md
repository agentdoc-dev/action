# AgentDoc Action

Runs one deterministic [AgentDoc](https://github.com/agentdoc-dev/adoc) Change
Assessment against the pull request's exact base and head commits. It posts one
in-place-updated **AgentDoc PR Report** and exposes a retained, machine-readable
assessment plus `adoc.pr_assessment_receipt.v0` receipt.

The deterministic receipt and advisory knowledge disposition report shipped
through V9.2. V9.3.1 added cited semantic review. V9.3.2 adds canonical,
create-only AgentDoc patches proved in an exact-head sandbox; governed Git
delivery, pilot gates, and the later managed/on-prem boundaries remain in the
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
        uses: agentdoc-dev/action@v2.0.0-alpha.2
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
| `working-directory` | `.` | Directory from which `agentdoc.config.yaml` discovery starts. |
| `comment` | `true` | Set `false` to skip the sticky comment (annotations and job summary remain). Use when several jobs in one workflow run the action, so only one comments. |
| `github-token` | `${{ github.token }}` | Token used to download the adoc release and upsert the sticky pull request comment. |
| `semantic-review` | `false` | Experimental cited review of bounded PR diff against selected exact-head knowledge. Explicit opt-in because code and Knowledge Object bodies leave the runner. |
| `propose` | `true` | Generate cited create-only candidates and construct canonical `adoc.patch.v0` drafts. Skips when credentials are unavailable; set `false` to disable. |
| `propose-provider` | `claude-code` | Proposal engine. Only `claude-code` is accepted. |
| `propose-delivery` | `comment` | `comment` renders canonical patches in the sticky report. Governed `commit` and `pr` delivery are reserved for V9.3.3 and currently remain comment-only. |
| `propose-on-error` | `warn` | `warn` keeps semantic/proposal failure advisory; `fail` fails the explicitly requested optional operation after the report and receipt are finalized. |
| `propose-max-paths` | `10` | Maximum selected changed paths sent in the bounded model call. |
| `model` | Sonnet (pinned) | Model used for cited findings and patch candidates. |
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
| `semantic-review-path` / `semantic-review-sha256` | Complete validated `adoc.semantic_review.v0` and its digest; empty for disabled, skipped, partial, or error states. |

The composite Action does not upload artifacts. The workflow owns retention
with the separately pinned `actions/upload-artifact` step shown above. Upload
only the explicit output paths, not the private Action directory. The
canonical schemas are
[`adoc.pr_assessment_receipt.v0`](schemas/adoc.pr_assessment_receipt.v0.schema.json)
and [`adoc.semantic_review.v0`](schemas/adoc.semantic_review.v0.schema.json).

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
5. With `semantic-review: true`, rebuilds the exact head in an isolated
   worktree, requires graph/object-set digest parity, derives bounded hunks and
   graph-only lexical context, and accepts only strictly cited Claude Code
   findings. This stage is advisory and separate from the assessment.
6. When `propose: true`, the same provider call may return private candidates
   correlated to validated `extends_existing_knowledge` findings. The Action
   constructs create-only `adoc.patch.v0` documents, rejects authority-bearing
   status/fields and invented placement, then proves each patch sequentially
   with `patch --check`, `patch --apply`, `check`, and a fresh no-embeddings
   build in one disposable exact-head worktree. Only canonical, non-authoritative
   patches appear in the report.
7. Finalizes semantic/proposal/delivery status, receipt, outputs, report, job summary,
   and a stale-head-safe sticky comment.
8. Exits once from the final gate according to the deterministic assessment
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
and receipt. Optional model-assisted sections are removed as one unit before
any deterministic report content is omitted.

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
| Same-repo PR | ✅ | ⚠️ V9.3.3, comment only | ⚠️ V9.3.3, comment only |
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
- Retained assessment, semantic review, and receipt files contain metadata,
  citations, bounded rationale, and digests—not raw diffs, Knowledge Object
  bodies, prompts, provider output, or credentials.
- No third-party actions are used inside this action.
- The GitHub token is used for the authenticated release download and PR
  comment API call. V9.3.2 does not give the model a Git writer.
- The allowlisted native Claude Code archive is downloaded in an empty
  environment, checked against the Action's pinned SHA-512, and installed
  before a provider credential is selected. API keys take precedence when
  both inputs are present; only that one credential reaches the provider.
- With semantic review explicitly enabled, up to 10 selected paths by default
  (50 maximum), 20 hunks per path, 32 KiB per hunk, 256 KiB total diff, and 50
  Knowledge Object bodies of at most 16 KiB each may leave the runner. Claude
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

V9.3 dogfood releases use prerelease tags such as `v2.0.0-alpha.2`. Do not
create or move floating `v2`, and do not move `v1` to V9.3 behavior until the
V9.3.2–V9.3.3 release gates are complete.

## License

MIT
