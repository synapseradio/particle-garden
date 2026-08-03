#!/usr/bin/env bats
# Detection helpers in ./enter: nim version gate, dispatch indirection,
# compute_plan, brew prefix writability, and the shared is_clone predicate.

load 'helpers/setup'

setup() {
  isolate_env
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/enter"
  load_shared_lib
}

# bats test_tags=unit
@test "nim_version_ok accepts 2.x and rejects 1.x, 3.x, and garbage" {
  mock_tool nim

  export MOCK_NIM_VERSION='2.2.10'
  run nim_version_ok
  assert_success

  export MOCK_NIM_VERSION='1.6.20'
  run nim_version_ok
  assert_failure

  export MOCK_NIM_VERSION='3.0.0'
  run nim_version_ok
  assert_failure

  mock_bin nim 0 'not a version line at all'
  run nim_version_ok
  assert_failure
}

# bats test_tags=unit
@test "phase_dispatch calls phase_<id>_<verb> by name" {
  phase_zz_detect() { printf 'dispatched\n'; }
  run phase_dispatch zz detect
  assert_success
  assert_output 'dispatched'
}

# bats test_tags=unit
@test "compute_plan marks every phase missing on a bare machine" {
  mock_bin xcode-select 2
  mock_bin xcrun 1
  CLONE_DIR="${ENTER_CLONE_DIR}"
  compute_plan
  local entry
  for entry in "${PLAN[@]}"; do
    case "${entry}" in
      *:missing) ;;
      *)
        echo "expected every entry missing, got: ${entry}" >&2
        return 1
        ;;
    esac
  done
  [ "${#PLAN[@]}" -eq 6 ]
}

# bats test_tags=unit
@test "compute_plan marks every phase present on a provisioned machine" {
  mock_macos_provisioned
  make_fake_clone "${ENTER_CLONE_DIR}"
  CLONE_DIR="${ENTER_CLONE_DIR}"
  compute_plan
  local entry
  for entry in "${PLAN[@]}"; do
    case "${entry}" in
      *:present) ;;
      *)
        echo "expected every entry present, got: ${entry}" >&2
        return 1
        ;;
    esac
  done
}

# bats test_tags=unit
@test "brew_prefix_writable follows the prefix's bin permissions" {
  mock_tool brew
  run brew_prefix_writable
  assert_success
  chmod 555 "${MOCK_PREFIX}/bin"
  run brew_prefix_writable
  assert_failure
  chmod 755 "${MOCK_PREFIX}/bin"
}

# bats test_tags=unit
@test "is_clone accepts a worktree .git file and rejects partial or non-repos" {
  mock_tool git

  # worktree-style clone: .git is a file, marker files present
  local wt="${BATS_TEST_TMPDIR}/wt"
  mkdir -p "${wt}"
  printf 'gitdir: /somewhere/.git/worktrees/wt\n' > "${wt}/.git"
  : > "${wt}/particle_garden.nimble"
  : > "${wt}/justfile"
  run is_clone "${wt}"
  assert_success

  # missing justfile
  local nj="${BATS_TEST_TMPDIR}/nj"
  mkdir -p "${nj}/.git"
  : > "${nj}/particle_garden.nimble"
  run is_clone "${nj}"
  assert_failure

  # missing nimble file
  local nn="${BATS_TEST_TMPDIR}/nn"
  mkdir -p "${nn}/.git"
  : > "${nn}/justfile"
  run is_clone "${nn}"
  assert_failure

  # not a repository at all
  local nr="${BATS_TEST_TMPDIR}/nr"
  mkdir -p "${nr}"
  : > "${nr}/particle_garden.nimble"
  : > "${nr}/justfile"
  run is_clone "${nr}"
  assert_failure
}
