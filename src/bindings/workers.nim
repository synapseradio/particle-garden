# ==============================================================================
# WORKERS - WEB WORKER API BINDINGS
# ==============================================================================
#
# This module provides idiomatic Nim bindings for the Web Worker API.
#
# EXPORTS:
# - Worker type and constructor
# - MessageEvent type for message handling
# - WorkerGlobalScope for worker context
# - postMessage, terminate methods
# - Event handlers: onmessage, onerror
# - self reference for worker context
#
# USAGE:
#   import bindings/workers
#
#   # In main thread:
#   let worker = newWorker("worker.js")
#   worker.onmessage = proc(e: MessageEvent) = echo e.data
#   worker.postMessage(myData)
#
#   # In worker:
#   self.onmessage = proc(e: MessageEvent) = ...
#   self.postMessage(result)
#
# ==============================================================================

from std/jsffi import JsObject

# ==============================================================================
# SECTION 1: TYPES
# ==============================================================================

type
  Worker* = ref object of JsObject
    ## Web Worker - runs scripts in background threads.
    ## Workers have their own global scope and event loop.

  MessageEvent* = ref object of JsObject
    ## Event containing data from postMessage.
    ## Received in onmessage handlers on both Worker and WorkerGlobalScope.
    data* {.importjs: "data".}: JsObject
      ## The message payload sent via postMessage.
    origin* {.importjs: "origin".}: cstring
      ## Origin of the message sender.
    lastEventId* {.importjs: "lastEventId".}: cstring
      ## Last event ID (for Server-Sent Events).
    source* {.importjs: "source".}: JsObject
      ## Reference to the message sender (if available).
    ports* {.importjs: "ports".}: JsObject
      ## Array of MessagePort objects.

  ErrorEvent* = ref object of JsObject
    ## Event containing error information from worker.
    message* {.importjs: "message".}: cstring
      ## Error message.
    filename* {.importjs: "filename".}: cstring
      ## Script filename where error occurred.
    lineno* {.importjs: "lineno".}: int
      ## Line number of error.
    colno* {.importjs: "colno".}: int
      ## Column number of error.
    error* {.importjs: "error".}: JsObject
      ## The Error object (if available).

  WorkerGlobalScope* = ref object of JsObject
    ## Global scope inside a Worker.
    ## Accessible via the `self` global variable in workers.

  MessageEventHandler* = proc(event: MessageEvent) {.closure.}
    ## Callback type for message events.

  ErrorEventHandler* = proc(event: ErrorEvent) {.closure.}
    ## Callback type for error events.

# ==============================================================================
# SECTION 2: WORKER CONSTRUCTORS
# ==============================================================================

proc newWorker*(scriptUrl: cstring): Worker {.importjs: "new Worker(#)".}
  ## Create a new Worker that runs the specified script.
  ##
  ## Parameters:
  ## - scriptUrl: URL of the script to run in the worker
  ##
  ## Example:
  ##   let worker = newWorker("physics-worker.js")

proc newWorkerWithOptions*(scriptUrl: cstring, options: JsObject): Worker {.importjs: "new Worker(#, #)".}
  ## Create a new Worker with options.
  ##
  ## Parameters:
  ## - scriptUrl: URL of the script to run
  ## - options: Object with type, credentials, name properties
  ##
  ## Example:
  ##   let opts = newJsObject()
  ##   opts["type"] = "module".cstring.toJs
  ##   let worker = newWorkerWithOptions("worker.js", opts)

# ==============================================================================
# SECTION 3: WORKER METHODS
# ==============================================================================

proc postMessage*(worker: Worker, message: JsObject) {.importjs: "#.postMessage(#)".}
  ## Send a message to the worker.
  ##
  ## Parameters:
  ## - message: Data to send (will be cloned unless transferable)
  ##
  ## Example:
  ##   worker.postMessage({"type": "init", "data": particles}.toJs)

proc postMessageTransfer*(worker: Worker, message: JsObject, transfer: JsObject) {.importjs: "#.postMessage(#, #)".}
  ## Send a message with transferable objects.
  ##
  ## Parameters:
  ## - message: Data to send
  ## - transfer: Array of Transferable objects to transfer ownership
  ##
  ## Transferable objects include: ArrayBuffer, MessagePort, ImageBitmap

proc terminate*(worker: Worker) {.importjs: "#.terminate()".}
  ## Immediately terminate the worker.
  ## The worker thread is killed and cannot be restarted.

# ==============================================================================
# SECTION 4: WORKER EVENT HANDLERS
# ==============================================================================

