#!/usr/bin/env bats
# .config/wt.toml's [pre-start] hook: the shell command `wt` runs to
# bootstrap a fresh worktree, read straight from the file and run against a
# mocked `just` so the guard logic is checked without a real nim build.

load 'helpers/setup'

setup() {
  isolate_env
  BOOTSTRAP_CMD="$(awk -F'"' '/^bootstrap = /{print $2}' "${REPO_ROOT}/.config/wt.toml")"
  cd "${BATS_TEST_TMPDIR}"
  cat > "${MOCK_BIN}/just" <<'EOS'
#!/bin/bash
case "$1" in
  deps)
    printf -- '--path:"x"\n' > nimble.paths
    ;;
  shaders)
    if [ ! -f "${SHADERS_SILENT_FAIL:-/nonexistent}" ]; then
      mkdir -p web/shaders
      : > web/shaders/render.wgsl
    fi
    ;;
esac
exit 0
EOS
  chmod +x "${MOCK_BIN}/just"
}

# bats test_tags=unit
@test "the pre-start hook leaves the shader bundle behind" {
  run bash -c "${BOOTSTRAP_CMD}"
  assert_success
  assert_file_exist "web/shaders/render.wgsl"
}

# bats test_tags=unit
@test "the pre-start hook fails loudly when shader bundling produces nothing" {
  export SHADERS_SILENT_FAIL="${BATS_TEST_TMPDIR}/silent-fail"
  : > "${SHADERS_SILENT_FAIL}"
  run bash -c "${BOOTSTRAP_CMD}"
  assert_failure
  assert_output --partial 'shader'
}
