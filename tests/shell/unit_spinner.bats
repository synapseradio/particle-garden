#!/usr/bin/env bats
# The spinner. Two properties, both of which an installer depends on: it stops
# when told, and it never swallows the interrupt that ends the run.
#
# Every test here carries a deadline. The failure these guard against is an
# unbounded hang, so a red test would otherwise wedge the suite instead of
# reporting.

load 'helpers/setup'

setup() {
  isolate_env
  cd "${BATS_TEST_TMPDIR}"
}

teardown() {
  # A wedged run leaves both the script and its spinner subshell alive, and a
  # survivor holding bats' reporting fd open hangs the whole suite at exit.
  # The pid files are the only handle a test has on a process it never forked;
  # run.pid names a process group leader, so the negative pid takes the tree.
  if [ -s "${BATS_TEST_TMPDIR}/run.pid" ]; then
    kill -9 -"$(cat "${BATS_TEST_TMPDIR}/run.pid")" 2>/dev/null || true
  fi
  if [ -s "${BATS_TEST_TMPDIR}/spinner.pid" ]; then
    kill -9 "$(cat "${BATS_TEST_TMPDIR}/spinner.pid")" 2>/dev/null || true
  fi
}

# Starts a script in its own process group and records the leader's pid.
# Monitor mode is what makes the signal tests possible at all: a background
# job from a non-interactive shell without it inherits SIGINT ignored, and
# bash then refuses to let the script trap INT, so no interrupt ever arrives.
# 3>&- keeps bats' reporting fd out of a process this test may have to kill.
start_run() {
  local out="$1"
  shift
  set -m
  "$@" > "${out}" 2>&1 3>&- < "${RUN_STDIN:-/dev/null}" &
  RUN_PID=$!
  set +m
  printf '%s\n' "${RUN_PID}" > "${BATS_TEST_TMPDIR}/run.pid"
}

# Runs a command with a hard deadline in tenths of a second, setting `status`
# and `output` the way bats' own `run` does. A deadline hit reports 124.
run_bounded() {
  local deadline="$1"
  shift
  local out="${BATS_TEST_TMPDIR}/bounded.out"
  : > "${out}"
  "$@" > "${out}" 2>&1 3>&- &
  local pid=$! waited=0
  while kill -0 "${pid}" 2>/dev/null; do
    if [ "${waited}" -ge "${deadline}" ]; then
      kill -9 "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      status=124
      output="$(cat "${out}")"
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  status=0
  wait "${pid}" || status=$?
  output="$(cat "${out}")"
  return 0
}

# Writes a probe that drives the spinner the way enter and leave do, and
# prints its path. BATS is never a TTY, so the probe forces the spinner on.
spinner_probe() {
  local path="${BATS_TEST_TMPDIR}/probe.sh"
  {
    printf '#!/bin/bash\n'
    printf 'set -o nounset\n'
    printf '. "%s/scripts/lib/load.sh"\n' "${REPO_ROOT}"
    printf 'ENTER_FORCE_SPINNER=1\n'
    printf '%s\n' "$1"
  } > "${path}"
  chmod +x "${path}"
  printf '%s\n' "${path}"
}

# Polls until a process is gone or the deadline passes, in tenths of a second.
# Signals reach the runner asynchronously, so nothing here may assume the exit
# has already happened.
wait_for_exit() {
  local pid="$1" deadline="$2" waited=0
  while kill -0 "${pid}" 2>/dev/null; do
    if [ "${waited}" -ge "${deadline}" ]; then
      return 1
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
}

# Polls until a file contains a pattern, in tenths of a second.
wait_for_line() {
  local file="$1" pattern="$2" deadline="$3" waited=0
  while ! grep -q "${pattern}" "${file}" 2>/dev/null; do
    if [ "${waited}" -ge "${deadline}" ]; then
      return 1
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
}

# bats test_tags=unit
@test "spinner_stop returns within three seconds" {
  local probe
  probe="$(spinner_probe '
spinner_start "probe"
printf "%s\n" "${SPINNER_PID}" > "'"${BATS_TEST_TMPDIR}"'/spinner.pid"
spinner_stop
printf "stopped\n"')"

  run_bounded 30 bash "${probe}"
  assert_equal "${status}" 0
  assert_output --partial 'stopped'
}

# bats test_tags=unit
@test "the spinner subshell dies on SIGTERM within a second" {
  local probe
  probe="$(spinner_probe '
spinner_start "probe"
printf "%s\n" "${SPINNER_PID}" > "'"${BATS_TEST_TMPDIR}"'/spinner.pid"
kill "${SPINNER_PID}"
waited=0
while kill -0 "${SPINNER_PID}" 2>/dev/null; do
  if [ "${waited}" -ge 10 ]; then
    printf "alive\n"
    exit 1
  fi
  sleep 0.1
  waited=$((waited + 1))
done
printf "gone\n"')"

  run_bounded 30 bash "${probe}"
  assert_equal "${status}" 0
  assert_output --partial 'gone'
}

