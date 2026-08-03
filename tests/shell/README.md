# Shell suite

BATS tests for `enter`, `leave`, `tools/garden.sh`, and the `scripts/lib/`
modules the first two share. Run them with `just test-shell`, or directly:

```
bats tests/shell                    # everything
bats tests/shell/unit_ledger.bats   # one file
bats tests/shell --filter-tags unit # by tag: unit, integration, lint, bootstrap
```

Requires bats-core plus its helper libraries:

```
brew tap bats-core/bats-core
brew install bats-core bats-support bats-assert bats-file
```

## Layout

- `helpers/setup.bash` — loads the helper libraries and defines
  `isolate_env`, which re-homes `HOME`, the state dir, the clone target, the
  zprofile, and `PATH` under `$BATS_TEST_TMPDIR`. No test touches real
  state; the exported `ENTER_CLONE_DIR` also keeps enter's adoption rule off
  this repository.
- `helpers/mocks.bash` — a factory (`create-mock-tool`) writing stateful
  mocks for git, gh, brew, the Homebrew installer, curl, just, nim, nimble,
  bun, xcode-select, xcrun, clang, sleep, sudo, and uname. Mocks are written
  against the real interfaces observed on macOS 15 and use only builtins
  plus `/bin` tools, so they survive a `PATH` without `/usr/bin` (how the
  bootstrap suite makes `git` disappear). Every call lands in
  `$MOCK_CALLS/<name>.log` and the shared ordering log `$MOCK_CALLS/all.log`;
  behavior pivots on files under `$MOCK_STATE` (`clt`, `gh-authed`,
  `gh-fork-fails`, `bun-fails`) and per-repo files under `.git/`
  (`origin-url`, `HEAD-branch`, `upstream-tracking`, `gitdir-override`,
  `status-mock`).
- `unit_*.bats` — source `./enter` (its strict mode and `main` call are
  sourcing-gated), or `scripts/lib/load.sh` through `load_shared_lib`, and
  exercise single functions: flags, ledger semantics, detection, repo
  treatment.
- `unit_spinner.bats` — the spinner and `run_step`, from the shared module
  and from both scripts under a real SIGINT. Every test here carries a
  deadline, because the behaviour it guards against is an unbounded hang.
  `ENTER_FORCE_SPINNER` turns the spinner on where no TTY exists, and
  `start_run` puts a script in its own process group: a background job from
  a non-interactive shell inherits SIGINT ignored, and bash then refuses to
  let the script trap it.
- `integration_enter.bats` / `integration_leave.bats` — execute the scripts
  end to end against mocked machines and read the call logs plus the ledger.
- `lint.bats` — syntax under both bashes, shellcheck, the bash-3.2
  banned-construct list, executable shape, and one check that no function
  body appears byte-identically in two files.
- `bootstrap.bats` — `tools/garden.sh`: flag parsing before any mutation,
  the consent gate, the marker handshake with enter, and the
  truncation-safe file shape.

## Seams the scripts expose for these tests

`ENTER_STATE_DIR`, `ENTER_CLONE_DIR`, `ENTER_ZPROFILE`, `ENTER_OWNER_EMAIL`,
`ENTER_BREW_PATHS` (colon-separated brew probe paths), and
`ENTER_ASSUME_TTY` (lets `confirm` read piped answers where a real run would
require a terminal or `--yes`), and `ENTER_FORCE_SPINNER` (starts the
spinner without a TTY). The last two stay separate names so that answering a
prompt in a test does not fill its output with spinner frames. Mock behavior
pivots on `MOCK_GIT_EMAIL`, `MOCK_NIM_VERSION`, `MOCK_JUST_STATUS`, and
`MOCK_UNAME`.
