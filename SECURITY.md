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

Do not use the action with write-capable secrets on workflows triggered by
untrusted forks. Pin both the action and reusable workflow by full commit SHA.
Review dependency-SHA changes and the exact core tag before merging them.

The included composite action and reusable workflow do not commit, push, or
open pull requests. `operation: update` changes only the runner working tree;
publication remains outside this repository's current trust boundary.