# Writes a probe that runs one step through the shared module, and prints its
# path. Nothing forces the spinner here: these tests ask where output lands.
step_probe() {
  local path="${BATS_TEST_TMPDIR}/step-probe.sh"
  {
    printf '#!/bin/bash\n'
    printf 'set -o nounset\n'
    printf '. "%s/scripts/lib/load.sh"\n' "${REPO_ROOT}"
    printf 'step_log_reset\n'
    printf '%s\n' "$1"
  } > "${path}"
  chmod +x "${path}"
  printf '%s\n' "${path}"
}

# bats test_tags=unit
@test "run_step puts a step's output on the screen and in the step log" {
  local probe
  probe="$(step_probe 'run_step "Fetching things…" printf "%s\n" "the-step-said-this"')"

  run bash "${probe}"
  assert_success
  assert_output --partial 'the-step-said-this'

  run cat "${ENTER_STATE_DIR}/step.log"
  assert_output --partial 'the-step-said-this'
}

# bats test_tags=unit
@test "a quiet step keeps its output off the screen and still logs it" {
  local probe
  probe="$(step_probe 'quiet=true
run_step "Fetching things…" printf "%s\n" "the-step-said-this"')"

  run bash "${probe}"
  assert_success
  refute_output --partial 'the-step-said-this'

  run cat "${ENTER_STATE_DIR}/step.log"
  assert_output --partial 'the-step-said-this'
}

# bats test_tags=unit
@test "run_step returns the command's status, not tee's" {
  local probe
  probe="$(step_probe 'run_step "Failing…" sh -c "exit 3"
printf "status=%s\n" "$?"')"

  run bash "${probe}"
  assert_output --partial 'status=3'
}

# bats test_tags=unit
@test "a failed quiet step prints the tail of the step log" {
  local probe
  probe="$(step_probe 'quiet=true
run_step "Failing…" sh -c "printf \"boom-from-the-step\n\"; exit 3"
printf "status=%s\n" "$?"')"

  run bash "${probe}"
  assert_output --partial 'boom-from-the-step'
  assert_output --partial 'status=3'
}

# bats test_tags=unit
@test "the step log carries this run's output only" {
  printf 'noise-from-a-previous-run\n' > "${ENTER_STATE_DIR}/step.log"
  local probe
  probe="$(step_probe 'run_step "Fetching things…" printf "%s\n" "the-step-said-this"')"

  run bash "${probe}"
  assert_success

  run cat "${ENTER_STATE_DIR}/step.log"
  refute_output --partial 'noise-from-a-previous-run'
  assert_output --partial 'the-step-said-this'
}

# Wedges enter inside the Command Line Tools wait loop: the installer mock
# never reports success, so the phase spins until a signal arrives. The sleep
# mock is short and real, so the interrupt lands within one loop turn — bash
# defers a trap until the foreground command returns.
wedge_enter_on_clt() {
  mock_macos_fresh
  cat > "${MOCK_BIN}/xcode-select" <<EOS
#!/bin/bash
printf '%s\n' "\$*" >> "${MOCK_CALLS}/xcode-select.log"
exit 2
EOS
  cat > "${MOCK_BIN}/sleep" <<'EOS'
#!/bin/bash
exec /bin/sleep 0.2
EOS
  chmod +x "${MOCK_BIN}/xcode-select" "${MOCK_BIN}/sleep"
}

# bats test_tags=integration
@test "enter exits 130 when SIGINT arrives while the spinner runs" {
  wedge_enter_on_clt
  local out="${BATS_TEST_TMPDIR}/enter.out"
  export ENTER_FORCE_SPINNER=1
  start_run "${out}" "${REPO_ROOT}/enter" --yes
  local pid="${RUN_PID}"

  wait_for_line "${out}" 'Command Line Tools installer' 100 \
    || { cat "${out}" >&2; false; }
  # Ctrl-C reaches the whole foreground group, and so does this.
  kill -INT -"${pid}"

  wait_for_exit "${pid}" 50 || { cat "${out}" >&2; false; }
  local st=0
  wait "${pid}" || st=$?
  assert_equal "${st}" 130
}

# bats test_tags=integration
@test "leave exits 130 when SIGINT arrives while the spinner runs" {
  mock_macos_provisioned
  printf '%s\t%s\t%s\t%s\t%s\n' '2026-08-01T00:00:00+0000' installed tool just \
    "${MOCK_BIN}/just" > "${ENTER_STATE_DIR}/ledger.tsv"
  # brew uninstall blocks for a second, which is the window the interrupt
  # has to land in.
  cat > "${MOCK_BIN}/brew" <<'EOS'
#!/bin/bash
exec /bin/sleep 1
EOS
  chmod +x "${MOCK_BIN}/brew"

  local out="${BATS_TEST_TMPDIR}/leave.out"
  export ENTER_ASSUME_TTY=1 ENTER_FORCE_SPINNER=1
  RUN_STDIN="${BATS_TEST_TMPDIR}/answers"
  printf 'y\ny\ny\ny\ny\n' > "${RUN_STDIN}"
  start_run "${out}" "${REPO_ROOT}/leave"
  local pid="${RUN_PID}"

  wait_for_line "${out}" 'Removing just' 100 || { cat "${out}" >&2; false; }
  kill -INT -"${pid}"

  wait_for_exit "${pid}" 50 || { cat "${out}" >&2; false; }
  local st=0
  wait "${pid}" || st=$?
  assert_equal "${st}" 130
}

# vim: ft=bash ts=2 sw=2 sts=2 et
