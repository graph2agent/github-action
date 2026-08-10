#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'graph2agent install: %s\n' "$1" >&2
  exit 2
}

command -v go >/dev/null 2>&1 || fail "Go is not available on PATH"

version=${GRAPH2AGENT_VERSION:-}
token=${GRAPH2AGENT_READ_TOKEN:-}
runner_temp=${RUNNER_TEMP:-}
github_output=${GITHUB_OUTPUT:-}
unset GRAPH2AGENT_READ_TOKEN

[[ "$token" != *$'\n'* && "$token" != *$'\r'* ]] || fail "read token contains a line break"
semver_pattern='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
[[ "$version" =~ $semver_pattern ]] ||
  fail "version must be an exact SemVer tag such as v0.1.0"
[[ -n "$runner_temp" && -d "$runner_temp" ]] || fail "RUNNER_TEMP must name an existing directory"
[[ "$runner_temp" != *$'\n'* && "$runner_temp" != *$'\r'* ]] || fail "RUNNER_TEMP contains a line break"
[[ -n "$github_output" ]] || fail "GITHUB_OUTPUT is required"

install_root=$(mktemp -d "${runner_temp%/}/graph2agent-action.XXXXXX")
bin_dir=${install_root}/bin
mkdir -p "$bin_dir"

if [[ -n "$token" ]]; then
  command -v base64 >/dev/null 2>&1 || fail "base64 is not available on PATH"
  # Private-preview compatibility: Git reads this authorization header only
  # from the child process environment. Nothing is written to Git config.
  basic_auth=$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\r\n')
  unset token
  GOBIN="$bin_dir" \
  GOTOOLCHAIN=local \
  GOPRIVATE='github.com/graph2agent/*' \
  GONOPROXY='github.com/graph2agent/*' \
  GONOSUMDB='github.com/graph2agent/*' \
  GIT_TERMINAL_PROMPT=0 \
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0='http.https://github.com/.extraheader' \
  GIT_CONFIG_VALUE_0="AUTHORIZATION: basic ${basic_auth}" \
    go install "github.com/graph2agent/graph2agent/cmd/graph2agent@${version}"
  unset basic_auth
else
  unset token
  GOBIN="$bin_dir" \
  GOTOOLCHAIN=local \
  GIT_TERMINAL_PROMPT=0 \
    go install "github.com/graph2agent/graph2agent/cmd/graph2agent@${version}"
fi

binary=${bin_dir}/graph2agent
[[ -x "$binary" ]] || fail "go install did not produce an executable graph2agent binary"

printf 'binary=%s\n' "$binary" >>"$github_output"
printf 'version=%s\n' "$version" >>"$github_output"
printf 'Installed graph2agent %s in an ephemeral runner directory.\n' "$version"
