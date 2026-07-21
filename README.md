# AgentDoc Action

Validates your [AgentDoc](https://github.com/agentdoc-dev/adoc) Knowledge Objects
in Strict Mode on every pull request and posts a single, in-place-updated
**AgentDoc PR Report** comment: validation diagnostics, impacted knowledge
with drift-suspicion badges, unresolved contradictions, and LLM-drafted
Knowledge Object proposals for whatever the PR left uncovered.

The current behavior is documented below. The next implementation cycle—fail-honest deterministic assessment, exact-SHA receipts, cited opt-in semantic review, canonical AgentDoc patches, pilot gates, and the later managed/on-prem boundaries—is planned in the [AgentDoc V9 roadmap](https://github.com/agentdoc-dev/adoc/blob/main/docs/roadmap/ROADMAP-V9.md). Roadmap items are not shipped inputs or guarantees until this README and a tagged release say so.

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
          fetch-depth: 0   # required for the Impacted Query (--ref)
      - uses: agentdoc-dev/action@v1
        with:
          claude-code-oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

Start in the default `advisory` mode; flip to `enforcement: strict` after a
clean week. Without a token the action still posts the full report — the
Proposed section just lists uncovered paths instead of drafting them.

To use your Claude subscription for drafting, run `claude setup-token` on a
machine with a browser (Pro/Max/Team/Enterprise plan; the token is valid for
about a year) and store the printed token as the `CLAUDE_CODE_OAUTH_TOKEN`
repository secret. An `anthropic-api-key` works too and wins when both are
set — configure only one.

## Inputs

| Input | Default | Description |
|---|---|---|
| `enforcement` | `advisory` | `advisory` posts the report without failing the job; `strict` fails the job when `adoc check` finds errors. |
| `scope` | `full` | `full` gates on every error in the knowledge base; `diff` gates only on errors in files changed by the pull request. The full report is always posted. |
| `report-style` | `compact` | Layout of the validation section: `compact` (one bullet per diagnostic, remediation help collapsed), `table` (one row per diagnostic), or `detailed` (per-file grouping with object_id/help sub-bullets). |
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

## What it does

1. Installs the pinned `adoc` binary from GitHub Releases (sha256-verified).
2. Builds the Graph Artifact (`adoc build --no-embeddings`).
3. Runs `adoc check` (Strict Mode validation) — diagnostics become file/line
   annotations via a problem matcher, no API calls involved. Paths in the
   report and annotations are repo-relative. Evidence Anchors (`hash:` on
   `source` objects, adoc v0.2.0+) surface here as `evidence.hash_drift`
   warnings when the cited file's bytes changed since verification.
4. Runs the Impacted Query (`adoc impacted-by --ref`) against the PR base and
   derives **Proposed Knowledge Objects**: changed source paths no Knowledge
   Object claims impact over. Impacted objects are also flagged as **drift
   suspicion** — badged `updated in this PR` when the PR touches the object's
   own definition (via `adoc review`) or `unreviewed in this PR` otherwise —
   and a **Contradictions** section lists unresolved authored contradictions
   (`adoc contradictions`) when any exist. Both are deterministic and
   report-only; a future `impacted-enforcement` input could gate on them via
   a second gate file in the Enforce step, but today they never fail the job.
5. When credentials are configured, drafts Knowledge Objects with headless
   Claude Code across three scopes: `create` drafts for uncovered changed
   paths, and `update` drafts for Knowledge Objects whose governed code
   changed or whose fields are expired/overdue. Every draft is applied to a
   sandbox copy of the tree and must pass `adoc check` there; failures are
   listed as rejected, provider errors fall back to the mechanical path list.
6. Delivers validated drafts per `propose-delivery`, upserts one sticky PR
   comment (marker `<!-- adoc:pr-report -->`), and writes the same report to
   the job summary.
7. Fails the job after the comment is posted — in `strict` mode when
   validation found errors, in any mode when adoc could not validate the
   project at all (a broken setup is never reported green), and when
   `propose-on-error: fail` and drafting failed.

## Assessment failure semantics

The report distinguishes a complete assessment, no changed assessable paths,
an unavailable assessment, and malformed internal output. Only a complete
assessment can say that all assessed paths are covered. Missing PR base
metadata, shallow history, a missing Graph Artifact, or malformed impact JSON
is non-green in both enforcement modes and includes remediation in the report.

A structurally invalid current Knowledge Base remains the deliberate exception:
`advisory` stays green and `strict` fails, but impact is reported as unavailable
until the structural errors are fixed. This preserves the existing validation
policy without presenting an unavailable analysis as coverage.

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
| Fork PR (no secrets) | drafting skipped, mechanical report only | same | same |

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
