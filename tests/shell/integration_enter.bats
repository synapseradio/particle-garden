#!/usr/bin/env bats
# End-to-end runs of ./enter against mocked machines: fresh, provisioned,
# partial, and every failure edge the plan names. Each test executes the
# script (never sources it) and reads the mock call logs plus the ledger.

load 'helpers/setup'

setup() {
  isolate_env
  E="${REPO_ROOT}/enter"
  cd "${BATS_TEST_TMPDIR}"
}

# Provisioned machine plus a clone it did not create — a developer Mac that
# already had both.
provisioned_with_clone() {
  mock_macos_provisioned
  make_fake_clone "${ENTER_CLONE_DIR}"
}

# A bare Mac reached the documented way: garden.sh cloned the code and left
# its marker, then ran enter inside the result. enter provisions tools only,
# so every fresh-machine run starts from a clone that already exists.
fresh_with_clone() {
  mock_macos_fresh
  make_fake_clone "${ENTER_CLONE_DIR}"
  mark_clone_created_by_garden "${ENTER_CLONE_DIR}"
}

count_action() {
  awk -F'\t' -v a="$1" '$2 == a' "${ENTER_STATE_DIR}/ledger.tsv" | wc -l | tr -d ' '
}

# bats test_tags=integration
@test "zero-tools machine: full ordered install sequence, interactive brew installer" {
  fresh_with_clone
  run "${E}" --yes --no-run
  assert_success

  assert_called_with xcode-select '(^| )--install'
  run cat "${MOCK_CALLS}/brew-installer-env.log"
  assert_output 'NONINTERACTIVE=absent'
  assert_called_with brew '^install just$'
  assert_called_with brew '^install nim$'
  assert_called_with brew '^install bun$'

  assert_order 'xcode-select --install' 'brew-installer'
  assert_order 'brew-installer' 'brew install just'
  assert_order 'brew install just' 'brew install nim'
  assert_order 'brew install nim' 'brew install bun'

  # enter provisions the Mac and stops there: it fetches no code, resolves no
  # project dependencies, and bypasses none of the just recipes.
  refute_called_with git '^clone'
  refute_called_with git '(^| )(pull|fetch)( |$)'
  refute_called_with nimble '^(install|setup|all|release)'
  refute_called_with bun '^install'

  # every provision is ledgered installed, nothing preexisting
  run awk -F'\t' '$2 == "installed" { print $3 "/" $4 }' "${ENTER_STATE_DIR}/ledger.tsv"
  assert_line 'tool/clt'
  assert_line 'tool/brew'
  assert_line 'tool/just'
  assert_line 'tool/nim'
  assert_line 'tool/bun'
  assert_line 'clone/particle-garden'
  assert_line 'hook/pre-push'
  assert_line 'shellenv/zprofile'
  [ "$(count_action preexisting)" -eq 0 ]
}

# bats test_tags=integration
@test "no clone at the target: enter refuses and names the bootstrap command" {
  mock_macos_provisioned
  run "${E}" --yes --no-run
  [ "${status}" -eq 2 ]
  assert_output --partial "no Particle Garden clone at ${ENTER_CLONE_DIR}"
  assert_output --partial 'tools/garden.sh'
  refute_called_with git '^clone'
}

# bats test_tags=integration
@test "fully provisioned machine: zero installs, one preexisting row per pair" {
  provisioned_with_clone
  run "${E}" --yes --no-run
  assert_success
  refute_called_with brew '(^| )install( |$)'
  refute_called_with xcode-select '(^| )--install'
  refute_called_with git '^clone'
  [ "$(count_action preexisting)" -eq 6 ]
  # the repo treatment still applies to the adopted clone
  assert_file_exist "${ENTER_CLONE_DIR}/.git/hooks/pre-push"
}

# bats test_tags=integration
@test "a second run installs nothing and appends no installed or preexisting rows" {
  fresh_with_clone
  run "${E}" --yes --no-run
  assert_success
  local installs_before installed_rows preexisting_rows
  installs_before="$(grep -c '^install' "${MOCK_CALLS}/brew.log")"
  installed_rows="$(count_action installed)"
  preexisting_rows="$(count_action preexisting)"

  run "${E}" --yes --no-run
  assert_success
  run grep -c '^install' "${MOCK_CALLS}/brew.log"
  assert_output "${installs_before}"
  [ "$(count_action installed)" -eq "${installed_rows}" ]
  [ "$(count_action preexisting)" -eq "${preexisting_rows}" ]
}

# bats test_tags=integration
@test "sticky ledger round trip: two enter runs, then leave still removes everything" {
  fresh_with_clone
  run "${E}" --yes --no-run
  assert_success
  run "${E}" --yes --no-run
  assert_success

  export ENTER_ASSUME_TTY=1
  # clone, then bun/nim/just, then the zprofile block
  run "${REPO_ROOT}/leave" <<< $'y\ny\ny\ny\ny'
  assert_success
  assert_dir_not_exist "${ENTER_CLONE_DIR}"
  assert_called_with brew '^uninstall bun$'
  assert_called_with brew '^uninstall nim$'
  assert_called_with brew '^uninstall just$'
  run grep -cF '# >>> particle-garden enter >>>' "${ENTER_ZPROFILE}"
  assert_failure
}

