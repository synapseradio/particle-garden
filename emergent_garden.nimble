# Package
version       = "0.1.0"
author        = "Goober Garden"
description   = "Particle life simulation with SharedArrayBuffer workers"
license       = "MIT"
srcDir        = "src"
bin           = @["emergent_garden"]

# Dependencies
requires "nim >= 2.0.0"
requires "webui >= 2.4.0"

task worker, "Build the JS worker":
  exec "nim js -d:release -d:danger --out:web/worker.js src/worker.nim"

task wasm, "Build the physics WASM module":
  # Step 1: Compile Nim to C for WASM32 target
  exec "nim c --backend:c --cpu:wasm32 --os:linux --nimcache:./nimcache_wasm --compileOnly -d:emscripten -d:release src/physics_wasm.nim"
  # Step 2: Compile C to WASM with SharedArrayBuffer support
  exec """emcc nimcache_wasm/*.c -O3 \
    -I/opt/homebrew/Cellar/nim/2.2.6/nim/lib \
    -sWASM=1 \
    -sIMPORTED_MEMORY=1 \
    -sSHARED_MEMORY=1 \
    -sINITIAL_MEMORY=134217728 \
    -sMAXIMUM_MEMORY=134217728 \
    -sALLOW_MEMORY_GROWTH=0 \
    -sEXPORTED_FUNCTIONS='["_physicsStepRange","_malloc","_free"]' \
    -sEXPORTED_RUNTIME_METHODS='["cwrap"]' \
    -o web/physics.js"""
