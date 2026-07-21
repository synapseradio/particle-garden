# ==============================================================================
# WGSL SHADER BUNDLER
# ==============================================================================
#
# This tool preprocesses WGSL shaders by:
# 1. Resolving //! import directives (module system)
# 2. Substituting {{PLACEHOLDER}} values from shader_config.nim
# 3. Validating struct layouts match gpu_types.nim (Phase 2)
#
# USAGE:
#   nim c -r tools/wgsl_bundle.nim
#
# The bundler reads from web/shaders/src/*.wgsl, resolves imports from
# web/shaders/modules/, and writes bundled output to web/shaders/*.wgsl.
#
# IMPORT SYNTAX:
#   //! import particle
#   //! import cell_index
#
# This directive must appear at the start of a line. The module name maps to
# web/shaders/modules/{name}.wgsl. Imports are topologically sorted and
# deduplicated.
#
# ==============================================================================

import std/[os, strutils, tables, sets, times, hashes]
import shader_config
import gpu_types

const
  ModulesDir = "web/shaders/modules"
  SrcDir = "web/shaders/src"
  OutDir = "web/shaders"

type
  Module = object
    name: string
    path: string
    content: string
    imports: seq[string]

# ==============================================================================
# IMPORT PARSING
# ==============================================================================

proc parseImports(content: string): seq[string] =
  ## Extract module names from //! import directives.
  ## Returns deduplicated list in declaration order.
  var seen: HashSet[string]
  for line in content.splitLines:
    let trimmed = line.strip
    if trimmed.startsWith("//! import "):
      let moduleName = trimmed[11..^1].strip
      if moduleName notin seen:
        seen.incl(moduleName)
        result.add(moduleName)

proc stripImportDirectives(content: string): string =
  ## Remove //! import lines from shader source.
  var lines: seq[string]
  for line in content.splitLines:
    if not line.strip.startsWith("//! import"):
      lines.add(line)
  result = lines.join("\n")

# ==============================================================================
# MODULE LOADING
# ==============================================================================

proc loadModule(name: string, loaded: var Table[string, Module]): Module =
  ## Load a module by name, caching in `loaded` table.
  if name in loaded:
    return loaded[name]

  let path = ModulesDir / name & ".wgsl"
  if not fileExists(path):
    quit "Error: Module not found: " & path

  result.name = name
  result.path = path
  result.content = readFile(path)
  result.imports = parseImports(result.content)
  loaded[name] = result

# ==============================================================================
# DEPENDENCY RESOLUTION (Topological Sort)
# ==============================================================================

proc topologicalSort(modules: Table[string, Module]): seq[string] =
  ## Kahn's algorithm for dependency ordering.
  ## Returns module names in order such that dependencies come before dependents.
  var inDegree: Table[string, int]
  var graph: Table[string, seq[string]]  # dependency -> dependents

  # Initialize in-degree for all modules
  for name in modules.keys:
    if name notin inDegree:
      inDegree[name] = 0

  # Build graph and count in-degrees
  for name, m in modules:
    for dep in m.imports:
      if dep notin graph:
        graph[dep] = @[]
      graph[dep].add(name)
      inDegree[name] = inDegree.getOrDefault(name, 0) + 1

  # Start with modules that have no dependencies
  var queue: seq[string]
  for name, deg in inDegree:
    if deg == 0:
      queue.add(name)

  # Process queue
  while queue.len > 0:
    let current = queue.pop
    result.add(current)
    for dependent in graph.getOrDefault(current, @[]):
      inDegree[dependent] -= 1
      if inDegree[dependent] == 0:
        queue.add(dependent)

  # Check for cycles
  if result.len != modules.len:
    var missing: seq[string]
    for name in modules.keys:
      if name notin result:
        missing.add(name)
    quit "Error: Circular dependency detected involving: " & missing.join(", ")

# ==============================================================================
# PLACEHOLDER SUBSTITUTION
# ==============================================================================

