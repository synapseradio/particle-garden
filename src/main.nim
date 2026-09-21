# ARCHITECTURE: WebGPU-only physics with native window wrapper.
#
# This application uses a hybrid "Native + Web" architecture:
#
# 1. Local HTTP Server (Port 8089):
#    - Lightweight async HTTP server serving web content
#    - Provides COOP/COEP headers for SharedArrayBuffer support
#
# 2. Native Window (WebUI):
#    - Opens a native browser window pointing to localhost:8089
#    - Skipped under --serve: the server runs alone until killed
#
# SECURITY HEADERS (COOP/COEP):
# The server provides Cross-Origin-Opener-Policy and Cross-Origin-Embedder-Policy
# headers to enable SharedArrayBuffer (used for memory buffer initialization).

import webui
import std/[os, asynchttpserver, asyncdispatch, net, strutils, tables]

const ServerPort = 8089

const MimeTypes = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript",
  ".css": "text/css; charset=utf-8",
  ".wgsl": "text/plain",
}.toTable

# Static file registry: path -> content
# Files are embedded at compile time via staticRead
const StaticFiles = {
  "/index.html": staticRead("../web/index.html"),
  "/app.js": staticRead("../web/app.js"),
  # Solid control panel, bundled by web-ui/build.ts (Bun). Build artifacts,
  # not checked in: `just happen` rebuilds them before this compile, so a
  # missing file fails here instead of shipping a stale UI.
  "/ui-bundle.js": staticRead("../web/ui-bundle.js"),
  "/ui-bundle.css": staticRead("../web/ui-bundle.css"),
  # AoS compute pipeline shaders
  "/shaders/bin-count.wgsl": staticRead("../web/shaders/bin-count.wgsl"),
  "/shaders/prefix-sum-local.wgsl": staticRead("../web/shaders/prefix-sum-local.wgsl"),
  "/shaders/prefix-sum-blocks.wgsl": staticRead("../web/shaders/prefix-sum-blocks.wgsl"),
  "/shaders/prefix-sum-final.wgsl": staticRead("../web/shaders/prefix-sum-final.wgsl"),
  "/shaders/bin-scatter.wgsl": staticRead("../web/shaders/bin-scatter.wgsl"),  # Merged AoS
  "/shaders/forces.wgsl": staticRead("../web/shaders/forces.wgsl"),
  "/shaders/forces-sph.wgsl": staticRead("../web/shaders/forces-sph.wgsl"),  # SPH fluid force pass
  "/shaders/integrate.wgsl": staticRead("../web/shaders/integrate.wgsl"),  # Merged AoS
  # Reaction-diffusion field passes.
  "/shaders/field-seed.wgsl": staticRead("../web/shaders/field-seed.wgsl"),
  "/shaders/field-deposit.wgsl": staticRead("../web/shaders/field-deposit.wgsl"),
  "/shaders/field-resolve.wgsl": staticRead("../web/shaders/field-resolve.wgsl"),
  "/shaders/rd-step.wgsl": staticRead("../web/shaders/rd-step.wgsl"),
  "/shaders/field-force.wgsl": staticRead("../web/shaders/field-force.wgsl"),
  # The bodies passes.
  "/shaders/body-force.wgsl": staticRead("../web/shaders/body-force.wgsl"),
  "/shaders/body-integrate.wgsl": staticRead("../web/shaders/body-integrate.wgsl"),
  # Long-range mesh chain. All five are served even though the shipped world
  # dispatches none of them: the pipelines are created at init, before any
  # strength is read.
  "/shaders/lr-deposit.wgsl": staticRead("../web/shaders/lr-deposit.wgsl"),
  "/shaders/lr-fft-rows.wgsl": staticRead("../web/shaders/lr-fft-rows.wgsl"),
  "/shaders/lr-fft-cols.wgsl": staticRead("../web/shaders/lr-fft-cols.wgsl"),
  "/shaders/lr-kernel.wgsl": staticRead("../web/shaders/lr-kernel.wgsl"),
  "/shaders/lr-force.wgsl": staticRead("../web/shaders/lr-force.wgsl"),
}.toTable

proc getMimeType(path: string): string =
  for ext, mime in MimeTypes:
    if path.endsWith(ext):
      return mime
  return "text/plain"

proc startCrossOriginIsolatedServer(): Future[void] {.async.} =
  var server = newAsyncHttpServer()

  proc handler(req: Request) {.async.} =
    echo "[DEBUG] Request: ", req.reqMethod, " ", req.url.path

    let path = if req.url.path == "/": "/index.html" else: req.url.path

    if StaticFiles.hasKey(path):
      let content = StaticFiles[path]
      let headers = newHttpHeaders([
        ("Content-Type", getMimeType(path)),
        ("Cross-Origin-Opener-Policy", "same-origin"),
        ("Cross-Origin-Embedder-Policy", "require-corp")
      ])
      await req.respond(Http200, content, headers)
    else:
      await req.respond(Http404, "Not Found", newHttpHeaders())

  echo "🦠 Starting Cross-Origin Isolated server on http://127.0.0.1:", ServerPort
  echo "   Headers: COOP=same-origin, COEP=require-corp"
  echo "   SharedArrayBuffer: ENABLED"

  await server.serve(Port(ServerPort), handler)

proc serverThread() {.thread.} =
  waitFor startCrossOriginIsolatedServer()

proc main() =
  let args = commandLineParams()
  let serveOnly = args == @["--serve"]
  if args.len > 0 and not serveOnly:
    stderr.writeLine "usage: main [--serve]"
    quit(2)

  var thread: Thread[void]
  createThread(thread, serverThread)

  if serveOnly:
    echo "Serving http://127.0.0.1:", ServerPort, " with no window. Ctrl-C to stop."
    joinThread(thread)
    return

  sleep(100)

  let window = newWindow()
  window.setSize(1400, 900)

  let url = "http://127.0.0.1:" & $ServerPort
  echo "Opening browser to ", url
  window.show(url)

  wait()

when isMainModule:
  main()