proc `onmessage=`*(worker: Worker, handler: MessageEventHandler) {.importjs: "#.onmessage = #".}
  ## Set the message event handler for receiving data from worker.
  ##
  ## Example:
  ##   worker.onmessage = proc(e: MessageEvent) =
  ##     let result = e.data
  ##     console.log("Received:", result)

proc `onerror=`*(worker: Worker, handler: ErrorEventHandler) {.importjs: "#.onerror = #".}
  ## Set the error event handler for worker errors.
  ##
  ## Example:
  ##   worker.onerror = proc(e: ErrorEvent) =
  ##     console.error("Worker error:", e.message)

proc `onmessageerror=`*(worker: Worker, handler: MessageEventHandler) {.importjs: "#.onmessageerror = #".}
  ## Set handler for message deserialization errors.

# ==============================================================================
# SECTION 5: WORKER GLOBAL SCOPE (FOR USE INSIDE WORKERS)
# ==============================================================================

var self* {.importjs: "self".}: WorkerGlobalScope
  ## Reference to the worker's global scope (use inside workers).

proc postMessage*(scope: WorkerGlobalScope, message: JsObject) {.importjs: "#.postMessage(#)".}
  ## Send a message from the worker back to the main thread.
  ##
  ## Example (inside worker):
  ##   self.postMessage({"result": computedValue}.toJs)

proc postMessageTransfer*(scope: WorkerGlobalScope, message: JsObject, transfer: JsObject) {.importjs: "#.postMessage(#, #)".}
  ## Send a message with transferables from worker.

proc `onmessage=`*(scope: WorkerGlobalScope, handler: MessageEventHandler) {.importjs: "#.onmessage = #".}
  ## Set the message handler inside a worker.
  ##
  ## Example (inside worker):
  ##   self.onmessage = proc(e: MessageEvent) =
  ##     let task = e.data
  ##     let result = processTask(task)
  ##     self.postMessage(result)

proc `onerror=`*(scope: WorkerGlobalScope, handler: ErrorEventHandler) {.importjs: "#.onerror = #".}
  ## Set the error handler inside a worker.

proc close*(scope: WorkerGlobalScope) {.importjs: "#.close()".}
  ## Close the worker from inside (graceful termination).

# ==============================================================================
# SECTION 6: WORKER GLOBAL PROPERTIES
# ==============================================================================

proc name*(scope: WorkerGlobalScope): cstring {.importjs: "#.name".}
  ## Get the worker's name (if set during construction).

proc location*(scope: WorkerGlobalScope): JsObject {.importjs: "#.location".}
  ## Get the worker's WorkerLocation object.

proc navigator*(scope: WorkerGlobalScope): JsObject {.importjs: "#.navigator".}
  ## Get the worker's WorkerNavigator object.

# ==============================================================================
# SECTION 7: IMPORT SCRIPTS (FOR WORKERS)
# ==============================================================================

proc importScripts*(urls: varargs[cstring]) {.importjs: "importScripts(@)".}
  ## Import one or more scripts into the worker's scope (classic workers only).
  ##
  ## Example:
  ##   importScripts("lib/math.js", "lib/utils.js")

# ==============================================================================
# SECTION 8: DEDICATED WORKER UTILITIES
# ==============================================================================

proc isWorkerContext*(): bool {.importjs: "(typeof WorkerGlobalScope !== 'undefined' && self instanceof WorkerGlobalScope)".}
  ## Check if code is running inside a Worker context.

proc isMainThread*(): bool {.importjs: "(typeof Window !== 'undefined' && self instanceof Window)".}
  ## Check if code is running in the main browser thread.

# ==============================================================================
# SECTION 9: STRUCTURED CLONE ALGORITHM HELPERS
# ==============================================================================

proc structuredClone*(value: JsObject): JsObject {.importjs: "structuredClone(#)".}
  ## Create a deep clone using the structured clone algorithm.
  ## This is the same algorithm used by postMessage.

proc structuredCloneTransfer*(value: JsObject, transfer: JsObject): JsObject {.importjs: "structuredClone(#, {transfer: #})".}
  ## Clone with transfer of ownership for transferable objects.

# ==============================================================================
# SECTION 10: TYPE ALIASES FOR MIGRATION
# ==============================================================================

# These aliases enable gradual migration from inline types to bindings module

type
  WebWorker* = Worker
    ## Alias for Worker type.

  WorkerMessageEvent* = MessageEvent
    ## Alias for MessageEvent type.

  WorkerErrorEvent* = ErrorEvent
    ## Alias for ErrorEvent type.

  WorkerScope* = WorkerGlobalScope
    ## Alias for WorkerGlobalScope type.
