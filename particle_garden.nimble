# Package
version       = "1.0.2"
author        = "Particle Garden"
description   = "Particle life simulation with WebGPU compute shaders"
license       = "MIT"
srcDir        = "src"
bin           = @["main"]
binDir        = "."

# Dependencies
requires "nim >= 2.0.0 & < 3.0.0"
# Pin to webui 2.4.2 tag (commit hash for reproducibility)
# Tag 2.4.2 = commit 552a3e3 (upstream version string says 2.4.0.0)
requires "webui#552a3e3"

# Compiler flags for style and warning enforcement
const styleFlags = "--styleCheck:error --styleCheck:usages"
# Single line required - multiline strings with backslash break on Windows CI
const warningFlags = "--warningAsError:Deprecated --warningAsError:BareExcept --warningAsError:CStringConv --warningAsError:EnumConv --warningAsError:HoleEnumConv --warningAsError:SmallLshouldNotBeUsed --warningAsError:ProveInit --warningAsError:UnusedImport --warningAsError:Effect --hint:XDeclaredButNotUsed:on"

# Combined quality flags for all builds
const qualityFlags = styleFlags & " " & warningFlags

# JS backend flags (for nim js builds)
const jsFlags = "-d:release " & qualityFlags

# Native backend flags (for nim c builds)
const nativeFlags = "-d:release --opt:speed " & qualityFlags

# Release flags - optimized builds with runtime checks preserved
const jsReleaseFlags = "-d:release " & qualityFlags
const nativeReleaseFlags = "-d:release --opt:speed " & qualityFlags

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

task release, "Build optimized release":
  echo "Building release..."
  echo "Building app..."
  exec "nim js " & jsReleaseFlags & " --out:web/app.js src/app.nim"
  echo "Building native app..."
  exec "nim c " & nativeReleaseFlags & " --out:main src/main.nim"
  echo "Release build complete. Run with: ./main"
