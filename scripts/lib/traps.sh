# Path setup, the exit paths, and the trap handlers ./enter and ./leave arm.
#
# Each script names its own failure reporter in TRAP_ERR_REPORT: the function
# script_trap_err calls to say what was underway when things broke. Leave it
# empty to fail silently.
#
# shellcheck shell=bash
# shellcheck disable=SC2329

# Set by script_exit before it routes a deliberate failure through the error
# trap, so the trap knows not to report it as a surprise.
EXPECTED_EXIT=''

#######################################
# Initialises path variables. Call once from main() before anything reads
# ${script_dir} or ${script_name}. The caller passes its own ${BASH_SOURCE[0]}
# — read from here it would name this library instead.
# Arguments:
#   $1 (required): Path of the calling script.
#   $@ (rest):     That script's own arguments.
# Globals (set): orig_cwd, script_path, script_dir, script_name, script_params
#######################################
# shellcheck disable=SC2034
function script_init() {
  readonly script_path="$1"
  shift
  readonly orig_cwd="${PWD}"
  readonly script_params="$*"
  script_dir="$(dirname "${script_path}")"
  script_name="$(basename "${script_path}")"
  readonly script_dir script_name
}

#######################################
# Handles unexpected errors: stops the spinner, lets the script's own reporter
# explain what was underway, and exits with the supplied code.
# Arguments:
#   $1 (optional): Numeric exit code; defaults to 1.
# Globals (read): TRAP_ERR_REPORT, EXPECTED_EXIT
#######################################
function script_trap_err() {
  local exit_code=1

  trap - ERR
  set +o errexit
  set +o pipefail
  spinner_stop

  if [[ ${1-} =~ ^[0-9]+$ ]]; then
    exit_code="$1"
  fi

  if [ -z "${EXPECTED_EXIT-}" ] && [ -n "${TRAP_ERR_REPORT-}" ]; then
    "${TRAP_ERR_REPORT}"
  fi

  exit "${exit_code}"
}

#######################################
# Handles every exit: stops the spinner, releases the lock, restores the
# original working directory, and resets terminal color state.
#######################################
function script_trap_exit() {
  spinner_stop
  cd "${orig_cwd:-/}" 2>/dev/null || true

  if [ -n "${LOCK_DIR-}" ] && [ -d "${LOCK_DIR}" ]; then
    rm -rf "${LOCK_DIR}"
  fi

  printf '%b' "${C_RESET-}" >&2
}

#######################################
# Exits with a message. A nonzero second argument routes through the error
# trap so cleanup matches an unexpected failure.
# Arguments:
#   $1 (required): Message to print (stderr).
#   $2 (optional): Numeric exit code; defaults to 0.
#######################################
function script_exit() {
  if [ $# -eq 1 ]; then
    printf '%s\n' "$1" >&2
    exit 0
  fi

  if [[ ${2-} =~ ^[0-9]+$ ]]; then
    printf '%b\n' "$1" >&2
    if [ "$2" -ne 0 ]; then
      EXPECTED_EXIT=1
      script_trap_err "$2"
    fi
    exit 0
  fi

  script_exit 'Missing required argument to script_exit()!' 2
}

# vim: ft=bash ts=2 sw=2 sts=2 et
