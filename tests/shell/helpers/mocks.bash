# Mock executables and call assertions for the enter/leave/garden.sh suite.
# Mocks are written against real interfaces observed on macOS 15 (git 2.x,
# Homebrew 4.x, nim 2.2.10, bats-core 1.13). They use only shell builtins and
# /bin tools, so they run even under a PATH without /usr/bin (the garden.sh
# CLT test removes /usr/bin to make `git` disappear). Every mock appends
# "name args" to ${MOCK_CALLS}/all.log (shared ordering record) and "args" to
# its own ${MOCK_CALLS}/name.log.
# shellcheck shell=bash

# Writes the factory script that creates the rich, stateful mocks. State
# files under ${MOCK_STATE} steer behavior:
#   clt            — CLT installed (xcode-select -p / xcrun succeed)
#   gh-authed      — `gh auth status` succeeds
#   gh-fork-fails  — `gh repo fork` fails (self-owned repo case)
#   bun-fails      — `bun install --frozen-lockfile` fails with the raw error
write_mock_factory() {
  cat > "${MOCK_BIN}/create-mock-tool" <<'FACTORY'
#!/bin/bash
name="$1"
out="${MOCK_BIN}/${name}"
case "${name}" in

  git)
    cat > "${out}" <<'EOS'
#!/bin/bash
printf 'git %s\n' "$*" >> "${MOCK_CALLS}/all.log"
printf '%s\n' "$*" >> "${MOCK_CALLS}/git.log"
dir="${PWD}"
if [ "${1-}" = '-C' ]; then dir="$2"; shift 2; fi
cmd="${1-}"
if [ $# -gt 0 ]; then shift; fi
gd="${dir}/.git"
if [ "${cmd}" = 'clone' ]; then
  url="$1"
  target="$2"
  mkdir -p "${target}/.git" "${target}/web-ui"
  : > "${target}/particle_garden.nimble"
  : > "${target}/justfile"
  printf '%s\n' "${url}" > "${target}/.git/origin-url"
  printf 'main\n' > "${target}/.git/HEAD-branch"
  : > "${target}/.git/upstream-tracking"
  cat > "${target}/enter" <<'EOE'
#!/bin/bash
printf 'fake-enter %s\n' "$*" >> "${MOCK_CALLS}/all.log"
printf '%s\n' "$*" >> "${MOCK_CALLS}/fake-enter.log"
exit 0
EOE
  chmod +x "${target}/enter"
  : > "${target}/leave"
  exit 0
fi
if [ "${cmd}" = 'config' ] && [ "$*" = 'user.email' ]; then
  printf '%s\n' "${MOCK_GIT_EMAIL:-owner@example.com}"
  exit 0
fi
if [ ! -e "${gd}" ]; then exit 128; fi
case "${cmd}" in
  rev-parse)
    case "$*" in
      *--git-path*hooks*)
        printf '%s/.git/hooks\n' "${dir}"
        exit 0
        ;;
      *--git-dir*)
        if [ -f "${gd}/gitdir-override" ]; then cat "${gd}/gitdir-override"; else printf '%s\n' "${gd}"; fi
        exit 0
        ;;
      *'@{upstream}'*)
        if [ -f "${gd}/upstream-tracking" ]; then printf 'origin/main\n'; exit 0; fi
        exit 128
        ;;
      *--abbrev-ref*HEAD*)
        if [ -f "${gd}/HEAD-branch" ]; then cat "${gd}/HEAD-branch"; else printf 'main\n'; fi
        exit 0
        ;;
    esac
    exit 0
    ;;
  symbolic-ref)
    printf 'origin/main\n'
    exit 0
    ;;
  remote)
    if [ "${1-}" = 'get-url' ]; then
      rname="${2-}"
      if [ -f "${gd}/${rname}-url" ]; then cat "${gd}/${rname}-url"; exit 0; fi
      if [ "${rname}" = 'origin' ]; then printf 'https://github.com/synapseradio/particle-garden\n'; exit 0; fi
      exit 2
    fi
    exit 0
    ;;
  config)
    printf '%s\n' "$*" >> "${gd}/config-log"
    exit 0
    ;;
  branch)
    case "$*" in
      *--set-upstream-to=*) : > "${gd}/upstream-tracking" ;;
    esac
    exit 0
    ;;
  status)
    if [ -f "${gd}/status-mock" ]; then cat "${gd}/status-mock"; fi
    exit 0
    ;;
