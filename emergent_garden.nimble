# Package
version       = "0.1.0"
author        = "Goober Garden"
description   = "Particle life simulation with SharedArrayBuffer workers"
license       = "MIT"
srcDir        = "src"
bin           = @["main"]
binDir        = "."

# Dependencies
requires "nim >= 2.0.0 & < 3.0.0"
requires "webui >= 2.4.0"

# Compiler flags for style and warning enforcement
const styleFlags = "--styleCheck:error --styleCheck:usages"
const warningFlags = """--warningAsError:Deprecated \
  --warningAsError:BareExcept \
  --warningAsError:CStringConv \
  --warningAsError:EnumConv \
  --warningAsError:HoleEnumConv \
  --warningAsError:SmallLshouldNotBeUsed \
  --warningAsError:ProveInit \
  --warningAsError:UnusedImport \
  --warningAsError:Effect \
  --hint:XDeclaredButNotUsed:on"""

# Combined quality flags for all builds
const qualityFlags = styleFlags & " " & warningFlags

# JS backend flags (for nim js builds)
const jsFlags = "-d:release " & qualityFlags

# Native backend flags (for nim c builds)
const nativeFlags = "-d:release --opt:speed " & qualityFlags

# Release flags - maximum performance, no runtime checks
const jsReleaseFlags = "-d:release -d:danger " & qualityFlags
const nativeReleaseFlags = "-d:release -d:danger --opt:speed " & qualityFlags
const wasmReleaseFlags = "--backend:c --cpu:wasm32 --os:linux -d:emscripten -d:release -d:danger " & styleFlags

# WASM backend flags (subset - some warnings don't apply to WASM cross-compile)
const wasmFlags = "--backend:c --cpu:wasm32 --os:linux -d:emscripten -d:release " & styleFlags

# Emscripten flags for SharedArrayBuffer support
const emccFlags = """-O3 -msimd128 \
  -I/opt/homebrew/Cellar/nim/2.2.6/nim/lib \
  -sWASM=1 \
  -sMODULARIZE=1 \
  -sEXPORT_NAME='createPhysicsModule' \
  -sIMPORTED_MEMORY=1 \
  -sSHARED_MEMORY=1 \
  -sINITIAL_MEMORY=134217728 \
  -sMAXIMUM_MEMORY=536870912 \
  -sALLOW_MEMORY_GROWTH=1 \
  -sEXPORTED_FUNCTIONS='["_physicsStepRange","_malloc","_free"]' \
  -sEXPORTED_RUNTIME_METHODS='["cwrap"]' \
  -o web/physics.js"""

task worker, "Build the JS worker":
  exec "nim js " & jsFlags & " --out:web/worker.js src/worker.nim"

task app, "Build the web app":
  exec "nim js " & jsFlags & " --out:web/app.js src/app.nim"

task wasm, "Build the physics WASM module":
  exec "nim c " & wasmFlags & " --nimcache:./nimcache_wasm --compileOnly src/physics_wasm.nim"
  exec "emcc nimcache_wasm/*.c " & emccFlags

task all, "Build everything: worker, app, wasm, and native":
  echo "Building worker..."
  exec "nim js " & jsFlags & " --out:web/worker.js src/worker.nim"
  echo "Building app..."
  exec "nim js " & jsFlags & " --out:web/app.js src/app.nim"
  echo "Building WASM physics module..."
  exec "nim c " & wasmFlags & " --nimcache:./nimcache_wasm --compileOnly src/physics_wasm.nim"
  exec "emcc nimcache_wasm/*.c " & emccFlags
  echo "Building native app..."
  exec "nim c " & nativeFlags & " --out:main src/main.nim"
  echo "Build complete. Run with: ./main"

task test, "Run tests":
  exec "nim c -r " & qualityFlags & " tests/test_all.nim"

task release, "Build everything with maximum optimization (no runtime checks)":
  echo "Building release with -d:danger..."
  echo "Building worker..."
  exec "nim js " & jsReleaseFlags & " --out:web/worker.js src/worker.nim"
  echo "Building app..."
  exec "nim js " & jsReleaseFlags & " --out:web/app.js src/app.nim"
  echo "Building WASM physics module..."
  exec "nim c " & wasmReleaseFlags & " --nimcache:./nimcache_wasm --compileOnly src/physics_wasm.nim"
  exec "emcc nimcache_wasm/*.c " & emccFlags
  echo "Building native app..."
  exec "nim c " & nativeReleaseFlags & " --out:main src/main.nim"
  echo "Release build complete. Run with: ./main"
