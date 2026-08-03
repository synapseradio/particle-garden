#!/usr/bin/env bats
# Flag parsing, confirm(), maybe_run(), and color gating in ./enter.

load 'helpers/setup'

setup() {
  isolate_env
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/enter"
  load_shared_lib
}

# bats test_tags=unit
@test "enter --help prints usage and exits 0" {
  run "${REPO_ROOT}/enter" --help
  assert_success
  assert_output --partial 'Usage:'
  assert_output --partial '--dry-run'
  assert_output --partial '--clone-dir'
}

# bats test_tags=unit
@test "enter rejects an unknown flag with exit 2" {
  run "${REPO_ROOT}/enter" --frobnicate
  assert_failure 2
  assert_output --partial 'Unknown option'
}

# bats test_tags=unit
@test "color_init disables color under --no-color" {
  no_color=true
  color_init
  [ -z "${C_ERROR}" ]
  [ -z "${C_RESET}" ]
}

# bats test_tags=unit
@test "color_init disables color under NO_COLOR" {
  export NO_COLOR=1
  color_init
  [ -z "${C_ERROR}" ]
  [ -z "${C_RESET}" ]
}

# bats test_tags=unit
@test "confirm takes the default without reading when --yes is set" {
  assume_yes=true
  run confirm 'Install the thing?' y < /dev/null
  assert_success
  run confirm 'Remove the thing?' n < /dev/null
  assert_failure
}

# bats test_tags=unit
@test "confirm declines on a non-TTY stdin and names --yes" {
  run confirm 'Install the thing?' y < /dev/null
  assert_failure
  assert_output --partial -- '--yes'
}

# bats test_tags=unit
@test "maybe_run logs instead of executing under --dry-run" {
  dry_run=true
  local canary="${BATS_TEST_TMPDIR}/canary"
  : > "${canary}"
  run maybe_run rm -f "${canary}"
  assert_success
  assert_output --partial 'DRY-RUN'
  assert_file_exist "${canary}"
}
