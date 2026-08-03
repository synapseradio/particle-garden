# The one predicate both halves of the installer agree on.
#
# shellcheck shell=bash
# shellcheck disable=SC2329

#######################################
# One definition of "this directory holds the Particle Garden clone". The
# body is duplicated byte-identically in tools/garden.sh, which arrives by
# curl and can source nothing; tests/shell/lint.bats diffs the two copies.
#######################################
function is_clone() {
  local dir="$1"
  git -C "${dir}" rev-parse --git-dir >/dev/null 2>&1 \
    && [ -f "${dir}/particle_garden.nimble" ] \
    && [ -f "${dir}/justfile" ]
}

# vim: ft=bash ts=2 sw=2 sts=2 et
