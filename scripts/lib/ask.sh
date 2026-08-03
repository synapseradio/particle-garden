# The two ways ./enter and ./leave gate a mutation: a yes/no question, and
# the --dry-run bypass.
#
# shellcheck shell=bash
# shellcheck disable=SC2329

#######################################
# Runs a command unless --dry-run is set, in which case it logs instead.
#######################################
function maybe_run() {
  if [ -n "${dry_run-}" ]; then
    log 'DRY-RUN' "$*" "${C_HINT-}"
    return 0
  fi
  "$@"
}

#######################################
# Asks a yes/no question on the terminal.
# - --dry-run answers yes (nothing will be mutated anyway, and the plan should
#   walk every phase).
# - --yes takes the default answer without asking.
# - A non-TTY stdin declines and names --yes, so a piped run never mutates.
#   ENTER_ASSUME_TTY overrides that check (test seam: lets BATS pipe answers).
# Arguments:
#   $1 (required): The question.
#   $2 (optional): Default answer, 'y' or 'n'; defaults to 'y'.
# Returns: 0 for yes, 1 for no.
#######################################
function confirm() {
  local prompt="$1"
  local default="${2:-y}"

  if [ -n "${dry_run-}" ]; then
    log 'DRY-RUN' "would ask: ${prompt}" "${C_HINT-}"
    return 0
  fi

  if [ -n "${assume_yes-}" ]; then
    if [ "${default}" = 'y' ]; then
      log 'INFO' "${prompt} — yes (--yes)" "${C_INFO-}"
      return 0
    fi
    log 'INFO' "${prompt} — taking the default: no (--yes)" "${C_INFO-}"
    return 1
  fi

  if [ ! -t 0 ] && [ -z "${ENTER_ASSUME_TTY-}" ]; then
    log 'WARN' "There's no terminal to ask on: ${prompt}" "${C_WARN-}"
    log 'WARN' 'Re-run with --yes to accept the defaults automatically.' "${C_WARN-}"
    return 1
  fi

  local suffix='[Y/n]'
  if [ "${default}" = 'n' ]; then
    suffix='[y/N]'
  fi

  local reply
  printf '%s %s ' "${prompt}" "${suffix}" >&2
  read -r reply || reply=''
  case "${reply}" in
    [Yy] | [Yy][Ee][Ss]) return 0 ;;
    '')
      if [ "${default}" = 'y' ]; then
        return 0
      fi
      return 1
      ;;
    *) return 1 ;;
  esac
}

# vim: ft=bash ts=2 sw=2 sts=2 et
