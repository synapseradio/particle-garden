#!/usr/bin/env bats
# End-to-end runs of ./leave against a hand-built ledger and matching
# artifacts: the removal guards, the keep defaults, and the summary contract.

load 'helpers/setup'

setup() {
  isolate_env
  L="${REPO_ROOT}/leave"
  cd "${BATS_TEST_TMPDIR}"
  mock_tool git
  mock_tool brew
  mock_tool nimble
}

# Appends one raw 5-field ledger row (fixed timestamp; readers only order).
row() {
  printf '%s\t%s\t%s\t%s\t%s\n' '2026-08-01T00:00:00+0000' "$1" "$2" "$3" "${4-}" \
    >> "${ENTER_STATE_DIR}/ledger.tsv"
}

# The ledger a full zero-tools enter run leaves behind.
standard_ledger() {
  row run session enter 'pid 1'
  row installed tool clt /Library/Developer/CommandLineTools
  row installed tool brew "${MOCK_BIN}/brew"
  row installed shellenv zprofile "${ENTER_ZPROFILE}"
  row installed tool just "${MOCK_BIN}/just"
  row installed tool nim "${MOCK_BIN}/nim"
  row installed tool bun "${MOCK_BIN}/bun"
  row installed clone particle-garden "${ENTER_CLONE_DIR}"
  row installed hook pre-push "${ENTER_CLONE_DIR}/.git/hooks/pre-push"
}

# The artifacts those records point at.
standard_artifacts() {
  make_fake_clone "${ENTER_CLONE_DIR}"
  mkdir -p "${ENTER_CLONE_DIR}/.git/hooks"
  printf '#!/bin/sh\n# particle-garden guard\nexit 0\n' \
    > "${ENTER_CLONE_DIR}/.git/hooks/pre-push"
  chmod 755 "${ENTER_CLONE_DIR}/.git/hooks/pre-push"
  {
    printf 'export BEFORE=1\n'
    printf '%s\n' '# >>> particle-garden enter >>>'
    printf 'eval "$(brew shellenv)"\n'
    printf '%s\n' '# <<< particle-garden enter <<<'
    printf 'export AFTER=1\n'
  } > "${ENTER_ZPROFILE}"
}

# bats test_tags=integration
@test "--yes removes the clone and the zprofile block, keeps the tools, records both" {
  standard_ledger
  standard_artifacts
  run "${L}" --yes
  assert_success
  assert_dir_not_exist "${ENTER_CLONE_DIR}"
  run grep -cF '# >>> particle-garden enter >>>' "${ENTER_ZPROFILE}"
  assert_failure
  assert_file_exist "${ENTER_ZPROFILE}.particle-garden.bak"
  run awk -F'\t' '$2 == "removed" { print $3 "/" $4 }' "${ENTER_STATE_DIR}/ledger.tsv"
  assert_line 'clone/particle-garden'
  assert_line 'shellenv/zprofile'
  run awk -F'\t' '$2 == "kept" { print $4 }' "${ENTER_STATE_DIR}/ledger.tsv"
  assert_line 'just'
  assert_line 'nim'
  assert_line 'bun'
  refute_called_with brew '^uninstall'
}

# bats test_tags=integration
@test "leave never uninstalls Homebrew or the CLT, even when everything else goes" {
  standard_ledger
  standard_artifacts
  export ENTER_ASSUME_TTY=1
  run "${L}" <<< $'y\ny\ny\ny\ny\ny'
  assert_success
  refute_called_with brew '^uninstall brew'
  refute_called_with brew '^uninstall clt'
  assert_called_with brew '^uninstall bun$'
  assert_called_with brew '^uninstall nim$'
  assert_called_with brew '^uninstall just$'
  assert_output --partial 'stay put'
}

# bats test_tags=integration
@test "preexisting records are never removed" {
  row run session enter 'pid 1'
  row preexisting tool just "${MOCK_BIN}/just"
  row installed tool nim "${MOCK_BIN}/nim"
  export ENTER_ASSUME_TTY=1
  run "${L}" <<< $'y'
  assert_success
  assert_called_with brew '^uninstall nim$'
  refute_called_with brew '^uninstall just$'
}

# bats test_tags=integration
@test "--keep protects named items even against an explicit yes" {
  standard_ledger
  standard_artifacts
  export ENTER_ASSUME_TTY=1
  run "${L}" --keep nim,zprofile <<< $'y\ny\ny\ny\ny'
  assert_success
  refute_called_with brew '^uninstall nim$'
  assert_called_with brew '^uninstall bun$'
  run awk -F'\t' '$2 == "kept" && $5 == "protected by --keep" { print $4 }' \
    "${ENTER_STATE_DIR}/ledger.tsv"
  assert_line 'nim'
  assert_line 'zprofile'
}

# bats test_tags=integration
@test "a ledgered path that fails is_clone is refused" {
  row run session enter 'pid 1'
  row installed clone particle-garden "${ENTER_CLONE_DIR}"
  mkdir -p "${ENTER_CLONE_DIR}"
  printf 'precious\n' > "${ENTER_CLONE_DIR}/data.txt"
  run "${L}" --yes
  assert_success
  assert_output --partial "doesn't look like a Particle Garden clone"
  assert_file_exist "${ENTER_CLONE_DIR}/data.txt"
}

