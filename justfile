# Particle Garden — cross-language build orchestration.
# nimble owns the Nim-side tasks; Bun owns web-ui/. This file owns the order:
# main.nim staticReads web/app.js AND web/ui-bundle.* at compile time, so the
# shader bundle, the frontend, and the UI bundle must all exist before nim c.

# Nim quality flags mirror particle_garden.nimble's nativeFlags.
native_flags := "-d:release --opt:speed --styleCheck:error --styleCheck:usages --warningAsError:Deprecated --warningAsError:BareExcept --warningAsError:CStringConv --warningAsError:EnumConv --warningAsError:HoleEnumConv --warningAsError:SmallLshouldNotBeUsed --warningAsError:ProveInit --warningAsError:UnusedImport --warningAsError:Effect --hint:XDeclaredButNotUsed:on"

default: happen

# Bundle WGSL shaders (resolve //! import, substitute config)
shaders:
    nimble shaders --verbose

# Compile the Nim frontend: src/app.nim -> web/app.js
build-app:
    nimble app --verbose

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
    nimble test --verbose

# TypeScript pure-logic tests
test-ui:
    cd web-ui && bun test

# Both test suites
check: test test-ui

# Pull, build everything, run
be:
    git pull
    just happen
    ./main

# Optimized release build. build-ui first: nimble release's nim c step
# staticReads web/ui-bundle.*; nimble release itself covers shaders + app + native.
release: build-ui
    nimble release --verbose