esac
exit 0
EOS
    ;;

  gh)
    cat > "${out}" <<'EOS'
#!/bin/bash
printf 'gh %s\n' "$*" >> "${MOCK_CALLS}/all.log"
printf '%s\n' "$*" >> "${MOCK_CALLS}/gh.log"
dir="${PWD}"
if [ "${1-}" = '-C' ]; then dir="$2"; shift 2; fi
case "$*" in
  'auth status')
    if [ -f "${MOCK_STATE}/gh-authed" ]; then exit 0; fi
    exit 1
    ;;
  'repo fork --remote')
    if [ -f "${MOCK_STATE}/gh-fork-fails" ]; then
      printf 'failed to fork: name already exists on this account\n' >&2
      exit 1
    fi
    printf 'https://github.com/tester/particle-garden\n' > "${dir}/.git/origin-url"
    printf 'https://github.com/synapseradio/particle-garden\n' > "${dir}/.git/upstream-url"
    exit 0
    ;;
esac
exit 0
EOS
    ;;

  brew)
    cat > "${out}" <<'EOS'
#!/bin/bash
printf 'brew %s\n' "$*" >> "${MOCK_CALLS}/all.log"
printf '%s\n' "$*" >> "${MOCK_CALLS}/brew.log"
case "${1-}" in
  --version) printf 'Homebrew 4.4.0\n'; exit 0 ;;
  --prefix) printf '%s\n' "${MOCK_PREFIX}"; exit 0 ;;
  shellenv) printf 'export HOMEBREW_PREFIX=%s\n' "${MOCK_PREFIX}"; exit 0 ;;
  install)
    shift
    for f in "$@"; do
      case "${f}" in
        just) "${MOCK_BIN}/create-mock-tool" just ;;
        nim) "${MOCK_BIN}/create-mock-tool" nim; "${MOCK_BIN}/create-mock-tool" nimble ;;
        bun | oven-sh/bun/bun) "${MOCK_BIN}/create-mock-tool" bun ;;
      esac
    done
    exit 0
    ;;
  uninstall)
    shift
    for f in "$@"; do
      case "${f}" in
        -y) ;;
        *) rm -f "${MOCK_BIN}/${f}" ;;
      esac
    done
    exit 0
    ;;
esac
exit 0
EOS
    ;;

  brew-installer)
    cat > "${out}" <<'EOS'
#!/bin/bash
printf 'brew-installer\n' >> "${MOCK_CALLS}/all.log"
printf 'ran\n' >> "${MOCK_CALLS}/brew-installer.log"
if [ -n "${NONINTERACTIVE-}" ]; then
  printf 'NONINTERACTIVE=present\n' >> "${MOCK_CALLS}/brew-installer-env.log"
else
  printf 'NONINTERACTIVE=absent\n' >> "${MOCK_CALLS}/brew-installer-env.log"
fi
"${MOCK_BIN}/create-mock-tool" brew
exit 0
EOS
    ;;

  curl)
    cat > "${out}" <<'EOS'
#!/bin/bash
printf 'curl %s\n' "$*" >> "${MOCK_CALLS}/all.log"
printf '%s\n' "$*" >> "${MOCK_CALLS}/curl.log"
case "$*" in
  *Homebrew/install*) printf '%s\n' "${MOCK_BIN}/brew-installer" ;;
esac
exit 0
EOS
    ;;

  just)
    cat > "${out}" <<'EOS'
#!/bin/bash
printf 'just %s\n' "$*" >> "${MOCK_CALLS}/all.log"
printf '%s\n' "$*" >> "${MOCK_CALLS}/just.log"
if [ "${1-}" = '--version' ]; then printf 'just 1.36.0\n'; exit 0; fi
if [ "${1-}" = 'be' ]; then
  if [ -d "${ENTER_STATE_DIR}/particle-garden.lock" ]; then
    printf 'lock-held\n' >> "${MOCK_CALLS}/just-observed.log"
  fi
  printf 'mock-just-be-running\n'
  exit "${MOCK_JUST_STATUS:-0}"
fi
exit 0
EOS
    ;;

  nim)
    cat > "${out}" <<'EOS'
#!/bin/bash
printf 'nim %s\n' "$*" >> "${MOCK_CALLS}/all.log"
printf '%s\n' "$*" >> "${MOCK_CALLS}/nim.log"
if [ "${1-}" = '--version' ]; then
  printf 'Nim Compiler Version %s [MacOSX: arm64]\n' "${MOCK_NIM_VERSION:-2.2.10}"
