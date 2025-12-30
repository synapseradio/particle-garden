# Package
version       = "0.1.0"
author        = "Goober Garden"
description   = "Particle life simulation with WebGPU compute shaders"
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

task app, "Build the web app":
  exec "nim js " & jsFlags & " --out:web/app.js src/app.nim"

task all, "Build everything: app and native":
  echo "Building app..."
  exec "nim js " & jsFlags & " --out:web/app.js src/app.nim"
  echo "Building native app..."
  exec "nim c " & nativeFlags & " --out:main src/main.nim"
  echo "Build complete. Run with: ./main"

task test, "Run tests":
  exec "nim c -r " & qualityFlags & " tests/test_all.nim"

task release, "Build everything with maximum optimization (no runtime checks)":
  echo "Building release with -d:danger..."
  echo "Building app..."
  exec "nim js " & jsReleaseFlags & " --out:web/app.js src/app.nim"
  echo "Building native app..."
  exec "nim c " & nativeReleaseFlags & " --out:main src/main.nim"
  echo "Release build complete. Run with: ./main"
