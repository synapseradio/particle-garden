#!/usr/bin/env bash
#
# Particle Garden bootstrap: the one command a fresh Mac runs. Makes sure git
# exists (installing the Xcode Command Line Tools if not), clones the repo,
# and hands off to ./enter with the terminal — and every flag — intact.
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/synapseradio/particle-garden/HEAD/tools/garden.sh)" -- [flags]
#
# Standalone on purpose: it runs before any clone exists, so it defines what
# it needs rather than sourcing scripts/lib. It never writes the ledger — it
# hands facts to enter through two marker files in the state dir, which enter
# consumes exactly once. Everything lives in functions with one guarded main
# at EOF, so a half-downloaded copy fails to parse instead of half-executing.

if [ -z "${BASH_VERSION-}" ]; then exec /bin/bash "$0" "$@"; fi

# nounset only when executed — no errexit: every failure here is handled by
# hand so the message stays friendly. Never active when sourced (BATS).
if ! (return 0 2>/dev/null); then
  set -o nounset
fi

REPO_URL='https://github.com/synapseradio/particle-garden'
TARGET=''
OPT_CLONE_DIR=''
OPT_STATE_DIR=''
DRY_RUN=''
ASSUME_YES=''
FWD_ARGS=()

function usage() {
  cat <<'EOF'
Particle Garden bootstrap for macOS.

Usage: garden.sh [options]

Makes sure git exists (installing Apple's Command Line Tools if needed),
downloads Particle Garden, then hands off to its installer, ./enter. All
options are passed through to enter as well.

Options:
  -h, --help            Show this help and exit.
      --dry-run         Show what would happen without changing anything.
      --yes             Skip the questions and accept the defaults.
      --clone-dir <path>  Where the Particle Garden code goes
                          (default: ./particle-garden).
      --state-dir <path>  Where the install ledger lives
                          (default: ~/.local/state/particle-garden).

Anything else (e.g. --no-run, --verbose) is forwarded to enter untouched.

Exit codes:
  0 done · 1 a step failed · 2 the target directory is in the way ·
  3 declined · 4 not macOS.
EOF
}

#######################################
# Answers "does Particle Garden already live here?" by reading the predicate
# out of the candidate itself. is_clone has one home, scripts/lib/clone.sh,
# and a directory missing that file is not a clone — so the absence answers
# the question without a second copy of the body living here. Reading from
# TARGET adds no trust this script does not already extend: it is about to
# exec TARGET/enter.
#######################################
function have_clone_at() {
  local dir="$1"
  if [ ! -f "${dir}/scripts/lib/clone.sh" ]; then
    return 1
  fi
  # shellcheck source=scripts/lib/clone.sh
  . "${dir}/scripts/lib/clone.sh"
  is_clone "${dir}"
}

#######################################
# Resolves the state directory the same way enter does:
# --state-dir > ENTER_STATE_DIR > XDG default.
#######################################
function state_dir() {
  if [ -n "${OPT_STATE_DIR}" ]; then
    printf '%s\n' "${OPT_STATE_DIR}"
  elif [ -n "${ENTER_STATE_DIR-}" ]; then
    printf '%s\n' "${ENTER_STATE_DIR}"
  else
    printf '%s\n' "${XDG_STATE_HOME:-${HOME}/.local/state}/particle-garden"
  fi
}

#######################################
# Parses the flags whose semantics precede enter, while keeping the full
# argument list for forwarding — without this, a cautious user appending
# --dry-run to the one-liner would get a multi-GB CLT install before enter
# ever saw the flag. `--` (the one-liner's $0 placeholder spill) is dropped.
#######################################
function parse_params() {
  local param
  while [ $# -gt 0 ]; do
    param="$1"
    shift
    case "${param}" in
      -h | --help)
        usage
        exit 0
        ;;
      --dry-run)
        DRY_RUN=1
        FWD_ARGS+=("${param}")
        ;;
      --yes)
        ASSUME_YES=1
        FWD_ARGS+=("${param}")
        ;;
      --clone-dir)
        if [ $# -lt 1 ]; then
          printf -- '--clone-dir needs a path after it.\n' >&2
          exit 2
        fi
        OPT_CLONE_DIR="$1"
        FWD_ARGS+=("${param}" "$1")
        shift
        ;;
      --state-dir)
        if [ $# -lt 1 ]; then
          printf -- '--state-dir needs a path after it.\n' >&2
          exit 2
        fi
        OPT_STATE_DIR="$1"
        FWD_ARGS+=("${param}" "$1")
        shift
        ;;
      --)
        ;;
      *)
        FWD_ARGS+=("${param}")
        ;;
    esac
  done
}

#######################################
# Resolves the clone target by the same precedence enter uses, minus
# adoption (there is no script directory to adopt — this script arrived
# through curl): --clone-dir > ENTER_CLONE_DIR > ./particle-garden.
#######################################
function resolve_target() {
  if [ -n "${OPT_CLONE_DIR}" ]; then
    TARGET="${OPT_CLONE_DIR}"
  elif [ -n "${ENTER_CLONE_DIR-}" ]; then
    TARGET="${ENTER_CLONE_DIR}"
  else
    TARGET="${PWD}/particle-garden"
  fi
}

