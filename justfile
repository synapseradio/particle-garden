# Particle Garden — cross-language build orchestration.
# Bun owns web-ui/; nim owns everything else. This file owns the order:
# main.nim staticReads web/app.js AND web/ui-bundle.* at compile time, so the
# shader bundle, the frontend, and the UI bundle must all exist before nim c.
#
# Recipes invoke `nim` DIRECTLY rather than through the nimble tasks: nimble
# 0.22.2 exits 0 even when a task's exec fails (observed: a broken `nimble
# app` reported success and left a stale web/app.js), so a nimble-based
# recipe cannot fail the build. The nimble tasks remain for manual use; the
# flag constants below mirror particle_garden.nimble and must stay in sync.

quality_flags := "--styleCheck:error --styleCheck:usages --warningAsError:Deprecated --warningAsError:BareExcept --warningAsError:CStringConv --warningAsError:EnumConv --warningAsError:HoleEnumConv --warningAsError:SmallLshouldNotBeUsed --warningAsError:ProveInit --warningAsError:UnusedImport --warningAsError:Effect --hint:XDeclaredButNotUsed:on"
js_flags := "-d:release " + quality_flags
native_flags := "-d:release --opt:speed " + quality_flags
# MinGW static linking on Windows (no VCRUNTIME140.dll dependency), matching
# particle_garden.nimble's release task.
windows_static_flags := if os() == "windows" { "--passL:-static --passL:-static-libgcc --passL:-static-libstdc++" } else { "" }

default: happen

# Bundle WGSL shaders (resolve //! import, substitute config)
shaders:
    nim c -r --path:src {{quality_flags}} tools/wgsl_bundle.nim

# Compile the Nim frontend: src/app.nim -> web/app.js
build-app:
    nim js {{js_flags}} --out:web/app.js src/app.nim

# Typecheck (tsc --noEmit, TS 7) and bundle the Solid UI -> web/ui-bundle.*
build-ui:
    cd web-ui && bun install --frozen-lockfile && bun run typecheck && bun run build.ts

# Compile the native server (staticReads web/app.js + web/ui-bundle.*)
build-native:
    nim c {{native_flags}} --out:main src/main.nim

# Full build. ORDER MATTERS: build-native staticReads the other steps' output.
happen: shaders build-app build-ui build-native
    @echo "Build complete. Run with: ./main"

# Native Nim test suite (pure-logic modules)
test:
    nim c -r {{quality_flags}} tests/test_all.nim

# TypeScript pure-logic tests
test-ui:
    cd web-ui && bun test

# Shell suite for enter / leave / tools/garden.sh
test-shell:
    bats tests/shell

# shellcheck over the onboarding scripts (-x follows enter/leave into scripts/lib)
lint-shell:
    shellcheck -s bash -S style -x enter leave tools/garden.sh scripts/lib/*.sh

# Shaders first: the bundled web/shaders/*.wgsl are gitignored output, and the
# binding-set test in tests/test_wgsl_lint.nim reads them. Without this a clone
# that has never built runs that test against an empty directory.
check: shaders test test-ui test-shell lint-shell

# Sync project dependencies (idempotent; seconds when already satisfied).
# Runs inside `be` so a nimble.lock bump can't strand the build.
deps:
    nimble install -d -y
    nimble setup

# Sync deps, build everything, run
be:
    just deps
    just happen
    ./main

# Optimized release build (same order and flags as the nimble release task,
# with the UI bundle built first for build-native's staticRead)
release: shaders build-app build-ui
    nim c {{native_flags}} {{windows_static_flags}} --out:main src/main.nim
