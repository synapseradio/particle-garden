import webui
import std/[os, asynchttpserver, asyncdispatch, net, strutils]

const HTML_CONTENT = staticRead("../web/index.html")
const PORT = 8089

# Custom HTTP server that serves with COOP/COEP headers for SharedArrayBuffer
proc startCrossOriginIsolatedServer(): Future[void] {.async.} =
  var server = newAsyncHttpServer()
  
  proc handler(req: Request) {.async.} =
    # Set Cross-Origin Isolation headers for SharedArrayBuffer support
    let headers = newHttpHeaders([
      ("Content-Type", "text/html; charset=utf-8"),
      ("Cross-Origin-Opener-Policy", "same-origin"),
      ("Cross-Origin-Embedder-Policy", "require-corp")
    ])
    
    await req.respond(Http200, HTML_CONTENT, headers)
  
  echo "🦠 Starting Cross-Origin Isolated server on http://localhost:", PORT
  echo "   Headers: COOP=same-origin, COEP=require-corp"
  echo "   SharedArrayBuffer: ENABLED"
  
  server.listen(Port(PORT))
  while true:
    if server.shouldAcceptRequest():
      await server.acceptRequest(handler)
    else:
      await sleepAsync(10)

proc main() =
  # Start the HTTP server in background
  asyncCheck startCrossOriginIsolatedServer()
  
  # Give server a moment to start
  sleep(100)
  
  # Create webui window
  let window = newWindow()
  window.setSize(1400, 900)
  
  # Navigate to our cross-origin isolated server
  let url = "http://localhost:" & $PORT
  echo "🌐 Opening browser to ", url
  window.show(url)
  
  # Wait for window to close
  wait()

when isMainModule:
  main()
