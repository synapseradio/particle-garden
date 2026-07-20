# ==============================================================================
# PARTICLE GARDEN - NATIVE DESKTOP WRAPPER
# ==============================================================================
#
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
#
# SECURITY HEADERS (COOP/COEP):
# The server provides Cross-Origin-Opener-Policy and Cross-Origin-Embedder-Policy
# headers to enable SharedArrayBuffer (used for memory buffer initialization).
#
# ==============================================================================

import webui
import std/[os, asynchttpserver, asyncdispatch, net, strutils, tables]

const ServerPort = 8089

# MIME types by extension
const MimeTypes = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript",
  ".wgsl": "text/plain",
}.toTable

# Static file registry: path -> content
# Files are embedded at compile time via staticRead
const StaticFiles = {
  "/index.html": staticRead("../web/index.html"),
  "/app.js": staticRead("../web/app.js"),
  # AoS compute pipeline shaders
  "/shaders/bin-count.wgsl": staticRead("../web/shaders/bin-count.wgsl"),
  "/shaders/prefix-sum-local.wgsl": staticRead("../web/shaders/prefix-sum-local.wgsl"),
  "/shaders/prefix-sum-blocks.wgsl": staticRead("../web/shaders/prefix-sum-blocks.wgsl"),
  "/shaders/prefix-sum-final.wgsl": staticRead("../web/shaders/prefix-sum-final.wgsl"),
  "/shaders/bin-scatter.wgsl": staticRead("../web/shaders/bin-scatter.wgsl"),  # Merged AoS
  "/shaders/forces.wgsl": staticRead("../web/shaders/forces.wgsl"),
  "/shaders/forces-sph.wgsl": staticRead("../web/shaders/forces-sph.wgsl"),  # SPH fluid force pass
  "/shaders/integrate.wgsl": staticRead("../web/shaders/integrate.wgsl"),  # Merged AoS
  # Reaction-diffusion field passes (S8). field-composite.wgsl is staticRead into
  # app.js by webgpu_render (a render shader), so it is deliberately not served here.
  "/shaders/field-deposit.wgsl": staticRead("../web/shaders/field-deposit.wgsl"),
  "/shaders/field-resolve.wgsl": staticRead("../web/shaders/field-resolve.wgsl"),
  "/shaders/rd-step.wgsl": staticRead("../web/shaders/rd-step.wgsl"),
  "/shaders/field-force.wgsl": staticRead("../web/shaders/field-force.wgsl"),
  "/shaders/render.wgsl": staticRead("../web/shaders/render.wgsl"),
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

    # Normalize path: "/" -> "/index.html"
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
  # Start the HTTP server in a separate thread
  var thread: Thread[void]
  createThread(thread, serverThread)

  # Give server a moment to start
  sleep(100)

  # Create webui window
  let window = newWindow()
  window.setSize(1400, 900)

  # Navigate to our cross-origin isolated server
  let url = "http://127.0.0.1:" & $ServerPort
  echo "Opening browser to ", url
  window.show(url)

  # Wait for window to close
  wait()

when isMainModule:
  main()
