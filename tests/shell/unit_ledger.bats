#!/usr/bin/env bats
# Ledger semantics in scripts/lib/ledger.sh, the module enter and leave share:
# path precedence, record shape, the sticky `installed` rule, final-state
# computation, and reader robustness.

load 'helpers/setup'

setup() {
  isolate_env
  load_shared_lib
}

# Appends a raw 5-field row, bypassing ledger_append (fixed timestamps keep
# the rows deterministic; readers only care about order).
append_row() {
  printf '%s\t%s\t%s\t%s\t%s\n' "2026-08-01T00:00:00+0000" "$1" "$2" "$3" "${4-}" \
    >> "${ENTER_STATE_DIR}/ledger.tsv"
}

# bats test_tags=unit
@test "state_dir resolves --state-dir over ENTER_STATE_DIR over the XDG default" {
  opt_state_dir="${BATS_TEST_TMPDIR}/flagged"
  run state_dir
  assert_output "${BATS_TEST_TMPDIR}/flagged"

  unset opt_state_dir
  run state_dir
  assert_output "${ENTER_STATE_DIR}"

  unset ENTER_STATE_DIR
  export XDG_STATE_HOME="${BATS_TEST_TMPDIR}/xdg"
  run state_dir
  assert_output "${BATS_TEST_TMPDIR}/xdg/particle-garden"
}

# bats test_tags=unit
@test "ledger_init creates the ledger and appends a session record" {
  rm -rf "${ENTER_STATE_DIR}"
  ledger_init enter
  assert_file_exist "${ENTER_STATE_DIR}/ledger.tsv"
  run ledger_has run session enter
  assert_success
}

# bats test_tags=unit
@test "ledger_append writes one 5-field record" {
  mkdir -p "${ENTER_STATE_DIR}"
  ledger_append installed tool just /opt/homebrew/bin/just
  run awk -F'\t' 'END { print NF }' "${ENTER_STATE_DIR}/ledger.tsv"
  assert_output '5'
  run ledger_has installed tool just
  assert_success
}

# bats test_tags=unit
@test "ledger_append writes nothing under --dry-run" {
  dry_run=true
  run ledger_append installed tool just /opt/homebrew/bin/just
  assert_success
  assert_output --partial 'DRY-RUN'
  assert_file_not_exist "${ENTER_STATE_DIR}/ledger.tsv"
}

# bats test_tags=unit
@test "ledger_has matches only the exact action-kind-name triple" {
  append_row installed tool just /opt/homebrew/bin/just
  run ledger_has installed tool just
  assert_success
  run ledger_has removed tool just
  assert_failure
  run ledger_has installed tool nim
  assert_failure
}

# bats test_tags=unit
@test "ledger_final_state reports installed, and removed supersedes it" {
  append_row installed tool just x
  run ledger_final_state tool just
  assert_output 'installed'
  append_row removed tool just x
  run ledger_final_state tool just
  assert_output 'removed'
}

# bats test_tags=unit
@test "installed is sticky: a later preexisting append attempt changes nothing" {
  append_row installed tool just x
  record_preexisting tool just x
  run ledger_final_state tool just
  assert_output 'installed'
  # record_preexisting appended nothing — the pair was already recorded
  run grep -c 'preexisting' "${ENTER_STATE_DIR}/ledger.tsv"
  assert_output '0'
  # even a raw preexisting row cannot downgrade the final state
  append_row preexisting tool just x
  run ledger_final_state tool just
  assert_output 'installed'
}

# bats test_tags=unit
@test "record_preexisting appends only for unrecorded pairs" {
  record_preexisting tool nim /opt/homebrew/bin/nim
  run ledger_final_state tool nim
  assert_output 'preexisting'
  record_preexisting tool nim /elsewhere/nim
  run grep -c 'preexisting' "${ENTER_STATE_DIR}/ledger.tsv"
  assert_output '1'
}

# bats test_tags=unit
@test "ledger_installed_of_kind emits reverse install order and excludes preexisting" {
  append_row preexisting tool brew x
  append_row installed tool just x
  append_row installed tool nim x
  append_row installed tool bun x
  append_row removed tool bun x
  run ledger_installed_of_kind tool
  assert_line --index 0 'nim'
  assert_line --index 1 'just'
  refute_line 'brew'
  refute_line 'bun'
}

# bats test_tags=unit
@test "spaces in the detail field survive a round trip" {
  mkdir -p "${ENTER_STATE_DIR}"
  ledger_append installed clone particle-garden '/Users/some one/particle garden'
  run ledger_detail clone particle-garden
  assert_output '/Users/some one/particle garden'
}

# bats test_tags=unit
@test "malformed rows are skipped by every reader" {
  append_row installed tool just x
  printf 'garbage line without tabs\n' >> "${ENTER_STATE_DIR}/ledger.tsv"
  printf 'a\tb\tc\n' >> "${ENTER_STATE_DIR}/ledger.tsv"
  run ledger_final_state tool just
  assert_output 'installed'
  run ledger_installed_of_kind tool
  assert_output 'just'
}
