# Colour palette and the logging front end, shared by ./enter and ./leave.
# Human output goes to stderr; stdout carries only what a script produces.
#
# shellcheck shell=bash
# Functions here are called from the sourcing scripts, which shellcheck cannot
# see from this file.
# shellcheck disable=SC2329

#######################################
# Initialises colour variables (Open Color palette, 24-bit ANSI). Honours
# --no-color, NO_COLOR, and a non-TTY stderr — human output goes to stderr
# through log(), so stderr is the stream that matters.
#######################################
# shellcheck disable=SC2034
function color_init() {
  local enable_color=true

  if [ -n "${no_color-}" ] || [ -n "${NO_COLOR-}" ]; then
    enable_color=false
  elif [ ! -t 2 ]; then
    enable_color=false
  fi

  if [ "${enable_color}" = true ]; then
    readonly C_RESET=$'\033[0m'
    readonly C_BOLD=$'\033[1m'
    readonly C_DIM=$'\033[2m'
    readonly C_UNDERLINE=$'\033[4m'
    readonly C_ERROR=$'\033[38;2;240;62;62m'    # red-7    #f03e3e
    readonly C_WARN=$'\033[38;2;253;126;20m'    # orange-6 #fd7e14
    readonly C_SUCCESS=$'\033[38;2;55;178;77m'  # green-7  #37b24d
    readonly C_INFO=$'\033[38;2;25;113;194m'    # blue-7   #1971c2
    readonly C_HINT=$'\033[38;2;134;142;150m'   # gray-6   #868e96
    readonly C_HEADER=$'\033[38;2;16;152;173m'  # cyan-7   #1098ad
  else
    readonly C_RESET=''
    readonly C_BOLD=''
    readonly C_DIM=''
    readonly C_UNDERLINE=''
    readonly C_ERROR=''
    readonly C_WARN=''
    readonly C_SUCCESS=''
    readonly C_INFO=''
    readonly C_HINT=''
    readonly C_HEADER=''
  fi
}

#######################################
# Prints a message to stderr. Timestamps appear only under --verbose so the
# default output reads human-first.
# Arguments:
#   $1 (required): Severity tag, e.g. INFO, WARN, ERROR, DRY-RUN.
#   $2 (required): Message body.
#   $3 (optional): Colour escape sequence for the tag.
#######################################
function log() {
  local severity="$1"
  local message="$2"
  local color="${3-}"
  local prefix=''

  if [ -n "${verbose-}" ]; then
    local timestamp
    timestamp="$(date +'%Y-%m-%dT%H:%M:%S%z')"
    prefix="[${timestamp}] "
  fi

  printf '%s%b%s%b %s\n' "${prefix}" "${color}" "${severity}" "${C_RESET-}" "${message}" >&2
}

#######################################
# Logs an INFO line only under --verbose.
#######################################
function verbose_log() {
  if [ -n "${verbose-}" ]; then
    log 'INFO' "$1" "${C_INFO-}"
  fi
}

# vim: ft=bash ts=2 sw=2 sts=2 et
