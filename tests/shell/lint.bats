#!/usr/bin/env bats
# Static checks over the three scripts and the library they share: syntax
# under modern and stock bash, shellcheck, the bash-3.2 banned-construct list,
# executable shape, and the byte-identity of the shared is_clone predicate.

load 'helpers/setup'

SCRIPTS=(enter leave tools/garden.sh)
LIBS=(
  scripts/lib/load.sh
  scripts/lib/output.sh
  scripts/lib/traps.sh
  scripts/lib/ask.sh
  scripts/lib/spinner.sh
  scripts/lib/ledger.sh
  scripts/lib/lock.sh
  scripts/lib/clone.sh
  scripts/lib/shellenv.sh
)

# bats test_tags=lint
@test "bash -n parses every script and library file" {
  local s
  for s in "${SCRIPTS[@]}" "${LIBS[@]}"; do
    run bash -n "${REPO_ROOT}/${s}"
    assert_success
  done
}

# bats test_tags=lint
@test "/bin/bash -n parses every script and library file under stock bash 3.2" {
  if ! /bin/bash --version 2>/dev/null | grep -q 'version 3\.2'; then
    skip '/bin/bash is not 3.2 on this machine'
  fi
  local s
  for s in "${SCRIPTS[@]}" "${LIBS[@]}"; do
    run /bin/bash -n "${REPO_ROOT}/${s}"
    assert_success
  done
}

# bats test_tags=lint
@test "shellcheck is clean at -S style" {
  if ! command -v shellcheck > /dev/null 2>&1; then
    skip 'shellcheck not installed (dev-machine tool)'
  fi
  cd "${REPO_ROOT}"
  run shellcheck -s bash -S style -x "${SCRIPTS[@]}" "${LIBS[@]}"
  assert_success
}

# bats test_tags=lint
@test "no bash-3.2-breaking construct appears outside comments" {
  local banned='declare -A|declare -g|mapfile|readarray|\$\{[A-Za-z_]+,,|\$\{[A-Za-z_]+\^\^|wait -n|sed -i|date -d|date -I|globstar|readlink -f|grep -P'
  local s hits
  for s in "${SCRIPTS[@]}" "${LIBS[@]}"; do
    hits="$(grep -v '^[[:space:]]*#' "${REPO_ROOT}/${s}" | grep -En "${banned}" || true)"
    if [ -n "${hits}" ]; then
      echo "banned construct in ${s}:" >&2
      echo "${hits}" >&2
      return 1
    fi
  done
}

# bats test_tags=lint
@test "each script is executable and starts with the env-bash shebang" {
  local s
  for s in "${SCRIPTS[@]}"; do
    [ -x "${REPO_ROOT}/${s}" ]
    run head -n 1 "${REPO_ROOT}/${s}"
    assert_output '#!/usr/bin/env bash'
  done
}

# bats test_tags=lint
@test "each library file is sourced, never run: no shebang, not executable" {
  local s
  for s in "${LIBS[@]}"; do
    [ ! -x "${REPO_ROOT}/${s}" ]
    run head -n 1 "${REPO_ROOT}/${s}"
    refute_output --partial '#!'
  done
}

# Prints "<name> <file>" for every function defined across the shell sources.
_function_index() {
  local f
  for f in "${SCRIPTS[@]}" "${LIBS[@]}"; do
    grep -Eo '^function [A-Za-z_][A-Za-z0-9_]*' "${REPO_ROOT}/${f}" \
      | awk -v file="${f}" '{ print $2, file }'
  done
}

# bats test_tags=lint
# A name may repeat across files — main, handoff and parse_params are each
# script's own surface. A body may not: identical text in two files means one
# of them is a copy, and copies drift.
@test "no function body appears in two files" {
  local index="${BATS_TEST_TMPDIR}/bodies"
  : > "${index}"
  local name file body
  while read -r name file; do
    body="$(awk -v open="function ${name}() {" '
      $0 == open { inside = 1 }
      inside { print }
      inside && $0 == "}" { exit }' "${REPO_ROOT}/${file}")"
    printf '%s %s %s\n' "$(printf '%s' "${body}" | cksum | awk '{ print $1 "-" $2 }')" \
      "${file}" "${name}" >> "${index}"
  done < <(_function_index)

  local dupes
  dupes="$(sort "${index}" | awk '
    $1 == prev { print "  " prevfile ":" prevname " and " $2 ":" $3 }
    { prev = $1; prevfile = $2; prevname = $3 }')"
  if [ -n "${dupes}" ]; then
    echo 'these function bodies are byte-identical copies:' >&2
    echo "${dupes}" >&2
    return 1
  fi
}
