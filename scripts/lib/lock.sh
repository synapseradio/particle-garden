# The single-instance lock ./enter and ./leave share.
#
# shellcheck shell=bash
# shellcheck disable=SC2329

# The lock this process holds, released by script_trap_exit. Empty means none.
LOCK_DIR=''

#######################################
# Acquires the lock. Stale locks (dead pid) are broken; a live holder exits 5.
# enter holds it across `just be` — releasing earlier would let a second enter
# start a concurrent build that corrupts the staticRead inputs mid-build, and
# leave would be uninstalling under a live install.
# Globals (set): LOCK_DIR
#######################################
function acquire_lock() {
  if [ -n "${dry_run-}" ]; then
    return 0
  fi

  local lock
  lock="$(state_dir)/particle-garden.lock"

  if ! mkdir "${lock}" 2>/dev/null; then
    local pid
    pid="$(cat "${lock}/pid" 2>/dev/null || true)"
    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      script_exit "A garden is being installed or is already running (process ${pid}). Finish or stop that one first." 5
    fi
    rm -rf "${lock}"
    if ! mkdir "${lock}" 2>/dev/null; then
      script_exit "Couldn't take the lock at ${lock}." 5
    fi
  fi

  printf '%s\n' "$$" > "${lock}/pid"
  # script_trap_exit, over in traps.sh, is what releases it.
  # shellcheck disable=SC2034
  LOCK_DIR="${lock}"
}

# vim: ft=bash ts=2 sw=2 sts=2 et
