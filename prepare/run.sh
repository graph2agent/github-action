#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'graph2agent prepare: %s\n' "$1" >&2
  exit 2
}

binary=${GRAPH2AGENT_PREPARE_BINARY:-}
workspace_input=${GRAPH2AGENT_PREPARE_WORKSPACE:-}
target_path=${GRAPH2AGENT_PREPARE_PATH:-}
profile=${GRAPH2AGENT_PREPARE_PROFILE:-}
branch=${GRAPH2AGENT_PREPARE_BRANCH:-}
artifact_directory=${GRAPH2AGENT_PREPARE_ARTIFACT_DIRECTORY:-}
runner_temp_input=${RUNNER_TEMP:-}
github_workspace_input=${GITHUB_WORKSPACE:-}
github_output=${GITHUB_OUTPUT:-}

[[ "$binary" == /* && -x "$binary" && ! -L "$binary" ]] ||
  fail "binary must be an absolute, executable, non-symlink file"
[[ -n "$workspace_input" && -d "$workspace_input" && ! -L "$workspace_input" ]] ||
  fail "workspace must be an existing, non-symlink directory"
[[ -n "$github_workspace_input" && -d "$github_workspace_input" ]] ||
  fail "GITHUB_WORKSPACE must be an existing directory"
[[ -n "$runner_temp_input" && -d "$runner_temp_input" ]] ||
  fail "RUNNER_TEMP must be an existing directory"
[[ -n "$github_output" ]] || fail "GITHUB_OUTPUT is required"

github_workspace=$(cd "$github_workspace_input" && pwd -P)
workspace=$(cd "$workspace_input" && pwd -P)
runner_temp=$(cd "$runner_temp_input" && pwd -P)
case "$workspace" in
  "$github_workspace" | "$github_workspace"/*) ;;
  *) fail "workspace must stay within GITHUB_WORKSPACE" ;;
esac

[[ "$artifact_directory" == /* ]] || fail "artifact directory must be absolute"
[[ "$artifact_directory" != *$'\n'* && "$artifact_directory" != *$'\r'* ]] ||
  fail "artifact directory contains a line break"
artifact_parent=$(dirname "$artifact_directory")
[[ -d "$artifact_parent" && ! -L "$artifact_parent" ]] ||
  fail "artifact parent must be an existing, non-symlink directory"
artifact_parent=$(cd "$artifact_parent" && pwd -P)
artifact_name=$(basename "$artifact_directory")
[[ -n "$artifact_name" && "$artifact_name" != . && "$artifact_name" != .. ]] ||
  fail "artifact directory name is invalid"
artifact_directory=${artifact_parent}/${artifact_name}
case "$artifact_directory" in
  "$runner_temp"/*) ;;
  *) fail "artifact directory must stay within RUNNER_TEMP" ;;
esac
[[ ! -e "$artifact_directory" && ! -L "$artifact_directory" ]] ||
  fail "artifact directory already exists"

[[ -n "$branch" && "$branch" != *$'\n'* && "$branch" != *$'\r'* ]] ||
  fail "branch is invalid"
case "$branch" in
  refs/* | -* | HEAD | @) fail "branch must be a short branch name" ;;
esac
git check-ref-format --branch "$branch" >/dev/null 2>&1 || fail "branch is invalid"

case "$profile" in
  compact | standard | exhaustive | readable-v1 | interpreted-v1 | interpreted-v2 | interpreted-v3) ;;
  *) fail "unsupported profile" ;;
esac
[[ -n "$target_path" && "$target_path" != -* ]] || fail "path is invalid"
[[ "$target_path" != *$'\n'* && "$target_path" != *$'\r'* ]] || fail "path contains a line break"
case "$target_path" in
  /* | ~* | *\\* | ../* | */../* | */..) fail "path must stay within the caller workspace" ;;
esac

cd "$workspace"
[[ $(git rev-parse --show-toplevel) == "$workspace" ]] || fail "workspace is not a Git worktree root"
[[ $(git symbolic-ref --quiet --short HEAD) == "$branch" ]] ||
  fail "workspace is not on the selected branch"
[[ -z $(git status --porcelain=v1 --untracked-files=all) ]] || fail "workspace is not clean"
[[ -e "$target_path" && ! -L "$target_path" ]] || fail "path does not exist or is a symlink"
if [[ -d "$target_path" ]]; then
  resolved_target=$(cd "$target_path" && pwd -P)
else
  target_parent=$(cd "$(dirname "$target_path")" && pwd -P)
  resolved_target=${target_parent}/$(basename "$target_path")
fi
case "$resolved_target" in
  "$workspace" | "$workspace"/*) ;;
  *) fail "path resolves outside the caller workspace" ;;
esac

assert_safe_git_config() {
  local scope
  for scope in --local --global; do
    if git config "$scope" --name-only --get-regexp \
      '^(credential\.|http\..*\.extraheader$|core\.hooksPath$|core\.fsmonitor$|diff\.external$|filter\.)' \
      >/dev/null 2>&1; then
      fail "workspace contains unsafe Git configuration"
    fi
  done
}
assert_safe_git_config

base_sha=$(git rev-parse HEAD)
git_config_path=$(git rev-parse --git-path config)
git_config_digest=$(sha256sum "$git_config_path")
git_config_digest=${git_config_digest%% *}

"$binary" update --profile "$profile" "$target_path"
"$binary" check --profile "$profile" "$target_path"

[[ $(git rev-parse HEAD) == "$base_sha" ]] || fail "graph2agent changed HEAD"
[[ $(git symbolic-ref --quiet --short HEAD) == "$branch" ]] || fail "graph2agent changed the branch"
assert_safe_git_config
current_config_digest=$(sha256sum "$git_config_path")
current_config_digest=${current_config_digest%% *}
[[ "$current_config_digest" == "$git_config_digest" ]] || fail "graph2agent changed local Git configuration"
git diff --cached --quiet -- || fail "graph2agent unexpectedly staged a change"
if IFS= read -r -d '' _untracked < <(git ls-files --others --exclude-standard -z); then
  fail "graph2agent unexpectedly created an untracked file"
fi
git --no-pager diff --no-ext-diff --no-textconv --check
[[ -z $(git --no-pager diff --no-ext-diff --no-textconv --summary --no-renames) ]] ||
  fail "graph2agent changed a file mode or file identity"

files=0
while IFS= read -r -d '' status && IFS= read -r -d '' path; do
  [[ "$status" == M ]] || fail "only modifications to tracked Markdown files are allowed"
  case "$path" in
    *.md) ;;
    *) fail "graph2agent changed a non-Markdown file" ;;
  esac
  [[ -f "$path" && ! -L "$path" ]] || fail "changed Markdown path is not a regular file"
  ((files += 1))
done < <(git --no-pager diff --no-ext-diff --no-textconv --name-status -z --no-renames)

printf 'base-sha=%s\n' "$base_sha" >>"$github_output"
printf 'files=%d\n' "$files" >>"$github_output"
if ((files == 0)); then
  git diff --quiet -- || fail "an unclassified working-tree change remains"
  printf 'updated=false\n' >>"$github_output"
  printf 'patch-sha256=\n' >>"$github_output"
  printf 'All selected graph2agent annotations are current.\n'
  exit 0
fi

mkdir -m 0700 "$artifact_directory"
patch_path=${artifact_directory}/update.patch
checksum_path=${artifact_directory}/update.patch.sha256
git --no-pager diff --binary --full-index --no-ext-diff --no-textconv --no-renames -- . >"$patch_path"
[[ -s "$patch_path" && -f "$patch_path" && ! -L "$patch_path" ]] || fail "patch was not created"
git apply --check --reverse --binary --whitespace=error-all "$patch_path" ||
  fail "generated patch is not reversible"

patch_digest=$(sha256sum "$patch_path")
patch_digest=${patch_digest%% *}
[[ "$patch_digest" =~ ^[0-9a-f]{64}$ ]] || fail "patch digest is invalid"
printf '%s  update.patch\n' "$patch_digest" >"$checksum_path"
chmod 0600 "$patch_path" "$checksum_path"

printf 'updated=true\n' >>"$github_output"
printf 'patch-sha256=%s\n' "$patch_digest" >>"$github_output"
printf 'Prepared a validated patch for %d Markdown file(s).\n' "$files"
