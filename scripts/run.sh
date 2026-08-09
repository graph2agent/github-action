#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'graph2agent action: %s\n' "$1" >&2
  exit 2
}

binary=${GRAPH2AGENT_BINARY:-}
operation=${GRAPH2AGENT_OPERATION:-}
target_path=${GRAPH2AGENT_PATH:-}
profile=${GRAPH2AGENT_PROFILE:-}

[[ -n "$binary" && -x "$binary" ]] || fail "GRAPH2AGENT_BINARY must be an executable file"
case "$operation" in
  update | check) ;;
  *) fail "operation must be update or check" ;;
esac
case "$profile" in
  compact | standard | exhaustive | readable-v1 | interpreted-v1 | interpreted-v2 | interpreted-v3) ;;
  *) fail "unsupported profile" ;;
esac
[[ -n "$target_path" ]] || fail "path must not be empty"
[[ "$target_path" != -* ]] || fail "path must not begin with a hyphen"
[[ "$target_path" != *$'\n'* && "$target_path" != *$'\r'* ]] || fail "path contains a line break"
case "$target_path" in
  /* | ~* | *\\* | ../* | */../* | */..) fail "path must stay within GITHUB_WORKSPACE" ;;
esac
[[ -e "$target_path" ]] || fail "path does not exist"
[[ ! -L "$target_path" ]] || fail "path must not be a symbolic link"

workspace=${GITHUB_WORKSPACE:-$PWD}
[[ -d "$workspace" ]] || fail "GITHUB_WORKSPACE must name an existing directory"
workspace=$(cd "$workspace" && pwd -P)
if [[ -d "$target_path" ]]; then
  resolved=$(cd "$target_path" && pwd -P)
else
  target_parent=$(cd "$(dirname "$target_path")" && pwd -P)
  resolved=${target_parent}/$(basename "$target_path")
fi
case "$resolved" in
  "$workspace" | "$workspace"/*) ;;
  *) fail "path resolves outside GITHUB_WORKSPACE" ;;
esac

"$binary" "$operation" --profile "$profile" "$target_path"

if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  printf 'operation=%s\n' "$operation" >>"$GITHUB_OUTPUT"
fi