# bats test_tags=integration
@test "partial machine: only the missing tools are installed" {
  fresh_with_clone
  : > "${MOCK_STATE}/clt"
  mock_tool git
  mock_tool brew
  mock_tool just
  run "${E}" --yes --no-run
  assert_success
  refute_called_with xcode-select '(^| )--install'
  refute_called_with brew '^install just$'
  assert_called_with brew '^install nim$'
  assert_called_with brew '^install bun$'
}

# bats test_tags=integration
@test "declining the first question exits 3 and lists what remains" {
  mock_macos_fresh
  run "${E}" --no-run < /dev/null
  [ "${status}" -eq 3 ]
  assert_output --partial 'Still to do'
  assert_output --partial 'Homebrew'
  assert_output --partial 'just be'
  refute_called_with xcode-select '(^| )--install'
  refute_called git
}

# bats test_tags=integration
@test "dry-run on a fresh machine mutates nothing and writes no ledger" {
  fresh_with_clone
  # A dry run installs no CLT, so the git that reads the clone has to be here
  # already — as it is on any Mac garden.sh has cloned into.
  mock_tool git
  run "${E}" --dry-run
  assert_success
  assert_output --partial 'DRY-RUN'
  assert_file_not_exist "${ENTER_STATE_DIR}/ledger.tsv"
  refute_called_with xcode-select '(^| )--install'
  refute_called brew
  [ ! -f "${ENTER_ZPROFILE}" ]
}

# bats test_tags=integration
@test "dry-run on an existing clone performs no git-config writes and installs no hook" {
  provisioned_with_clone
  run "${E}" --dry-run
  assert_success
  [ ! -s "${ENTER_CLONE_DIR}/.git/config-log" ]
  assert_file_not_exist "${ENTER_CLONE_DIR}/.git/hooks/pre-push"
}

# bats test_tags=integration
@test "accepted fork offer converts the clone in place and installs no hook" {
  provisioned_with_clone
  mock_tool gh
  : > "${MOCK_STATE}/gh-authed"
  export ENTER_ASSUME_TTY=1
  # first answer: persist shellenv; second: the fork offer
  run "${E}" --no-run <<< $'y\ny'
  assert_success
  assert_called_with gh 'repo fork --remote$'
  run cat "${ENTER_CLONE_DIR}/.git/config-log"
  assert_line 'remote.pushDefault origin'
  assert_line 'push.default current'
  assert_file_not_exist "${ENTER_CLONE_DIR}/.git/hooks/pre-push"
}

# bats test_tags=integration
@test "unauthenticated gh: no fork offer, hook installed, never gh auth login" {
  provisioned_with_clone
  mock_tool gh
  run "${E}" --yes --no-run
  assert_success
  assert_called_with gh '^auth status$'
  refute_called_with gh 'auth login'
  refute_called_with gh 'repo fork'
  assert_file_exist "${ENTER_CLONE_DIR}/.git/hooks/pre-push"
}

# bats test_tags=integration
@test "failed fork attempt falls through to the plain treatment" {
  provisioned_with_clone
  mock_tool gh
  : > "${MOCK_STATE}/gh-authed"
  : > "${MOCK_STATE}/gh-fork-fails"
  export ENTER_ASSUME_TTY=1
  run "${E}" --no-run <<< $'y\ny'
  assert_success
  assert_called_with gh 'repo fork --remote$'
  assert_output --partial "didn't go through"
  assert_file_exist "${ENTER_CLONE_DIR}/.git/hooks/pre-push"
}

# bats test_tags=integration
@test "non-macOS exits 4 before touching anything" {
  mock_macos_fresh
  mock_tool uname
  run "${E}" --yes --no-run
  [ "${status}" -eq 4 ]
  assert_output --partial 'only knows macOS'
  assert_output --partial 'https://github.com/synapseradio/particle-garden/releases'
  refute_called_with xcode-select '(^| )--install'
}

# bats test_tags=integration
@test "an incompatible nim is a hard stop naming choosenim, never an install-over" {
  mock_macos_provisioned
  export MOCK_NIM_VERSION='1.6.20'
  run "${E}" --yes --no-run
  [ "${status}" -eq 1 ]
  assert_output --partial 'choosenim'
  assert_output --partial '1.6.20'
  refute_called_with brew '^install nim$'
}

# bats test_tags=integration
@test "a live lock holder means exit 5" {
  provisioned_with_clone
  mkdir -p "${ENTER_STATE_DIR}/particle-garden.lock"
  printf '%s\n' "$$" > "${ENTER_STATE_DIR}/particle-garden.lock/pid"
  run "${E}" --yes --no-run
  [ "${status}" -eq 5 ]
  assert_output --partial 'already running'
}

