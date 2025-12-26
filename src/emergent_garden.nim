# ==============================================================================
# EMERGENT GARDEN - NATIVE DESKTOP WRAPPER
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
import std/[os, asynchttpserver, asyncdispatch, net, strutils]

const ServerPort = 8089

# Custom HTTP server that serves with COOP/COEP headers for SharedArrayBuffer
proc startCrossOriginIsolatedServer(): Future[void] {.async.} =
  var server = newAsyncHttpServer()

  proc handler(req: Request) {.async.} =
    echo "[DEBUG] Request: ", req.reqMethod, " ", req.url.path

    var path = req.url.path
    if path == "/": path = "/index.html"

    let filePath = "web" & path

    if fileExists(filePath):
      var contentType = "text/plain"
      if filePath.endsWith(".html"): contentType = "text/html; charset=utf-8"
      elif filePath.endsWith(".js"): contentType = "application/javascript"

      # Set Cross-Origin Isolation headers for SharedArrayBuffer support
      let headers = newHttpHeaders([
        ("Content-Type", contentType),
        ("Cross-Origin-Opener-Policy", "same-origin"),
        ("Cross-Origin-Embedder-Policy", "require-corp")
      ])

      await req.respond(Http200, readFile(filePath), headers)
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
