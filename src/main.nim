# ==============================================================================
# GOOBER GARDEN - NATIVE DESKTOP WRAPPER
# ==============================================================================
#
# ARCHITECTURE EXPLANATION:
# This application uses a hybrid "Native + Web" architecture to enable high-performance
# features (SharedArrayBuffer) that are restricted in modern browsers.
#
# 1. Local HTTP Server (Port 8089):
#    - We spawn a lightweight async HTTP server.
#    - Its primary purpose is to serve the web content with specific security headers.
#    - Serving from "file://" protocol blocks SharedArrayBuffer in most browsers.
#
# 2. Native Window (WebUI):
#    - We use the WebUI library to open a native browser window.
#    - This window navigates to "http://localhost:8089".
#
# SECURITY HEADERS (COOP/COEP):
# To enable SharedArrayBuffer (required for zero-copy worker synchronization),
# the browser requires the page to be "Cross-Origin Isolated". This is achieved
# by serving the following headers:
#
# - Cross-Origin-Opener-Policy: same-origin
# - Cross-Origin-Embedder-Policy: require-corp
#
# Without these headers, `SharedArrayBuffer` is undefined in the JS environment.
# ==============================================================================

import webui
import std/[os, asynchttpserver, asyncdispatch, net, strutils, tables]

const ServerPort = 8089

# MIME types by extension
const MimeTypes = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript",
  ".wasm": "application/wasm",
  ".wgsl": "text/plain",
}.toTable

# Static file registry: path -> content
# Files are embedded at compile time via staticRead
const StaticFiles = {
  "/index.html": staticRead("../web/index.html"),
  "/app.js": staticRead("../web/app.js"),
  "/worker.js": staticRead("../web/worker.js"),
  "/physics.js": staticRead("../web/physics.js"),
  "/physics.wasm": staticRead("../web/physics.wasm"),
  "/shaders/bin-count.wgsl": staticRead("../web/shaders/bin-count.wgsl"),
  "/shaders/prefix-sum.wgsl": staticRead("../web/shaders/prefix-sum.wgsl"),
  "/shaders/prefix-sum-local.wgsl": staticRead("../web/shaders/prefix-sum-local.wgsl"),
  "/shaders/prefix-sum-blocks.wgsl": staticRead("../web/shaders/prefix-sum-blocks.wgsl"),
  "/shaders/prefix-sum-final.wgsl": staticRead("../web/shaders/prefix-sum-final.wgsl"),
  "/shaders/bin-scatter.wgsl": staticRead("../web/shaders/bin-scatter.wgsl"),
  "/shaders/cell-stats.wgsl": staticRead("../web/shaders/cell-stats.wgsl"),
  "/shaders/forces.wgsl": staticRead("../web/shaders/forces.wgsl"),
  "/shaders/density.wgsl": staticRead("../web/shaders/density.wgsl"),
  "/shaders/integrate.wgsl": staticRead("../web/shaders/integrate.wgsl"),
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
  echo "🌐 Opening browser to ", url
  window.show(url)

  # Wait for window to close
  wait()

when isMainModule:
  main()
