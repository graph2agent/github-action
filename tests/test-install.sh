#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/graph2agent-install-test.XXXXXX")
trap 'rm -rf "$temporary"' EXIT

fake_path=${temporary}/bin
mkdir -p "$fake_path"
cp "${repo_root}/tests/fixtures/fake-go" "${fake_path}/go"
chmod +x "${fake_path}/go"

go_log=${temporary}/go-arguments.bin
github_output=${temporary}/github-output.txt
test_token='private-test-token-never-print'
: >"$github_output"

captured=$(PATH="${fake_path}:$PATH" \
  FAKE_GO_LOG="$go_log" \
  FAKE_GRAPH2AGENT_FIXTURE="${repo_root}/tests/fixtures/fake-graph2agent" \
  EXPECT_PRIVATE_AUTH=true \
  EXPECTED_TEST_TOKEN="$test_token" \
  GRAPH2AGENT_READ_TOKEN="$test_token" \
  GRAPH2AGENT_VERSION=v0.4.0 \
  RUNNER_TEMP="$temporary" \
  GITHUB_OUTPUT="$github_output" \
  "${repo_root}/scripts/install.sh" 2>&1)

[[ $captured == *'Installed graph2agent v0.4.0'* ]]
[[ $captured != *"$test_token"* ]]
[[ $(tr '\0' '\n' <"$go_log") == $'install\ngithub.com/graph2agent/graph2agent/cmd/graph2agent@v0.4.0' ]]
[[ $(grep -c '^binary=' "$github_output") -eq 1 ]]
grep -Fx 'version=v0.4.0' "$github_output" >/dev/null
[[ $(<"$github_output") != *"$test_token"* ]]
installed_binary=$(sed -n 's/^binary=//p' "$github_output")
[[ -x "$installed_binary" ]]

for invalid_version in main latest v1 v1.2 v01.2.3 v1.02.3 v1.2.03 v1.2.3-01 v1.2.3-; do
  if PATH="${fake_path}:$PATH" \
    FAKE_GO_LOG="$go_log" \
    FAKE_GRAPH2AGENT_FIXTURE="${repo_root}/tests/fixtures/fake-graph2agent" \
    EXPECT_PRIVATE_AUTH=true \
    EXPECTED_TEST_TOKEN="$test_token" \
    GRAPH2AGENT_READ_TOKEN="$test_token" \
    GRAPH2AGENT_VERSION="$invalid_version" \
    RUNNER_TEMP="$temporary" \
    GITHUB_OUTPUT="$github_output" \
    "${repo_root}/scripts/install.sh" >/dev/null 2>&1; then
    printf 'install accepted invalid version %q\n' "$invalid_version" >&2
    exit 1
  fi
done

public_output=${temporary}/public-output.txt
: >"$public_output"
public_captured=$(PATH="${fake_path}:$PATH" \
  FAKE_GO_LOG="$go_log" \
  FAKE_GRAPH2AGENT_FIXTURE="${repo_root}/tests/fixtures/fake-graph2agent" \
  EXPECT_PRIVATE_AUTH=false \
  GRAPH2AGENT_VERSION=v0.4.0 \
  RUNNER_TEMP="$temporary" \
  GITHUB_OUTPUT="$public_output" \
  "${repo_root}/scripts/install.sh" 2>&1)
[[ $public_captured == *'Installed graph2agent v0.4.0'* ]]
[[ $(tr '\0' '\n' <"$go_log") == $'install\ngithub.com/graph2agent/graph2agent/cmd/graph2agent@v0.4.0' ]]
grep -Fx 'version=v0.4.0' "$public_output" >/dev/null

printf 'install tests passed\n'