# bats test_tags=integration
@test "a linked git worktree is refused" {
  row run session enter 'pid 1'
  row installed clone particle-garden "${ENTER_CLONE_DIR}"
  make_fake_clone "${ENTER_CLONE_DIR}"
  printf '/main-repo/.git/worktrees/clone\n' > "${ENTER_CLONE_DIR}/.git/gitdir-override"
  run "${L}" --yes
  assert_success
  assert_output --partial 'linked git worktree'
  assert_dir_exist "${ENTER_CLONE_DIR}"
}

# bats test_tags=integration
@test "the zprofile block is excised with a backup, neighbors byte-identical" {
  row run session enter 'pid 1'
  row installed shellenv zprofile "${ENTER_ZPROFILE}"
  standard_artifacts
  local original
  original="$(cat "${ENTER_ZPROFILE}")"
  run "${L}" --yes
  assert_success
  run cat "${ENTER_ZPROFILE}"
  assert_output $'export BEFORE=1\nexport AFTER=1'
  run cat "${ENTER_ZPROFILE}.particle-garden.bak"
  assert_output "${original}"
}

# bats test_tags=integration
@test "the hook is removed on its own when the clone is kept" {
  standard_ledger
  standard_artifacts
  export ENTER_ASSUME_TTY=1
  # keep the clone, remove the hook, keep everything else
  run "${L}" <<< $'n\ny\nn\nn\nn\nn\nn'
  assert_success
  assert_dir_exist "${ENTER_CLONE_DIR}"
  assert_file_not_exist "${ENTER_CLONE_DIR}/.git/hooks/pre-push"
}

# bats test_tags=integration
@test "no ledger means nothing to undo, exit 0" {
  run "${L}"
  assert_success
  assert_output --partial 'Nothing recorded'
}

# bats test_tags=integration
@test "dry-run removes nothing and leaves the ledger untouched" {
  standard_ledger
  standard_artifacts
  local sum_before
  sum_before="$(cksum "${ENTER_STATE_DIR}/ledger.tsv")"
  run "${L}" --dry-run
  assert_success
  assert_output --partial 'Dry run'
  assert_dir_exist "${ENTER_CLONE_DIR}"
  assert_file_exist "${ENTER_CLONE_DIR}/.git/hooks/pre-push"
  run grep -cF '# >>> particle-garden enter >>>' "${ENTER_ZPROFILE}"
  assert_output '1'
  [ "$(cksum "${ENTER_STATE_DIR}/ledger.tsv")" = "${sum_before}" ]
}

# bats test_tags=integration
@test "run from inside the clone: removal succeeds and the summary says cd ~" {
  standard_ledger
  standard_artifacts
  cd "${ENTER_CLONE_DIR}"
  run "${L}" --yes
  cd "${BATS_TEST_TMPDIR}"
  assert_success
  assert_dir_not_exist "${ENTER_CLONE_DIR}"
  assert_output --partial 'cd ~'
}

# bats test_tags=integration
@test "a ledgered clone that is already gone is recorded and the run continues" {
  standard_ledger
  # artifacts minus the clone itself
  {
    printf '%s\n' '# >>> particle-garden enter >>>'
    printf 'eval "$(brew shellenv)"\n'
    printf '%s\n' '# <<< particle-garden enter <<<'
  } > "${ENTER_ZPROFILE}"
  run "${L}" --yes
  assert_success
  assert_output --partial 'already gone'
  # the sequence continued: the zprofile block still came out
  run grep -cF '# >>> particle-garden enter >>>' "${ENTER_ZPROFILE}"
  assert_failure
  run awk -F'\t' '$2 == "removed" && $3 == "clone" { print $5 }' \
    "${ENTER_STATE_DIR}/ledger.tsv"
  assert_output 'already gone'
}

# bats test_tags=integration
@test "the summary buckets every installed record exactly once" {
  standard_ledger
  standard_artifacts
  run "${L}" --yes
  assert_success
  # removed
  assert_output --partial 'the Particle Garden folder'
  assert_output --partial 'the Homebrew setup block'
  # removed with the folder
  assert_output --partial 'the push guard (pre-push hook) — removed with the folder'
  # kept
  assert_output --partial 'the Xcode Command Line Tools — stays by design'
  assert_output --partial 'Homebrew — stays by design'
  assert_output --partial 'just — kept'
  assert_output --partial 'nim — kept'
  assert_output --partial 'bun — kept'
  # standing notes
  assert_output --partial 'leave never removes them'
  assert_output --partial 'left as-is'
}

# bats test_tags=integration
@test "a package row from an older ledger is named and kept" {
  standard_ledger
  standard_artifacts
  row installed pkg webui 'webui@#552a3e3'
  run "${L}" --yes
  assert_success
  assert_output --partial "webui — kept (leave doesn't know how to remove it)"
  refute_called_with nimble '^uninstall'
}

# bats test_tags=integration
@test "leave on a non-macOS machine exits 4" {
  standard_ledger
  standard_artifacts
  mock_tool uname
  run "${L}" --yes
  [ "${status}" -eq 4 ]
  assert_output --partial 'only knows macOS'
  assert_output --partial 'https://github.com/synapseradio/particle-garden/releases'
}