# Get placeholder map from shader_config.nim (centralized configuration)
let PLACEHOLDERS = getPlaceholderMap()

proc substitutePlaceholders(code: string, shaderName: string): string =
  ## Replace {{PLACEHOLDER}} values with configured constants from shader_config.nim.
  result = code

  # Shader-specific workgroup size
  let workgroupKey = "WORKGROUP_SIZE_" & shaderName.toUpperAscii.replace("-", "_")
  if workgroupKey in PLACEHOLDERS:
    result = result.replace("{{WORKGROUP_SIZE}}", PLACEHOLDERS[workgroupKey])

  # All other placeholders from config
  for key, value in PLACEHOLDERS:
    result = result.replace("{{" & key & "}}", value)

  # Check for unreplaced placeholders
  if "{{" in result:
    let startIdx = result.find("{{")
    let endIdx = result.find("}}", startIdx)
    if endIdx > startIdx:
      let placeholder = result[startIdx..endIdx+1]
      quit "Error: Unreplaced placeholder in " & shaderName & ": " & placeholder

# ==============================================================================
# SHADER BUNDLING
# ==============================================================================

proc bundle(srcPath: string): string =
  ## Bundle a shader with all its dependencies.
  let content = readFile(srcPath)
  let imports = parseImports(content)
  let shaderName = srcPath.extractFilename.replace(".wgsl", "")

  # If no imports, just substitute placeholders and return
  if imports.len == 0:
    return substitutePlaceholders(content, shaderName)

  # Load all required modules (recursive)
  var loaded: Table[string, Module]
  var toProcess = imports
  while toProcess.len > 0:
    let name = toProcess.pop
    if name notin loaded:
      let m = loadModule(name, loaded)
      for dep in m.imports:
        if dep notin loaded:
          toProcess.add(dep)

  # Topologically sort modules
  let order = topologicalSort(loaded)

  # Build output
  var output = "// =============================================================================\n"
  output &= "// AUTO-GENERATED BY tools/wgsl_bundle.nim - DO NOT EDIT DIRECTLY\n"
  output &= "// =============================================================================\n"
  output &= "// Source: " & srcPath & "\n"
  output &= "// Bundled modules: " & order.join(", ") & "\n"
  output &= "// Generated: " & $now() & "\n"
  output &= "// =============================================================================\n\n"

  # Add modules in dependency order
  for name in order:
    let m = loaded[name]
    output &= "// ─────────────────────────────────────────────────────────────────────────────\n"
    output &= "// MODULE: " & name & "\n"
    output &= "// Source: " & m.path & "\n"
    output &= "// ─────────────────────────────────────────────────────────────────────────────\n\n"
    output &= stripImportDirectives(m.content).strip & "\n\n"

  # Add main shader (with imports stripped)
  output &= "// ─────────────────────────────────────────────────────────────────────────────\n"
  output &= "// MAIN SHADER\n"
  output &= "// ─────────────────────────────────────────────────────────────────────────────\n\n"
  output &= stripImportDirectives(content)

  # Substitute placeholders
  result = substitutePlaceholders(output, shaderName)

# ==============================================================================
# INCREMENTAL BUILD SUPPORT
# ==============================================================================

const PlaceholderSources = [
  "src/shader_config.nim",
  "src/field_core.nim",
  "src/bloom_core.nim",
  "src/colormap_core.nim",
]
  ## The Nim modules whose constants feed {{PLACEHOLDER}} substitution
  ## (shader_config.getPlaceholderMap and the pure modules it draws from).
  ## An edit to any of them changes bundled output without touching a .wgsl
  ## file, so needsRebuild must treat them as inputs — otherwise a tuning
  ## edit ships silently stale shaders.

