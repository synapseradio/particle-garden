#!/usr/bin/env bats
# Repo treatment pieces in ./enter: the pre-push guard, gh auth detection,
# and the three gates on ensure_tracking.

load 'helpers/setup'

setup() {
  isolate_env
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/enter"
  load_shared_lib
  mock_tool git
  CLONE_DIR="${ENTER_CLONE_DIR}"
  OWNER_EMAIL="${ENTER_OWNER_EMAIL}"
  make_fake_clone "${CLONE_DIR}"
}

# bats test_tags=unit
@test "install_prepush_hook writes a 0755 hook carrying the owner email and marker" {
  install_prepush_hook
  local hook="${CLONE_DIR}/.git/hooks/pre-push"
  assert_file_exist "${hook}"
  run stat -f '%Lp' "${hook}"
  assert_output '755'
  run grep -c 'owner@example.com' "${hook}"
  assert_output '1'
  run grep -c 'particle-garden' "${hook}"
  assert_output '1'
}

# bats test_tags=unit
@test "the pre-push hook blocks a stranger's email and passes the owner's" {
  install_prepush_hook
  local hook="${CLONE_DIR}/.git/hooks/pre-push"

  export MOCK_GIT_EMAIL='stranger@example.net'
  run "${hook}"
  assert_failure
  assert_output --partial 'fork'

  export MOCK_GIT_EMAIL='owner@example.com'
  run "${hook}"
  assert_success
}

# bats test_tags=unit
@test "have_gh_auth requires gh on PATH and a passing auth status" {
  run have_gh_auth
  assert_failure

  mock_tool gh
  run have_gh_auth
  assert_failure

  : > "${MOCK_STATE}/gh-authed"
  run have_gh_auth
  assert_success
}

# bats test_tags=unit
@test "ensure_tracking no-ops when tracking already resolves" {
  ensure_tracking
  run grep -E 'branch --set-upstream-to' "${MOCK_CALLS}/git.log"
  assert_failure
}

# bats test_tags=unit
@test "ensure_tracking warns and writes nothing when HEAD is not the default branch" {
  rm -f "${CLONE_DIR}/.git/upstream-tracking"
  printf 'install-script\n' > "${CLONE_DIR}/.git/HEAD-branch"
  run ensure_tracking
  assert_success
  assert_output --partial 'leaving it alone'
  refute_called_with git 'branch --set-upstream-to'
}

# bats test_tags=unit
@test "ensure_tracking no-ops under --dry-run" {
  rm -f "${CLONE_DIR}/.git/upstream-tracking"
  dry_run=true
  run ensure_tracking
  assert_success
  refute_called_with git 'branch --set-upstream-to'
}

# bats test_tags=unit
@test "install_prepush_hook skips a linked worktree with a warning" {
  printf '%s\n' "/main-repo/.git/worktrees/clone" > "${CLONE_DIR}/.git/gitdir-override"
  run install_prepush_hook
  assert_success
  assert_output --partial 'worktree'
  assert_file_not_exist "${CLONE_DIR}/.git/hooks/pre-push"
}