# bats test_tags=integration
@test "the lock stays held while just be runs" {
  provisioned_with_clone
  run "${E}" --yes
  assert_success
  run cat "${MOCK_CALLS}/just-observed.log"
  assert_output 'lock-held'
}

# bats test_tags=integration
@test "the zprofile block lands exactly once across two runs" {
  provisioned_with_clone
  run "${E}" --yes --no-run
  assert_success
  run "${E}" --yes --no-run
  assert_success
  run grep -cF '# >>> particle-garden enter >>>' "${ENTER_ZPROFILE}"
  assert_output '1'
}

# bats test_tags=integration
@test "--clone-dir beats ENTER_CLONE_DIR" {
  mock_macos_provisioned
  local spot="${BATS_TEST_TMPDIR}/spot-a"
  make_fake_clone "${spot}"
  run "${E}" --yes --no-run --clone-dir "${spot}"
  assert_success
  refute_called_with git '^clone'
  assert_dir_not_exist "${ENTER_CLONE_DIR}"
  run grep -c "${spot}" "${ENTER_STATE_DIR}/ledger.tsv"
  refute_output '0'
}

# bats test_tags=integration
@test "ENTER_CLONE_DIR beats adoption of the script's own directory" {
  mock_macos_provisioned
  local self="${BATS_TEST_TMPDIR}/self-clone"
  make_fake_clone "${self}"
  install_enter_into "${self}"
  # The override names an empty spot, so the refusal is what proves it won:
  # adoption would have found the clone the script is sitting in.
  run "${self}/enter" --yes --no-run
  [ "${status}" -eq 2 ]
  assert_output --partial "no Particle Garden clone at ${ENTER_CLONE_DIR}"
}

# bats test_tags=integration
@test "adoption beats \$PWD/particle-garden when no override is set" {
  mock_macos_provisioned
  local self="${BATS_TEST_TMPDIR}/self-clone"
  make_fake_clone "${self}"
  install_enter_into "${self}"
  unset ENTER_CLONE_DIR
  run "${self}/enter" --yes --no-run
  assert_success
  refute_called_with git '^clone'
  assert_dir_not_exist "${BATS_TEST_TMPDIR}/particle-garden"
  run grep -c "${self}" "${ENTER_STATE_DIR}/ledger.tsv"
  refute_output '0'
}

# bats test_tags=integration
@test "garden.sh's clone marker turns adoption into installed, consumed once" {
  provisioned_with_clone
  mark_clone_created_by_garden "${ENTER_CLONE_DIR}"
  run "${E}" --yes --no-run
  assert_success
  run awk -F'\t' '$3 == "clone" { print $2 }' "${ENTER_STATE_DIR}/ledger.tsv"
  assert_output 'installed'
  assert_file_not_exist "${ENTER_STATE_DIR}/clone-created-by-garden"
}

# bats test_tags=integration
@test "an adopted clone without the marker is ledgered preexisting" {
  provisioned_with_clone
  run "${E}" --yes --no-run
  assert_success
  run awk -F'\t' '$3 == "clone" { print $2 }' "${ENTER_STATE_DIR}/ledger.tsv"
  assert_output 'preexisting'
}

# bats test_tags=integration
@test "guidance prints before just be runs, and carries every pointer" {
  provisioned_with_clone
  run "${E}" --yes
  assert_success
  assert_output --partial 'http://localhost:8089'
  assert_output --partial 'WebGPU'
  assert_output --partial './leave'
  assert_output --partial "cd ${ENTER_CLONE_DIR} && just be"
  local g m
  g="$(printf '%s\n' "${output}" | grep -nF 'localhost:8089' | cut -d: -f1 | head -n 1)"
  m="$(printf '%s\n' "${output}" | grep -nF 'mock-just-be-running' | cut -d: -f1 | head -n 1)"
  [ -n "${g}" ] && [ -n "${m}" ] && [ "${g}" -lt "${m}" ]
}

# bats test_tags=integration
@test "non-TTY output carries no spinner escapes and no carriage returns" {
  provisioned_with_clone
  run "${E}" --yes
  assert_success
  local hide_cursor=$'\033[?25l' carriage=$'\r'
  case "${output}" in
    *"${hide_cursor}"*)
      echo 'output hides the cursor on a non-TTY' >&2
      return 1
      ;;
    *"${carriage}"*)
      echo 'output carries a carriage return on a non-TTY' >&2
      return 1
      ;;
  esac
}

# bats test_tags=integration
@test "a failed just be gets one interpreting line and passes the status through" {
  provisioned_with_clone
  export MOCK_JUST_STATUS=7
  printf ' M src/app.nim\n' > "${ENTER_CLONE_DIR}/.git/status-mock"
  run "${E}" --yes
  [ "${status}" -eq 7 ]
  assert_output --partial 'git stash'
}

# bats test_tags=integration
@test "just be exiting 130 passes through silently" {
  provisioned_with_clone
  export MOCK_JUST_STATUS=130
  run "${E}" --yes
  [ "${status}" -eq 130 ]
  refute_output --partial 'just be stopped'
}
