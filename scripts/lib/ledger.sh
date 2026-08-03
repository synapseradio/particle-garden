# The install ledger: one append-only TSV of what the installer actually did,
# and the readers that turn it back into decisions.
#
# A record is five tab-separated fields:
#   <iso8601> <action> <kind> <name> <detail>
# Actions: run, installed, preexisting, removed, kept, declined, note.
# Readers skip malformed rows (NF != 5) so a hand-mangled line never steers a
# decision. `installed` is sticky — only `removed` supersedes it.
#
# The ledger lives outside the clone, so ./leave still works once the clone
# is gone.
#
# shellcheck shell=bash
# shellcheck disable=SC2329

#######################################
# Resolves the state directory: --state-dir > ENTER_STATE_DIR > XDG default.
#######################################
function state_dir() {
  if [ -n "${opt_state_dir-}" ]; then
    printf '%s\n' "${opt_state_dir}"
  elif [ -n "${ENTER_STATE_DIR-}" ]; then
    printf '%s\n' "${ENTER_STATE_DIR}"
  else
    printf '%s\n' "${XDG_STATE_HOME:-${HOME}/.local/state}/particle-garden"
  fi
}

function ledger_path() {
  printf '%s/ledger.tsv\n' "$(state_dir)"
}

#######################################
# Creates the state dir and ledger, refusing with a chown hint when a past
# sudo run left them root-owned. Appends a session record. No-op on --dry-run.
# Arguments:
#   $1 (required): Session name, i.e. which script opened this run.
#######################################
function ledger_init() {
  local session="$1"

  if [ -n "${dry_run-}" ]; then
    return 0
  fi

  local dir
  dir="$(state_dir)"
  if ! mkdir -p "${dir}" 2>/dev/null || [ ! -w "${dir}" ]; then
    script_exit "The state folder ${dir} isn't writable (a past run with sudo can cause this). Fix it with: sudo chown -R $(id -un) ${dir}" 1
  fi
  touch "$(ledger_path)"
  ledger_append run session "${session}" "pid $$"
}

#######################################
# Appends one 5-field record. Logs instead of writing under --dry-run.
# Detail must never contain a tab.
#######################################
function ledger_append() {
  local action="$1"
  local kind="$2"
  local name="$3"
  local detail="${4-}"

  if [ -n "${dry_run-}" ]; then
    log 'DRY-RUN' "ledger: ${action} ${kind} ${name} ${detail}" "${C_HINT-}"
    return 0
  fi

  local timestamp
  timestamp="$(date +'%Y-%m-%dT%H:%M:%S%z')"
  printf '%s\t%s\t%s\t%s\t%s\n' "${timestamp}" "${action}" "${kind}" "${name}" "${detail}" \
    >> "$(ledger_path)"
}

#######################################
# True when any record with this action exists for (kind, name).
#######################################
function ledger_has() {
  local action="$1"
  local kind="$2"
  local name="$3"
  local lp
  lp="$(ledger_path)"
  if [ ! -f "${lp}" ]; then
    return 1
  fi
  awk -F'\t' -v a="${action}" -v k="${kind}" -v n="${name}" \
    'NF == 5 && $2 == a && $3 == k && $4 == n { found = 1 } END { exit found ? 0 : 1 }' "${lp}"
}

#######################################
# True when (kind, name) has any record at all — the sticky-installed rule's
# guard: preexisting is appended only for unrecorded pairs.
#######################################
function ledger_recorded() {
  local kind="$1"
  local name="$2"
  local lp
  lp="$(ledger_path)"
  if [ ! -f "${lp}" ]; then
    return 1
  fi
  awk -F'\t' -v k="${kind}" -v n="${name}" \
    'NF == 5 && $3 == k && $4 == n { found = 1 } END { exit found ? 0 : 1 }' "${lp}"
}

#######################################
# Prints the last recorded detail for (kind, name); empty when none. Every
# handler that acts on a path re-records that path when it keeps the item, so
# the last detail still names where the item lives.
#######################################
function ledger_detail() {
  local kind="$1"
  local name="$2"
  local lp
  lp="$(ledger_path)"
  if [ ! -f "${lp}" ]; then
    return 0
  fi
  awk -F'\t' -v k="${kind}" -v n="${name}" \
    'NF == 5 && $3 == k && $4 == n { d = $5 } END { print d }' "${lp}"
}

#######################################
# Prints the final state for (kind, name): installed, removed, preexisting,
# or nothing. A later `preexisting` never downgrades `installed`.
#######################################
function ledger_final_state() {
  local kind="$1"
  local name="$2"
  local lp
  lp="$(ledger_path)"
  if [ ! -f "${lp}" ]; then
    return 0
  fi
  awk -F'\t' -v k="${kind}" -v n="${name}" '
    NF == 5 && $3 == k && $4 == n {
      if ($2 == "installed") state = "installed"
      else if ($2 == "removed") state = "removed"
      else if ($2 == "preexisting" && state == "") state = "preexisting"
    }
    END { print state }' "${lp}"
}

#######################################
# Prints the names of a kind whose final state is `installed`, most recent
# first, so removal runs in reverse install order.
#######################################
function ledger_installed_of_kind() {
  local kind="$1"
  local lp
  lp="$(ledger_path)"
  if [ ! -f "${lp}" ]; then
    return 0
  fi
  awk -F'\t' -v k="${kind}" '
    NF == 5 && $3 == k {
      key = $4
      if (!(key in seen)) { seen[key] = ++count; names[count] = key }
      if ($2 == "installed") state[key] = "installed"
      else if ($2 == "removed") state[key] = "removed"
      else if ($2 == "preexisting" && state[key] == "") state[key] = "preexisting"
    }
    END {
      for (i = count; i >= 1; i--) {
        if (state[names[i]] == "installed") print names[i]
      }
    }' "${lp}"
}

#######################################
# Appends `preexisting` only when (kind, name) has no record yet. Anything
# else would let a re-run downgrade `installed` and disarm ./leave.
#######################################
function record_preexisting() {
  local kind="$1"
  local name="$2"
  local detail="${3-}"
  if ! ledger_recorded "${kind}" "${name}"; then
    ledger_append preexisting "${kind}" "${name}" "${detail}"
  fi
}

# vim: ft=bash ts=2 sw=2 sts=2 et