fi
exit 0
EOS
    ;;

  nimble)
    cat > "${out}" <<'EOS'
#!/bin/bash
printf 'nimble %s\n' "$*" >> "${MOCK_CALLS}/all.log"
printf '%s\n' "$*" >> "${MOCK_CALLS}/nimble.log"
case "${1-}" in
  --version) printf 'nimble v0.22.2\n' ;;
  setup) printf -- '--path:"%s/.nimble/pkgs2/webui-0.9.0"\n' "${HOME}" > nimble.paths ;;
esac
exit 0
EOS
    ;;

  bun)
    cat > "${out}" <<'EOS'
#!/bin/bash
printf 'bun %s\n' "$*" >> "${MOCK_CALLS}/all.log"
printf '%s\n' "$*" >> "${MOCK_CALLS}/bun.log"
case "$*" in
  --version) printf '1.2.0\n' ;;
  'install --frozen-lockfile')
    if [ -f "${MOCK_STATE}/bun-fails" ]; then
      printf 'error: lockfile had changes, but lockfile is frozen\n' >&2
      exit 1
    fi
    mkdir -p node_modules
    ;;
esac
exit 0
EOS
    ;;

  xcode-select)
    cat > "${out}" <<'EOS'
#!/bin/bash
printf 'xcode-select %s\n' "$*" >> "${MOCK_CALLS}/all.log"
printf '%s\n' "$*" >> "${MOCK_CALLS}/xcode-select.log"
case "$*" in
  -p | --print-path)
    if [ -f "${MOCK_STATE}/clt" ]; then printf '/Library/Developer/CommandLineTools\n'; exit 0; fi
    exit 2
    ;;
  --install)
    : > "${MOCK_STATE}/clt"
    "${MOCK_BIN}/create-mock-tool" git
    exit 0
    ;;
esac
exit 0
EOS
    ;;

  xcrun)
    cat > "${out}" <<'EOS'
#!/bin/bash
printf 'xcrun %s\n' "$*" >> "${MOCK_CALLS}/all.log"
printf '%s\n' "$*" >> "${MOCK_CALLS}/xcrun.log"
if [ -f "${MOCK_STATE}/clt" ]; then printf '/usr/bin/clang\n'; exit 0; fi
exit 1
EOS
    ;;

  clang)
    cat > "${out}" <<'EOS'
#!/bin/bash
printf 'clang %s\n' "$*" >> "${MOCK_CALLS}/all.log"
printf '%s\n' "$*" >> "${MOCK_CALLS}/clang.log"
printf 'Apple clang version 17.0.0\n'
exit 0
EOS
    ;;

  sleep)
    cat > "${out}" <<'EOS'
#!/bin/bash
printf '%s\n' "$*" >> "${MOCK_CALLS}/sleep.log"
exit 0
EOS
    ;;

  sudo)
    cat > "${out}" <<'EOS'
#!/bin/bash
printf 'sudo %s\n' "$*" >> "${MOCK_CALLS}/all.log"
printf '%s\n' "$*" >> "${MOCK_CALLS}/sudo.log"
exit 0
EOS
    ;;

  uname)
    cat > "${out}" <<'EOS'
#!/bin/bash
printf '%s\n' "$*" >> "${MOCK_CALLS}/uname.log"
printf '%s\n' "${MOCK_UNAME:-Linux}"
exit 0
EOS
    ;;

esac
chmod +x "${out}"
FACTORY
  chmod +x "${MOCK_BIN}/create-mock-tool"
}

mock_tool() {
  "${MOCK_BIN}/create-mock-tool" "$1"
}

# Zero-tools machine: the CLT is installable, the brew installer reachable.
mock_macos_fresh() {
  local t
  for t in xcode-select xcrun clang sleep sudo curl brew-installer; do
    mock_tool "${t}"
  done
}

# Fully provisioned machine: CLT present, every tool on PATH.
mock_macos_provisioned() {
  mock_macos_fresh
  : > "${MOCK_STATE}/clt"
  local t
  for t in git brew just nim nimble bun; do
    mock_tool "${t}"
  done
}

