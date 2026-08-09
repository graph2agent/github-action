#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/graph2agent-runner-test.XXXXXX")
outside=$(mktemp "${TMPDIR:-/tmp}/graph2agent-runner-outside.XXXXXX")
trap 'rm -rf "$temporary"; rm -f "$outside"' EXIT

target=${temporary}/README\ file.md
log=${temporary}/arguments.bin
output=${temporary}/github-output.txt
printf '# Fixture\n' >"$target"
: >"$output"

(
  cd "$temporary"
  FAKE_GRAPH2AGENT_LOG="$log" \
  GRAPH2AGENT_BINARY="${repo_root}/tests/fixtures/fake-graph2agent" \
  GRAPH2AGENT_OPERATION=update \
  GRAPH2AGENT_PATH='README file.md' \
  GRAPH2AGENT_PROFILE=interpreted-v3 \
  GITHUB_WORKSPACE="$temporary" \
  GITHUB_OUTPUT="$output" \
    "${repo_root}/scripts/run.sh"
)

arguments=()
while IFS= read -r -d '' value; do
  arguments+=("$value")
done <"$log"

[[ ${#arguments[@]} -eq 4 ]]
[[ ${arguments[0]} == update ]]
[[ ${arguments[1]} == --profile ]]
[[ ${arguments[2]} == interpreted-v3 ]]
[[ ${arguments[3]} == 'README file.md' ]]
grep -Fx 'operation=update' "$output" >/dev/null

assert_rejected() {
  local expected=$1
  shift
  : >"$log"
  local captured
  if captured=$(
    cd "$temporary"
    FAKE_GRAPH2AGENT_LOG="$log" \
      GRAPH2AGENT_BINARY="${repo_root}/tests/fixtures/fake-graph2agent" \
      GITHUB_WORKSPACE="$temporary" \
      "$@" "${repo_root}/scripts/run.sh" 2>&1
  ); then
    printf 'expected runner rejection containing %q\n' "$expected" >&2
    exit 1
  fi
  [[ $captured == *"$expected"* ]]
  [[ ! -s "$log" ]]
}

assert_rejected 'operation must be update or check' \
  env GRAPH2AGENT_OPERATION=publish GRAPH2AGENT_PATH="$target" GRAPH2AGENT_PROFILE=interpreted-v3
assert_rejected 'unsupported profile' \
  env GRAPH2AGENT_OPERATION=check GRAPH2AGENT_PATH="$target" GRAPH2AGENT_PROFILE='interpreted-v3; touch bad'
assert_rejected 'path must not begin with a hyphen' \
  env GRAPH2AGENT_OPERATION=check GRAPH2AGENT_PATH=--help GRAPH2AGENT_PROFILE=interpreted-v3
assert_rejected 'path contains a line break' \
  env GRAPH2AGENT_OPERATION=check GRAPH2AGENT_PATH=$'README.md\n--help' GRAPH2AGENT_PROFILE=interpreted-v3
assert_rejected 'path does not exist' \
  env GRAPH2AGENT_OPERATION=check GRAPH2AGENT_PATH=missing.md GRAPH2AGENT_PROFILE=interpreted-v3
assert_rejected 'path must stay within GITHUB_WORKSPACE' \
  env GRAPH2AGENT_OPERATION=check GRAPH2AGENT_PATH=../outside.md GRAPH2AGENT_PROFILE=interpreted-v3
assert_rejected 'path must stay within GITHUB_WORKSPACE' \
  env GRAPH2AGENT_OPERATION=check GRAPH2AGENT_PATH="$outside" GRAPH2AGENT_PROFILE=interpreted-v3
ln -s "$outside" "${temporary}/linked.md"
assert_rejected 'path must not be a symbolic link' \
  env GRAPH2AGENT_OPERATION=check GRAPH2AGENT_PATH=linked.md GRAPH2AGENT_PROFILE=interpreted-v3
ln -s "$(dirname "$outside")" "${temporary}/linked-parent"
assert_rejected 'path resolves outside GITHUB_WORKSPACE' \
  env GRAPH2AGENT_OPERATION=check GRAPH2AGENT_PATH="linked-parent/$(basename "$outside")" GRAPH2AGENT_PROFILE=interpreted-v3

printf 'runner tests passed\n'
