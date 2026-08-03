# Shared BATS setup for the enter / leave / tools/garden.sh suite.
# Every test file starts with:  load 'helpers/setup'
# shellcheck shell=bash

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
export REPO_ROOT

# bats-support / bats-assert / bats-file resolve from BATS_LIB_PATH, then the
# Homebrew prefixes. Install with:
#   brew tap bats-core/bats-core && brew install bats-support bats-assert bats-file
_load_helper_lib() {
  local lib="$1" dir
  for dir in ${BATS_LIB_PATH//:/ } /opt/homebrew/lib /usr/local/lib; do
    if [ -f "${dir}/${lib}/load.bash" ]; then
      load "${dir}/${lib}/load"
      return 0
    fi
  done
  echo "Missing ${lib}. Install with: brew tap bats-core/bats-core && brew install bats-support bats-assert bats-file" >&2
  return 1
}

_load_helper_lib bats-support
_load_helper_lib bats-assert
_load_helper_lib bats-file

# Re-homes everything under BATS_TEST_TMPDIR so no test can touch real state:
# HOME, the state dir, the clone target, the zprofile, the owner email, the
# mock bin/calls/state dirs, and a narrow PATH with mocks first. The exported
# ENTER_CLONE_DIR also keeps enter's adoption rule from ever pointing a test
# at this real repository (whose script dir always looks like a clone).
isolate_env() {
  if [ -z "${BATS_TEST_TMPDIR:-}" ]; then
    echo 'ERROR: not running under BATS' >&2
    return 1
  fi
  export HOME="${BATS_TEST_TMPDIR}/home"
  export ENTER_STATE_DIR="${BATS_TEST_TMPDIR}/state"
  export ENTER_CLONE_DIR="${BATS_TEST_TMPDIR}/clone"
  export ENTER_ZPROFILE="${BATS_TEST_TMPDIR}/home/.zprofile"
  export ENTER_OWNER_EMAIL='owner@example.com'
  export ENTER_BREW_PATHS="${BATS_TEST_TMPDIR}/no-brew-arm/brew:${BATS_TEST_TMPDIR}/no-brew-x86/brew"
  export MOCK_BIN="${BATS_TEST_TMPDIR}/mockbin"
  export MOCK_CALLS="${BATS_TEST_TMPDIR}/calls"
  export MOCK_STATE="${BATS_TEST_TMPDIR}/mockstate"
  export MOCK_PREFIX="${BATS_TEST_TMPDIR}/prefix"
  export PATH="${MOCK_BIN}:/usr/bin:/bin"
  export NO_COLOR=1
  unset ENTER_ASSUME_TTY MOCK_GIT_EMAIL MOCK_NIM_VERSION MOCK_JUST_STATUS XDG_STATE_HOME
  mkdir -p "${HOME}" "${ENTER_STATE_DIR}" "${MOCK_BIN}" "${MOCK_CALLS}" \
    "${MOCK_STATE}" "${MOCK_PREFIX}/bin"
  write_mock_factory
}

# Sources the shared core the way enter and leave do, for unit tests that
# reach one of its functions without going through either script.
load_shared_lib() {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/load.sh"
}

load "${BATS_TEST_DIRNAME}/helpers/mocks"
