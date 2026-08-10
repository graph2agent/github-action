# graph2agent GitHub automation

This private repository provides a composite GitHub Action and reusable
workflows for checking or updating deterministic graph2agent annotations in
Markdown. The composite action installs one exact private core tag, runs the
requested operation, and stops. It never commits, pushes, opens a pull request,
or changes Git credentials on disk. Publication is isolated in one explicitly
write-capable reusable workflow.

## Composite action

```yaml
permissions:
  contents: read

steps:
  - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
    with:
      persist-credentials: false
  - uses: graph2agent/github-action@<audited-40-character-commit-sha>
    with:
      token: ${{ secrets.GRAPH2AGENT_READ_TOKEN }}
      version: v0.1.0
      operation: check
      path: .
      profile: interpreted-v3
```

For a controlled working-tree update, set `operation: update`. The caller then
decides how to inspect or publish the diff. This action deliberately performs
no Git publication step.

### Inputs

| Input | Default | Contract |
| --- | --- | --- |
| `token` | required | Read-only access to the private core repository. |
| `version` | `v0.1.0` | Exact SemVer tag; branches, ranges, and `latest` are rejected. |
| `operation` | `check` | Exactly `check` or `update`. |
| `path` | `.` | One repository-relative file or directory; traversal, symlink targets, leading hyphens, and line breaks are rejected. |
| `profile` | `interpreted-v3` | One supported deterministic narrative profile. |
| `go-version` | `1.25.x` | Toolchain used only for installation. |

Outputs are the ephemeral binary path, exact installed version, and validated
operation. The binary lives under `RUNNER_TEMP` and should not be cached or
published.

## Read-only reusable workflow

[`check-markdown.yml`](.github/workflows/check-markdown.yml) is callable by
other repositories and has only `contents: read`. A successful call exports
`checked=true` and the exact core version. See
[`examples/reusable-check.yml`](examples/reusable-check.yml).

## Write-capable reusable workflow

[`update-markdown.yml`](.github/workflows/update-markdown.yml) updates every
selected `.md` file, verifies the generated annotations, commits the resulting
Markdown-only diff, and performs a normal non-force push. Its default `path: .`
selects the caller repository recursively; its default empty `branch` selects
the caller repository's default branch.

The caller must deliberately grant `contents: write` and pass its unique
read-only core deploy key as `GRAPH2AGENT_DEPLOY_KEY`. Reusable workflows cannot
elevate a caller token. The workflow separates generation from publication:

1. `prepare` has only `contents: read`. It checks out the exact private core
   tag with the deploy key, builds and runs it, verifies the result, and uploads
   a checksummed binary patch containing only modifications to tracked regular
   `.md` files.
2. `publish` starts on a fresh runner with `contents: write`. It receives no
   core credential and runs no core code. A separately SHA-pinned publisher
   verifies and reapplies the patch against its exact base, independently
   repeats the Markdown-only checks, commits with hooks disabled, and performs
   one normal push with the short-lived caller `GITHUB_TOKEN`.

Every checkout disables persisted credentials. Staged, untracked, renamed,
added, deleted, mode-changing, symlink, and non-`.md` changes are rejected. An
ephemeral masked authorization header is passed only to `git push`. A concurrent
update or repository rule therefore fails the push instead of being bypassed.
The workflow never force-pushes, changes branch protection, or opens a pull
request.

Call the workflow only from a trusted event such as `workflow_dispatch`,
`schedule`, or a protected-branch push. Do not invoke a write-capable workflow
with untrusted pull-request code. Pin the reusable workflow to an audited full
commit SHA. See [`examples/reusable-update.yml`](examples/reusable-update.yml).

### Update inputs and outputs

| Input | Default | Contract |
| --- | --- | --- |
| `path` | `.` | Existing repository-relative Markdown file or directory. |
| `profile` | `interpreted-v3` | One supported deterministic narrative profile. |
| `graph2agent-version` | `v0.1.0` | Exact private core SemVer tag. |
| `branch` | empty | Existing short branch name; empty selects the caller default branch. |
| `commit-message` | `docs: refresh graph2agent annotations` | Non-empty, single-line message of at most 200 characters. |

The workflow returns `updated`, `files-changed`, `commit-sha`, and `branch`.
`commit-sha` is empty when all selected annotations were already current.

## Private-organization access

The composite action and read-only reusable check currently use
`GRAPH2AGENT_READ_TOKEN`. Create it as a fine-grained personal access token or
GitHub App installation token with:

- access only to `graph2agent/graph2agent`;
- repository permission `Contents: read` and no write permissions;
- an expiration and an owner responsible for rotation.

Store it as an organization or repository Actions secret. The caller
repository's `GITHUB_TOKEN` does not normally grant access to a different
private repository.

The installer removes the raw token from its environment, derives a Basic
authorization header in memory, and supplies that header only through
`GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0` for the single
`go install` process. It does not run `git config`, add credentials to a remote
URL, use a credential helper, print the token, or persist it in a file.

The write-capable reusable workflow does not accept that token. Give each
caller repository a distinct read-only deploy key for
`graph2agent/graph2agent`, store the private half only as the repository secret
`GRAPH2AGENT_DEPLOY_KEY`, and keep the public half registered on the core
repository with write access disabled. The key is available only in `prepare`;
it is not uploaded with the patch or passed to `publish`.

Private Actions sharing must also be enabled for this repository in the
organization settings. Pin this action or reusable workflow to a reviewed full
commit SHA even when the repository is private.

## Examples

- [`action-check.yml`](examples/action-check.yml): direct read-only check.
- [`action-update-for-review.yml`](examples/action-update-for-review.yml):
  manual working-tree update that prints/fails on the resulting diff and does
  not publish it.
- [`reusable-check.yml`](examples/reusable-check.yml): reusable read-only check.
- [`reusable-update.yml`](examples/reusable-update.yml): trusted-event,
  Markdown-only commit and non-force push.

The all-zero references in examples are deliberate invalid placeholders. A
consumer must replace each with an audited commit SHA.

## Development

```sh
make check
```

The test suite uses fake `go` and `graph2agent` executables. It verifies exact
arguments, rejects unsafe input, checks that credentials are environment-only,
tests the reusable update workflow's request/diff/commit/push boundaries, and
confirms that captured output contains no test token. CI pins external Actions
by full SHA and installs an exact actionlint release.
