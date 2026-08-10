# Security policy

## Supported versions

Only the latest tagged release is supported while this repository is private.
Report suspected vulnerabilities before enabling the action in additional
repositories.

## Reporting

Use GitHub's private vulnerability reporting for this repository. Do not open a
public issue containing credentials, private repository names, workflow logs,
or an exploit transcript. Include the action commit SHA, core tag, runner OS,
and the smallest safe reproduction.

## Credential boundary

`GRAPH2AGENT_READ_TOKEN` must be read-only and scoped solely to the private core
repository. The installer passes an authorization header through ephemeral Git
configuration environment variables for one `go install` command. It must
never be placed in a URL, command trace, cache, artifact, output, Git config, or
credential helper.

`GRAPH2AGENT_DEPLOY_KEY` is the reusable update workflow's separate core-read
credential. Every caller must use a unique key whose public half is registered
on the core repository with write access disabled. The private half is used
only by the read-only `prepare` job and must never enter the patch artifact or
the publisher job.

Do not use the action or write-capable reusable workflow on events that execute
untrusted fork code. Pin both the action and reusable workflow by full commit
SHA. Review dependency-SHA changes and the exact core tag before merging them.

The composite action and `check-markdown.yml` do not commit, push, or open pull
requests. `operation: update` changes only the runner working tree.

`update-markdown.yml` is the sole publication boundary. Its core-running
`prepare` job has only `contents: read`; its fresh `publish` job alone receives
`contents: write`, never receives the core key, and never runs core code. The
jobs exchange only a checksummed patch artifact. The publisher implementation
is independently pinned by full commit SHA, revalidates that the patch modifies
only existing regular `.md` files, creates one bot-authored commit with hooks
disabled, and performs a normal non-force push using an ephemeral authorization
header. It persists no credential, opens no pull request, and neither modifies
nor bypasses branch protection. Repository rules and concurrent updates are
expected to reject a disallowed or non-fast-forward push.