# A realistic clone at $1: canonical origin, main checked out, tracking set,
# and the clone predicate garden.sh reads out of a candidate directory.
make_fake_clone() {
  local dir="$1"
  mkdir -p "${dir}/.git" "${dir}/web-ui" "${dir}/scripts/lib"
  cp "${REPO_ROOT}/scripts/lib/clone.sh" "${dir}/scripts/lib/clone.sh"
  : > "${dir}/particle_garden.nimble"
  : > "${dir}/justfile"
  printf 'https://github.com/synapseradio/particle-garden\n' > "${dir}/.git/origin-url"
  printf 'main\n' > "${dir}/.git/HEAD-branch"
  : > "${dir}/.git/upstream-tracking"
}

# Copies the real enter into the clone at $1 along with scripts/lib, which it
# sources — a bare copy of the script alone would refuse to start.
install_enter_into() {
  local dir="$1"
  cp "${REPO_ROOT}/enter" "${dir}/enter"
  mkdir -p "${dir}/scripts/lib"
  cp "${REPO_ROOT}"/scripts/lib/*.sh "${dir}/scripts/lib/"
}

# Replaces $1/enter with a logging stub, so a garden.sh handoff (exec) lands
# somewhere observable instead of running the real installer.
make_fake_enter() {
  local dir="$1"
  cat > "${dir}/enter" <<EOF
#!/bin/bash
printf 'fake-enter %s\n' "\$*" >> "${MOCK_CALLS}/all.log"
printf '%s\n' "\$*" >> "${MOCK_CALLS}/fake-enter.log"
exit 0
EOF
  chmod +x "${dir}/enter"
  : > "${dir}/leave"
}

# The marker garden.sh writes after cloning: it tells enter the clone at $1 is
# its own to record as installed, rather than one to adopt as preexisting.
mark_clone_created_by_garden() {
  mkdir -p "${ENTER_STATE_DIR}"
  printf '%s\n' "$1" > "${ENTER_STATE_DIR}/clone-created-by-garden"
}

# Simple stub: mock_bin NAME [EXIT] [STDOUT]
mock_bin() {
  local name="$1" status="${2:-0}" out="${3-}"
  {
    printf '#!/bin/bash\n'
    printf 'printf "%s %%s\\n" "$*" >> "%s/all.log"\n' "${name}" "${MOCK_CALLS}"
    printf 'printf "%%s\\n" "$*" >> "%s/%s.log"\n' "${MOCK_CALLS}" "${name}"
    if [ -n "${out}" ]; then
      printf 'printf "%%s\\n" %q\n' "${out}"
    fi
    printf 'exit %s\n' "${status}"
  } > "${MOCK_BIN}/${name}"
  chmod +x "${MOCK_BIN}/${name}"
}

assert_called() {
  local name="$1"
  if [ ! -s "${MOCK_CALLS}/${name}.log" ]; then
    echo "expected ${name} to have been called, but it was not" >&2
    return 1
  fi
}

assert_called_with() {
  local name="$1" pattern="$2"
  assert_called "${name}" || return 1
  if ! grep -Eq -e "${pattern}" "${MOCK_CALLS}/${name}.log"; then
    {
      echo "expected a ${name} call matching: ${pattern}"
      echo 'calls were:'
      cat "${MOCK_CALLS}/${name}.log"
    } >&2
    return 1
  fi
}

refute_called() {
  local name="$1"
  if [ -s "${MOCK_CALLS}/${name}.log" ]; then
    {
      echo "expected ${name} to never be called; calls were:"
      cat "${MOCK_CALLS}/${name}.log"
    } >&2
    return 1
  fi
}

refute_called_with() {
  local name="$1" pattern="$2"
  if [ -s "${MOCK_CALLS}/${name}.log" ] && grep -Eq -e "${pattern}" "${MOCK_CALLS}/${name}.log"; then
    {
      echo "expected no ${name} call matching: ${pattern} — calls were:"
      cat "${MOCK_CALLS}/${name}.log"
    } >&2
    return 1
  fi
}

_all_log_line() {
  grep -En "$1" "${MOCK_CALLS}/all.log" 2>/dev/null | awk -F: 'NR == 1 { print $1 }'
}

# Asserts pattern $1 appears before pattern $2 in the shared ordering log.
assert_order() {
  local a b
  a="$(_all_log_line "$1")"
  b="$(_all_log_line "$2")"
  if [ -z "${a}" ] || [ -z "${b}" ] || [ "${a}" -ge "${b}" ]; then
    {
      echo "expected '$1' (line ${a:-none}) before '$2' (line ${b:-none}); all.log:"
      cat "${MOCK_CALLS}/all.log" 2>/dev/null
    } >&2
    return 1
  fi
}
