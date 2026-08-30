#!/usr/bin/env bats
# Coverage relations between the installer scripts, README.md, the how-to-run
# text files and the release workflow. A user refused by the installer is sent
# to a download route, and these hold that route together: the scripts name a
# page that exists, the README carries the section they name, and each archive
# ships the file its packaging step copies in.

load 'helpers/setup'

RELEASES_URL='https://github.com/synapseradio/particle-garden/releases'
SCRIPTS=(enter leave tools/garden.sh)

# Prints the GitHub anchor of every ATX heading in README.md.
_readme_anchors() {
  awk '
    /^#+ / {
      sub(/^#+ +/, "")
      line = tolower($0)
      gsub(/[^a-z0-9 -]/, "", line)
      gsub(/ /, "-", line)
      print line
    }' "${REPO_ROOT}/README.md"
}

# Prints the body of the README section whose heading text is $1.
_readme_section() {
  awk -v want="$1" '
    /^#+ / {
      heading = $0
      sub(/^#+ +/, "", heading)
      inside = (heading == want)
      next
    }
    inside { print }' "${REPO_ROOT}/README.md"
}

# bats test_tags=lint
@test "every installer script names the releases page when it refuses a non-macOS machine" {
  local s
  for s in "${SCRIPTS[@]}"; do
    run grep -F "${RELEASES_URL}" "${REPO_ROOT}/${s}"
    assert_success
  done
}

# bats test_tags=lint
@test "every README section an installer message names exists in README.md" {
  local anchors fragment s found
  anchors="$(_readme_anchors)"
  for s in "${SCRIPTS[@]}"; do
    while read -r fragment; do
      [ -n "${fragment}" ] || continue
      found="$(echo "${anchors}" | grep -Fx "${fragment}" || true)"
      if [ -z "${found}" ]; then
        echo "${s} points at README anchor #${fragment}, which no heading produces" >&2
        return 1
      fi
    done < <(grep -Eo 'particle-garden#[a-z0-9-]+' "${REPO_ROOT}/${s}" \
      | cut -d '#' -f 2 | sort -u)
  done
}

# bats test_tags=lint
@test "each release archive carries the how-to-run file its packaging step names" {
  local workflow="${REPO_ROOT}/.github/workflows/release.yml"
  local doc
  for doc in docs/how-to-run-windows.txt docs/how-to-run-linux.txt; do
    assert_file_exist "${REPO_ROOT}/${doc}"
    run grep -F "${doc}" "${workflow}"
    assert_success
    assert_output --partial 'HOW-TO-RUN.txt'
  done
}

# bats test_tags=lint
# "Click through the warning" is the wording a novice cannot act on: the
# SmartScreen dialog hides Run anyway behind More info, so both names must
# survive any rewording of the walkthrough.
@test "the Windows guidance names both buttons the user must click" {
  local button
  for button in 'More info' 'Run anyway'; do
    run grep -F "${button}" "${REPO_ROOT}/docs/how-to-run-windows.txt"
    assert_success

    run grep -F "${button}" <(_readme_section 'Windows')
    assert_success
  done
}
