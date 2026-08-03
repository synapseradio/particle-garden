# Pulls the whole shared core into the sourcing script. ./enter and ./leave
# each reach it with a single line at the top of main(); the module list lives
# here and nowhere else.
#
# shellcheck shell=bash

GARDEN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# shellcheck source=scripts/lib/output.sh
. "${GARDEN_LIB_DIR}/output.sh"
# shellcheck source=scripts/lib/traps.sh
. "${GARDEN_LIB_DIR}/traps.sh"
# shellcheck source=scripts/lib/ask.sh
. "${GARDEN_LIB_DIR}/ask.sh"
# shellcheck source=scripts/lib/spinner.sh
. "${GARDEN_LIB_DIR}/spinner.sh"
# shellcheck source=scripts/lib/ledger.sh
. "${GARDEN_LIB_DIR}/ledger.sh"
# shellcheck source=scripts/lib/lock.sh
. "${GARDEN_LIB_DIR}/lock.sh"
# shellcheck source=scripts/lib/clone.sh
. "${GARDEN_LIB_DIR}/clone.sh"
# shellcheck source=scripts/lib/shellenv.sh
. "${GARDEN_LIB_DIR}/shellenv.sh"

unset GARDEN_LIB_DIR

# vim: ft=bash ts=2 sw=2 sts=2 et
