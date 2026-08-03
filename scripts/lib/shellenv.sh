# The Homebrew shellenv block: where it goes, and the fence ./enter writes
# around it so ./leave can take exactly that block back out.
#
# shellcheck shell=bash
# shellcheck disable=SC2329

# enter writes the fence, leave reads it — neither lives in this file.
# shellcheck disable=SC2034
ZPROFILE_MARK_START='# >>> particle-garden enter >>>'
# shellcheck disable=SC2034
ZPROFILE_MARK_END='# <<< particle-garden enter <<<'

#######################################
# The shell startup file the block lives in. ENTER_ZPROFILE overrides it
# (test seam), so no test writes a real one.
#######################################
function zprofile_path() {
  printf '%s\n' "${ENTER_ZPROFILE:-${HOME}/.zprofile}"
}

# vim: ft=bash ts=2 sw=2 sts=2 et