proc needsRebuild(srcPath, outPath: string): bool =
  ## Check if shader needs rebuilding based on file modification times.
  if not fileExists(outPath):
    return true

  let outMtime = getLastModificationTime(outPath)

  # Check source file
  if getLastModificationTime(srcPath) > outMtime:
    return true

  # Check imported modules
  let content = readFile(srcPath)
  for name in parseImports(content):
    let modPath = ModulesDir / name & ".wgsl"
    if fileExists(modPath) and getLastModificationTime(modPath) > outMtime:
      return true

  # Check the Nim sources that feed placeholder substitution
  for placeholderSource in PlaceholderSources:
    if fileExists(placeholderSource) and
        getLastModificationTime(placeholderSource) > outMtime:
      return true

  return false

# ==============================================================================
# GENERATED STRUCT MODULES
# ==============================================================================
# WGSL struct modules generated from the Nim layout tables in gpu_types.nim, the
# single source of truth. Emitted into ModulesDir before import resolution so a
# shader can `//! import` them. Kept out of version control (see .gitignore);
# the bundler recreates them every build.

proc generateStructModule(name: string, header, body: string) =
  ## Write ModulesDir/<name>.wgsl only when its content changes, so mtime-based
  ## incremental rebuilds still fire exactly when the layout actually changed.
  let path = ModulesDir / name & ".wgsl"
  let content = header & body
  if not fileExists(path) or readFile(path) != content:
    writeFile(path, content)
    echo "  Generated module: ", name, ".wgsl"

proc structModuleHeader(moduleName, layoutName: string): string =
  "// =============================================================================\n" &
  "// MODULE: " & moduleName & "\n" &
  "// AUTO-GENERATED from src/gpu_types.nim (" & layoutName & ") - DO NOT EDIT\n" &
  "// Regenerated by tools/wgsl_bundle.nim on every build.\n" &
  "// =============================================================================\n\n"

proc generateStructModules() =
  ## Regenerate every WGSL struct module owned by gpu_types.nim.
  generateStructModule("sim_params",
    structModuleHeader("sim_params", "SimParamsLayout"),
    toWgslStruct(SimParamsLayout))
  generateStructModule("render_params",
    structModuleHeader("render_params", "RenderParamsLayout"),
    toWgslStruct(RenderParamsLayout))
  generateStructModule("fade_params",
    structModuleHeader("fade_params", "FadeParamsLayout"),
    toWgslStruct(FadeParamsLayout))
  generateStructModule("field_params",
    structModuleHeader("field_params", "FieldParamsLayout"),
    toWgslStruct(FieldParamsLayout))
  generateStructModule("bloom_params",
    structModuleHeader("bloom_params", "BloomParamsLayout"),
    toWgslStruct(BloomParamsLayout))
  generateStructModule("tonemap_params",
    structModuleHeader("tonemap_params", "TonemapParamsLayout"),
    toWgslStruct(TonemapParamsLayout))

# ==============================================================================
# MAIN
# ==============================================================================

proc main() =
  echo "WGSL Shader Bundler"
  echo "==================="

  # Check directories exist
  if not dirExists(SrcDir):
    echo "Note: Source directory ", SrcDir, " does not exist yet."
    echo "Creating passthrough for existing shaders..."

    # In bootstrap mode, just copy existing shaders
    # This allows gradual migration
    echo "No source shaders found. Run 'nimble all' after migrating shaders to src/."
    return

  # Generate struct modules from gpu_types.nim before resolving imports.
  generateStructModules()

  var bundled = 0
  var skipped = 0

  for srcFile in walkFiles(SrcDir / "*.wgsl"):
    let name = srcFile.extractFilename
    let outPath = OutDir / name

    if needsRebuild(srcFile, outPath):
      echo "  Bundling: ", name
      let output = bundle(srcFile)
      writeFile(outPath, output)
      bundled += 1
    else:
      skipped += 1

  echo ""
  echo "Summary: ", bundled, " bundled, ", skipped, " unchanged"

when isMainModule:
  main()