function need_clt() {
  ! command -v git >/dev/null 2>&1
}

#######################################
# Installs the Xcode Command Line Tools via Apple's GUI installer and polls
# with no timeout — the download is big and the window may hide behind
# others. Deliberately duplicates enter's minimal loop; enter still owns the
# ledger, so the truth is handed over via the clt marker file.
#######################################
function ensure_git() {
  if ! need_clt; then
    return 0
  fi

  printf 'Asking Apple to install the Command Line Tools (compiler and git)…\n' >&2
  xcode-select --install 2>/dev/null || true
  printf 'An install window opened — it may be hiding behind other windows. Click Install there.\n' >&2

  local waited=0
  until xcode-select -p >/dev/null 2>&1 && command -v git >/dev/null 2>&1; do
    sleep 5
    waited=$((waited + 5))
    if [ $((waited % 60)) -eq 0 ]; then
      printf 'Still waiting on the Command Line Tools installer (about %s min so far — big download, no rush)…\n' "$((waited / 60))" >&2
    fi
  done
  hash -r

  mkdir -p "$(state_dir)"
  : > "$(state_dir)/clt-installed-by-garden"
}

#######################################
# Hands the terminal to enter with every flag forwarded. exec — garden.sh
# has nothing left to do, and enter must own the TTY.
#######################################
function handoff() {
  chmod +x "${TARGET}/enter" "${TARGET}/leave" 2>/dev/null || true
  exec "${TARGET}/enter" ${FWD_ARGS[@]+"${FWD_ARGS[@]}"}
}

function main() {
  parse_params "$@"

  if [ "$(uname -s)" != 'Darwin' ]; then
    printf '%s\n' \
      "Particle Garden's installer only knows macOS. On Windows or Linux you do not need it:" \
      'download the ready-to-run app from https://github.com/synapseradio/particle-garden/releases' \
      'and follow the steps at https://github.com/synapseradio/particle-garden#windows' >&2
    exit 4
  fi

  resolve_target

  if have_clone_at "${TARGET}"; then
    printf 'Particle Garden is already at %s — handing off to its installer.\n' "${TARGET}" >&2
    if [ -n "${DRY_RUN}" ]; then
      printf 'DRY-RUN would run: %s/enter\n' "${TARGET}" >&2
      exit 0
    fi
    handoff
  fi

  if [ -e "${TARGET}" ]; then
    printf "There's already something at %s that doesn't look like a Particle Garden clone. Move it aside, or pick another spot with --clone-dir <path>.\n" "${TARGET}" >&2
    exit 2
  fi

  if [ -n "${DRY_RUN}" ]; then
    if need_clt; then
      printf 'DRY-RUN would install: the Xcode Command Line Tools (Apple opens its own install window).\n' >&2
    else
      printf 'DRY-RUN git is already here — no Command Line Tools install needed.\n' >&2
    fi
    printf 'DRY-RUN would download Particle Garden to: %s\n' "${TARGET}" >&2
    printf 'DRY-RUN would then hand off to: %s/enter (which asks before each of its own steps)\n' "${TARGET}" >&2
    exit 0
  fi

  # One consent before any mutation. enter asks again before each of its own
  # steps; this covers only what garden.sh itself is about to do.
  printf 'This will%s download Particle Garden to %s, then start its installer (which asks before each step).\n' \
    "$(if need_clt; then printf " install Apple's Command Line Tools, then"; fi)" "${TARGET}" >&2
  if [ -z "${ASSUME_YES}" ]; then
    if [ ! -t 0 ] && [ -z "${ENTER_ASSUME_TTY-}" ]; then
      printf 'There is no terminal to ask on. Run again with --yes to accept, or from an interactive shell.\n' >&2
      exit 3
    fi
    local reply
    printf 'Sound good? [Y/n] ' >&2
    read -r reply || reply=''
    case "${reply}" in
      '' | [Yy] | [Yy][Ee][Ss]) ;;
      *)
        printf 'Stopping here — nothing was changed. Run the command again any time.\n' >&2
        exit 3
        ;;
    esac
  fi

  ensure_git

  printf 'Downloading Particle Garden to %s…\n' "${TARGET}" >&2
  if ! git clone "${REPO_URL}" "${TARGET}"; then
    printf "The download didn't finish — check your connection and run the command again.\n" >&2
    exit 1
  fi

  mkdir -p "$(state_dir)"
  printf '%s\n' "${TARGET}" > "$(state_dir)/clone-created-by-garden"

  handoff
}

# Invoke main only when executed directly, never when sourced — and never
# when the download was cut short, since a truncated file has no main call.
if ! (return 0 2>/dev/null); then
  main "$@"
fi

# vim: ft=bash ts=2 sw=2 sts=2 et
