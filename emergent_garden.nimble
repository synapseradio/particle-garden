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
