#!/usr/bin/env bats
# tools/garden.sh: the curl-able bootstrap. Flag parsing before any mutation,
# the consent gate, the marker handshake with enter, and the truncation-safe
# file shape shared by all three scripts.

load 'helpers/setup'

setup() {
  isolate_env
  G="${REPO_ROOT}/tools/garden.sh"
  export MOCK_UNAME=Darwin
  mock_tool uname
  cd "${BATS_TEST_TMPDIR}"
}

# bats test_tags=bootstrap
@test "--dry-run prints the intent and mutates nothing" {
  run "${G}" --dry-run
  assert_success
  assert_output --partial 'DRY-RUN would download Particle Garden to'
  assert_dir_not_exist "${ENTER_CLONE_DIR}"
  assert_file_not_exist "${ENTER_STATE_DIR}/clt-installed-by-garden"
  assert_file_not_exist "${ENTER_STATE_DIR}/clone-created-by-garden"
}

# bats test_tags=bootstrap
@test "--help exits 0 before any mutation" {
  run "${G}" --help
  assert_success
  assert_output --partial 'Usage'
  assert_dir_not_exist "${ENTER_CLONE_DIR}"
}

# bats test_tags=bootstrap
@test "the consent gate declines on a non-TTY without --yes, exit 3, nothing mutated" {
  mock_tool git
  run "${G}" < /dev/null
  [ "${status}" -eq 3 ]
  assert_output --partial '--yes'
  refute_called_with git '^clone'
  assert_dir_not_exist "${ENTER_CLONE_DIR}"
}

# bats test_tags=bootstrap
@test "--clone-dir picks the clone target and is forwarded to enter" {
  mock_tool git
  local spot="${BATS_TEST_TMPDIR}/spot"
  run "${G}" --yes --clone-dir "${spot}"
  assert_success
  assert_called_with git "^clone https://github.com/synapseradio/particle-garden ${spot}$"
  run cat "${ENTER_STATE_DIR}/clone-created-by-garden"
  assert_output "${spot}"
  assert_called_with fake-enter "^--yes --clone-dir ${spot}$"
}

# bats test_tags=bootstrap
@test "an existing clone at the target skips the clone and forwards every flag" {
  mock_tool git
  make_fake_clone "${ENTER_CLONE_DIR}"
  make_fake_enter "${ENTER_CLONE_DIR}"
  run "${G}" --yes --no-run --state-dir "${ENTER_STATE_DIR}"
  assert_success
  assert_output --partial 'already at'
  refute_called_with git '^clone'
  assert_called_with fake-enter "^--yes --no-run --state-dir ${ENTER_STATE_DIR}$"
}

# bats test_tags=bootstrap
@test "a directory in the way that is not a clone is refused with exit 2" {
  mock_tool git
  mkdir -p "${ENTER_CLONE_DIR}"
  run "${G}" --yes
  [ "${status}" -eq 2 ]
  assert_output --partial "doesn't look like a Particle Garden clone"
}

# bats test_tags=bootstrap
@test "a non-macOS machine is refused with exit 4" {
  export MOCK_UNAME=Linux
  run "${G}" --yes
  [ "${status}" -eq 4 ]
  assert_output --partial 'only knows macOS'
}

# bats test_tags=bootstrap
@test "truncation-safe shape: no top-level statement but the guarded main, and sh re-execs" {
  local s
  for s in enter leave tools/garden.sh; do
    run awk '
      /^[[:space:]]*(#.*)?$/ { next }
      infunc { if ($0 == "}") infunc = 0; next }
      ingate { if ($0 == "fi") ingate = 0; next }
      /^function [A-Za-z_][A-Za-z0-9_]*\(\) \{$/ { infunc = 1; next }
      /^if ! \(return 0 2>\/dev\/null\); then$/ { ingate = 1; next }
      /^if \[ -z "\$\{BASH_VERSION-\}" \]; then exec \/bin\/bash "\$0" "\$@"; fi$/ { next }
      /^if \[\[ .*DEBUG.* \]\]; then set -o xtrace; fi$/ { next }
      /^[A-Za-z_][A-Za-z0-9_]*=/ { next }
      { print FILENAME ":" FNR ": " $0; bad = 1 }
      END { exit bad }
    ' "${REPO_ROOT}/${s}"
    assert_success
    # the guarded main call is present at EOF
    run tail -n 5 "${REPO_ROOT}/${s}"
    assert_output --partial 'main "$@"'
  done

  run sh "${REPO_ROOT}/enter" --help
  assert_success
  run sh "${G}" --help
  assert_success
}

# bats test_tags=bootstrap
@test "markers land where enter will look, including under a forwarded --state-dir" {
  mock_tool xcode-select
  mock_tool sleep
  local sd="${BATS_TEST_TMPDIR}/forwarded-state"
  # /usr/bin is off PATH, so git only exists once the mock CLT install lands
  run env PATH="${MOCK_BIN}:/bin" "${G}" --yes --state-dir "${sd}"
  assert_success
  assert_called_with xcode-select '(^| )--install'
  assert_file_exist "${sd}/clt-installed-by-garden"
  run cat "${sd}/clone-created-by-garden"
  assert_output "${ENTER_CLONE_DIR}"
  assert_called_with fake-enter "^--yes --state-dir ${sd}$"
}
