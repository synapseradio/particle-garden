# The spinner, and the step runner that wraps a command in one.
#
# shellcheck shell=bash
# shellcheck disable=SC2329

# The running loop's pid, and the message it is showing. Empty means stopped.
SPINNER_PID=''
SPINNER_ACTIVE=''

#######################################
# The spinner runs only around proven-non-interactive commands, and degrades
# to plain log lines when stderr is not a TTY, under --verbose, or --dry-run.
# ENTER_FORCE_SPINNER overrides the TTY check (test seam).
#######################################
function spinner_enabled() {
  if [ -n "${verbose-}" ] || [ -n "${dry_run-}" ]; then
    return 1
  fi
  if [ -n "${ENTER_FORCE_SPINNER-}" ]; then
    return 0
  fi
  [ -t 2 ]
}

#######################################
# Starts the spinner with a message, or logs one plain line when disabled.
# Frames are indexed from an array, never sliced with ${var:i:1} — substring
# slicing is locale-dependent in bash 3.2 and shreds UTF-8 under a C locale.
#######################################
function spinner_start() {
  local msg="$1"

  if ! spinner_enabled; then
    log 'INFO' "${msg}" "${C_INFO-}"
    return 0
  fi

  spinner_stop

  local frames
  case "${LC_ALL-}${LC_CTYPE-}${LANG-}" in
    *UTF-8* | *utf8*) frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') ;;
    *) frames=('|' '/' '-' "\\") ;;
  esac

  printf '\033[?25l' >&2
  (
    # errtrace propagates the ERR trap into subshells — disarm everything the
    # parent armed before looping forever.
    trap - ERR
    # INT only. A Ctrl-C at the terminal reaches the whole foreground group, and
    # the parent's INT handler needs the spinner still alive to clean up after.
    # TERM stays deliverable: spinner_stop sends it.
    trap '' INT
    set +o errexit
    set +o nounset
    set +o pipefail
    local i=0
    SECONDS=0
    while :; do
      printf '\r%s %s (%d:%02d)\033[K' "${frames[$((i % ${#frames[@]}))]}" \
        "${msg}" "$((SECONDS / 60))" "$((SECONDS % 60))" >&2
      i=$((i + 1))
      sleep 0.1
    done
  ) &
  SPINNER_PID=$!
  SPINNER_ACTIVE="${msg}"
}

#######################################
# Stops the spinner, reaps the background loop (silencing "Terminated"),
# clears the line, and restores the cursor. Idempotent.
#######################################
function spinner_stop() {
  if [ -z "${SPINNER_PID-}" ]; then
    return 0
  fi

  kill "${SPINNER_PID}" 2>/dev/null || true

  # SIGTERM, a second of grace, then SIGKILL. `wait` on a process that ignores
  # its signal never returns, and this runs inside the INT handler, so a loop
  # that survives its signal takes the whole installer down with it.
  # The block redirect swallows bash 3.2's async "Terminated: 15" job notice.
  {
    local waited=0
    while kill -0 "${SPINNER_PID}" 2>/dev/null; do
      if [ "${waited}" -ge 10 ]; then
        kill -9 "${SPINNER_PID}" 2>/dev/null || true
        break
      fi
      sleep 0.1
      waited=$((waited + 1))
    done
  } 2>/dev/null

  wait "${SPINNER_PID}" 2>/dev/null || true
  printf '\r\033[K\033[?25h' >&2
  SPINNER_PID=''
  SPINNER_ACTIVE=''
}

#######################################
# Swaps the spinner message (reassurance updates during long waits).
#######################################
function spinner_message() {
  if [ "$1" = "${SPINNER_ACTIVE-}" ]; then
    return 0
  fi
  spinner_start "$1"
}

#######################################
# Runs a command under the spinner and returns its status, so callers branch
# on the result instead of the ERR trap firing mid-spin.
#######################################
function with_spinner() {
  local msg="$1"
  shift
  local st=0
  # $- carries errexit; restoring it rather than setting it keeps a caller
  # that never enabled errexit from acquiring it here.
  local flags="$-"
  spinner_start "${msg}"
  set +o errexit
  "$@"
  st=$?
  case "${flags}" in *e*) set -o errexit ;; esac
  spinner_stop
  return "${st}"
}

#######################################
# Where a step's output is copied, so a failure can show its tail.
#######################################
function step_log_path() {
  printf '%s\n' "$(state_dir)/step.log"
}

#######################################
# Empties the step log. Called once per run, so a failure tail can only ever
# show output from the run the reader is looking at.
#######################################
function step_log_reset() {
  mkdir -p "$(state_dir)"
  : > "$(step_log_path)"
}

#######################################
# Appends a command's output to the step log, leaving the screen alone.
#######################################
function step_logged() {
  "$@" >> "$(step_log_path)" 2>&1
}

#######################################
# Runs one install step. Its output streams to the screen and into the step
# log at once; --quiet trades the stream for a spinner and prints the log's
# tail only when the step fails.
# Returns the command's status — never tee's, which succeeds regardless.
#######################################
function run_step() {
  local msg="$1"
  shift
  mkdir -p "$(state_dir)"
  local st=0

  if [ -n "${quiet-}" ]; then
    with_spinner "${msg}" step_logged "$@" || st=$?
    if [ "${st}" -ne 0 ]; then
      log 'ERROR' "${msg} failed. The last lines of output:" "${C_ERROR-}"
      tail -n 30 "$(step_log_path)" >&2 || true
    fi
    return "${st}"
  fi

  log 'INFO' "${msg}" "${C_INFO-}"
  # Streaming costs the command its TTY, so brew and bun print plain lines
  # instead of redrawing progress bars. The log gains what the screen loses.
  local flags="$-"
  set +o errexit
  "$@" 2>&1 | tee -a "$(step_log_path)"
  st="${PIPESTATUS[0]}"
  case "${flags}" in *e*) set -o errexit ;; esac
  return "${st}"
}

# vim: ft=bash ts=2 sw=2 sts=2 et
