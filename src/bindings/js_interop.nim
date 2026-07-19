# ==============================================================================
# JS INTEROP - FOUNDATION BINDINGS MODULE
# ==============================================================================
#
# This module provides the foundation for Nim-to-JavaScript interop used across
# all other bindings modules. It centralizes common patterns and utilities.
#
# EXPORTS:
# - JsObject utility procs (isNil, isUndefined, toJs conversions)
# - Console bindings (log, warn, error, debug, info)
# - GlobalThis access for browser globals
# - Promise/Future interop utilities
# - Common type conversion patterns
# - Performance timing utilities
#
# USAGE:
#   import bindings/js_interop
#
# All other bindings modules should import this module for common utilities.
#
# ==============================================================================

import std/jsffi
import std/asyncjs

# ==============================================================================
# SECTION 1: UNDEFINED AND NULL HANDLING
# ==============================================================================

# JavaScript undefined value
var jsUndefined* {.importjs: "undefined".}: JsObject

# JavaScript null value
var jsNull* {.importjs: "null".}: JsObject

proc isUndefined*(obj: JsObject): bool {.importjs: "(# === undefined)".}
  ## Check if a JsObject is JavaScript undefined.

proc isNull*(obj: JsObject): bool {.importjs: "(# === null)".}
  ## Check if a JsObject is JavaScript null.

proc isNullOrUndefined*(obj: JsObject): bool {.importjs: "(# == null)".}
  ## Check if a JsObject is null or undefined (uses loose equality).

proc isDefined*(obj: JsObject): bool {.importjs: "(# !== undefined)".}
  ## Check if a JsObject is defined (not undefined).

# ==============================================================================
# SECTION 2: TYPE CHECKING UTILITIES
# ==============================================================================

proc jsTypeof*(obj: JsObject): cstring {.importjs: "(typeof #)".}
  ## Get the JavaScript typeof result as a string.

proc isJsFunction*(obj: JsObject): bool {.importjs: "(typeof # === 'function')".}
  ## Check if a JsObject is a function.

proc isJsObject*(obj: JsObject): bool {.importjs: "(typeof # === 'object' && # !== null)".}
  ## Check if a JsObject is an object (and not null).

proc isJsArray*(obj: JsObject): bool {.importjs: "Array.isArray(#)".}
  ## Check if a JsObject is an array.

proc isJsString*(obj: JsObject): bool {.importjs: "(typeof # === 'string')".}
  ## Check if a JsObject is a string.

proc isJsNumber*(obj: JsObject): bool {.importjs: "(typeof # === 'number')".}
  ## Check if a JsObject is a number.

proc isJsBoolean*(obj: JsObject): bool {.importjs: "(typeof # === 'boolean')".}
  ## Check if a JsObject is a boolean.

proc instanceOf*(obj: JsObject, constructor: JsObject): bool {.importjs: "(# instanceof #)".}
  ## Check if obj is an instance of constructor.

# ==============================================================================
# SECTION 3: TYPE CONVERSIONS
# ==============================================================================

proc toJsObject*(value: int): JsObject {.importjs: "(#)".}
  ## Convert Nim int to JsObject.

proc toJsObject*(value: float): JsObject {.importjs: "(#)".}
  ## Convert Nim float to JsObject.

proc toJsObject*(value: bool): JsObject {.importjs: "(#)".}
  ## Convert Nim bool to JsObject.

proc toJsObject*(value: cstring): JsObject {.importjs: "(#)".}
  ## Convert cstring to JsObject.

proc toJsObject*(value: string): JsObject {.importjs: "(#)".}
  ## Convert Nim string to JsObject.

proc toInt*(obj: JsObject): int {.importjs: "(#|0)".}
  ## Convert JsObject to int (bitwise OR with 0 for truncation).

proc toFloat*(obj: JsObject): float {.importjs: "(+#)".}
  ## Convert JsObject to float (unary plus).

proc toBool*(obj: JsObject): bool {.importjs: "(!!#)".}
  ## Convert JsObject to bool (double negation for truthiness).

# Generic `to` converter for method-call syntax: obj.to(int), obj.to(float), etc.
proc to*(obj: JsObject, T: typedesc[int]): int {.inline.} = obj.toInt
proc to*(obj: JsObject, T: typedesc[float]): float {.inline.} = obj.toFloat
proc to*(obj: JsObject, T: typedesc[bool]): bool {.inline.} = obj.toBool

proc toCstring*(obj: JsObject): cstring {.importjs: "String(#)".}
  ## Convert JsObject to cstring via String().

proc toJsString*(obj: JsObject): JsObject {.importjs: "String(#)".}
  ## Convert JsObject to JS string object.

proc parseJsonJs*(jsonText: cstring): JsObject {.importjs: "JSON.parse(#)".}
  ## Parse a JSON string to JsObject.

proc stringifyJs*(obj: JsObject): cstring {.importjs: "JSON.stringify(#)".}
  ## Stringify a JsObject to JSON string.

proc stringifyJsPretty*(obj: JsObject, indent: int = 2): cstring {.importjs: "JSON.stringify(#, null, #)".}
  ## Stringify a JsObject to pretty-printed JSON string.

# ==============================================================================
# SECTION 4: OBJECT UTILITIES
# ==============================================================================

proc jsKeys*(obj: JsObject): JsObject {.importjs: "Object.keys(#)".}
  ## Get array of object keys.

proc jsValues*(obj: JsObject): JsObject {.importjs: "Object.values(#)".}
  ## Get array of object values.

proc jsEntries*(obj: JsObject): JsObject {.importjs: "Object.entries(#)".}
  ## Get array of [key, value] pairs.

proc jsAssign*(target: JsObject, source: JsObject): JsObject {.importjs: "Object.assign(#, #)".}
  ## Shallow copy properties from source to target.

proc jsFreeze*(obj: JsObject): JsObject {.importjs: "Object.freeze(#)".}
  ## Freeze an object (make it immutable).

proc hasOwnProperty*(obj: JsObject, key: cstring): bool {.importjs: "#.hasOwnProperty(#)".}
  ## Check if object has own property (not inherited).

proc deleteProperty*(obj: JsObject, key: cstring) {.importjs: "delete #[#]".}
  ## Delete a property from an object.

proc newJsObject*(): JsObject {.importjs: "({})".}
  ## Create a new empty JavaScript object.

proc newJsArray*(): JsObject {.importjs: "([])".}
  ## Create a new empty JavaScript array.

proc newJsArray*(length: int): JsObject {.importjs: "new Array(#)".}
  ## Create a new JavaScript array with specified length.

proc push*(arr: JsObject, val: JsObject): int {.importjs: "#.push(#)", discardable.}
  ## Push a value onto a JavaScript array. Returns the new length.

# ==============================================================================
# SECTION 5: CONSOLE BINDINGS
# ==============================================================================

type
  Console* = ref object of JsObject
    ## Browser console object type.

var console* {.importjs: "console".}: Console
  ## Global console object.

proc log*(console: Console, args: varargs[JsObject, toJs]) {.importjs: "#.log(...@)".}
  ## Log to console.

proc warn*(console: Console, args: varargs[JsObject, toJs]) {.importjs: "#.warn(...@)".}
  ## Log warning to console.

proc error*(console: Console, args: varargs[JsObject, toJs]) {.importjs: "#.error(...@)".}
  ## Log error to console.

proc info*(console: Console, args: varargs[JsObject, toJs]) {.importjs: "#.info(...@)".}
  ## Log info to console.

proc debug*(console: Console, args: varargs[JsObject, toJs]) {.importjs: "#.debug(...@)".}
  ## Log debug to console.

proc trace*(console: Console) {.importjs: "#.trace()".}
  ## Print stack trace.

proc clear*(console: Console) {.importjs: "#.clear()".}
  ## Clear console.

proc group*(console: Console, label: cstring) {.importjs: "#.group(#)".}
  ## Start a console group.

proc groupEnd*(console: Console) {.importjs: "#.groupEnd()".}
  ## End a console group.

proc time*(console: Console, label: cstring) {.importjs: "#.time(#)".}
  ## Start a timer.

proc timeEnd*(console: Console, label: cstring) {.importjs: "#.timeEnd(#)".}
  ## End a timer and log duration.

proc table*(console: Console, data: JsObject) {.importjs: "#.table(#)".}
  ## Display data as a table.

# Convenience procs that use the global console
proc consoleLog*(args: varargs[JsObject, toJs]) {.importjs: "console.log(...@)".}
  ## Log to console (convenience).

proc consoleWarn*(args: varargs[JsObject, toJs]) {.importjs: "console.warn(...@)".}
  ## Log warning (convenience).

proc consoleError*(args: varargs[JsObject, toJs]) {.importjs: "console.error(...@)".}
  ## Log error (convenience).

# ==============================================================================
# SECTION 6: GLOBALTHIS ACCESS
# ==============================================================================

var globalThis* {.importjs: "globalThis".}: JsObject
  ## The global object (works in browser and Node.js).

var window* {.importjs: "window".}: JsObject
  ## Browser window object.

var document* {.importjs: "document".}: JsObject
  ## Browser document object.

proc setGlobal*(name: cstring, value: JsObject) {.importjs: "globalThis[#] = #".}
  ## Set a global variable.

proc getGlobal*(name: cstring): JsObject {.importjs: "globalThis[#]".}
  ## Get a global variable.

proc hasGlobal*(name: cstring): bool {.importjs: "(# in globalThis)".}
  ## Check if a global variable exists.

# ==============================================================================
# SECTION 7: PERFORMANCE TIMING
# ==============================================================================

type
  Performance* = ref object of JsObject
    ## Performance API type.

var performance* {.importjs: "performance".}: Performance
  ## Global performance object.

proc now*(performance: Performance): float {.importjs: "#.now()".}
  ## Get high-resolution timestamp in milliseconds.

proc performanceNow*(): float {.importjs: "performance.now()".}
  ## Get high-resolution timestamp (convenience).

proc mark*(performance: Performance, name: cstring) {.importjs: "#.mark(#)".}
  ## Create a performance mark.

proc measure*(performance: Performance, name: cstring, startMark: cstring, endMark: cstring) {.importjs: "#.measure(#, #, #)".}
  ## Create a performance measure between two marks.

# ==============================================================================
# SECTION 8: PROMISE/FUTURE INTEROP
# ==============================================================================

type
  JsPromise*[T] = ref object of JsObject
    ## JavaScript Promise type.

proc newPromise*[T](executor: proc(resolve: proc(value: T), reject: proc(reason: JsObject))): JsPromise[T] {.importjs: "new Promise(#)".}
  ## Create a new Promise.

proc jsResolve*[T](value: T): JsPromise[T] {.importjs: "Promise.resolve(#)".}
  ## Create a resolved Promise.

proc jsReject*(reason: JsObject): JsPromise[JsObject] {.importjs: "Promise.reject(#)".}
  ## Create a rejected Promise.

proc jsThen*[T, U](promise: JsPromise[T], onFulfilled: proc(value: T): U): JsPromise[U] {.importjs: "#.then(#)".}
  ## Add fulfillment handler.

proc jsCatch*[T](promise: JsPromise[T], onRejected: proc(reason: JsObject): T): JsPromise[T] {.importjs: "#.catch(#)".}
  ## Add rejection handler.

proc jsFinally*[T](promise: JsPromise[T], onFinally: proc()): JsPromise[T] {.importjs: "#.finally(#)".}
  ## Add finally handler.

proc jsAll*(promises: JsObject): JsPromise[JsObject] {.importjs: "Promise.all(#)".}
  ## Wait for all promises.

proc jsRace*(promises: JsObject): JsPromise[JsObject] {.importjs: "Promise.race(#)".}
  ## Race promises.

proc jsAllSettled*(promises: JsObject): JsPromise[JsObject] {.importjs: "Promise.allSettled(#)".}
  ## Wait for all promises to settle.

proc jsAny*(promises: JsObject): JsPromise[JsObject] {.importjs: "Promise.any(#)".}
  ## Return first fulfilled promise.

# Conversion between Future and Promise
# Note: std/asyncjs Future is already a Promise wrapper, so these are for clarity

proc toPromise*[T](future: Future[T]): JsPromise[T] =
  ## Convert Nim Future to JS Promise.
  ## Note: Future[T] from asyncjs is already a Promise, this is for type clarity.
  cast[JsPromise[T]](future)

proc toFuture*[T](promise: JsPromise[T]): Future[T] =
  ## Convert JS Promise to Nim Future.
  ## Note: This casts the Promise to Future for use with async/await.
  cast[Future[T]](promise)

# ==============================================================================
# SECTION 9: TIMERS
# ==============================================================================

type
  TimeoutId* = distinct int
  IntervalId* = distinct int

proc setTimeout*(callback: proc(), ms: int): TimeoutId {.importjs: "setTimeout(#, #)".}
  ## Set a timeout.

proc clearTimeout*(id: TimeoutId) {.importjs: "clearTimeout(#)".}
  ## Clear a timeout.

proc setInterval*(callback: proc(), ms: int): IntervalId {.importjs: "setInterval(#, #)".}
  ## Set an interval.

proc clearInterval*(id: IntervalId) {.importjs: "clearInterval(#)".}
  ## Clear an interval.

proc requestAnimationFrame*(callback: proc(timestamp: float)): int {.importjs: "requestAnimationFrame(#)".}
  ## Request animation frame.

proc cancelAnimationFrame*(id: int) {.importjs: "cancelAnimationFrame(#)".}
  ## Cancel animation frame.

# ==============================================================================
# SECTION 10: ERROR HANDLING
# ==============================================================================

type
  JsError* = ref object of JsObject
    message* {.importjs: "message".}: cstring
    name* {.importjs: "name".}: cstring
    stack* {.importjs: "stack".}: cstring

proc newJsError*(message: cstring): JsError {.importjs: "new Error(#)".}
  ## Create a new Error.

proc newJsTypeError*(message: cstring): JsError {.importjs: "new TypeError(#)".}
  ## Create a new TypeError.

proc newJsRangeError*(message: cstring): JsError {.importjs: "new RangeError(#)".}
  ## Create a new RangeError.

proc throwJs*(error: JsError) {.importjs: "throw #".}
  ## Throw an error.

# ==============================================================================
# SECTION 11: MATH UTILITIES
# ==============================================================================

var jsMath* {.importjs: "Math".}: JsObject
  ## JavaScript Math object.

proc mathRandom(): float {.importjs: "Math.random()".}
  ## Get random number [0, 1). Non-deterministic; the default random source.

proc jsImul(multiplicand, multiplier: uint32): uint32 {.importjs: "(Math.imul(#, #) >>> 0)".}
  ## 32-bit integer multiply with correct wraparound (JS `*` loses precision
  ## past 2^53, so the mulberry32 PRNG below needs Math.imul specifically).

var rngState: uint32 = 0
  ## mulberry32 generator state. Only meaningful once rngSeeded is true.

var rngSeeded = false
  ## Set by setRandomSeed(); routes jsRandom() through the deterministic
  ## generator instead of Math.random() once true.

proc mulberry32Next(): float =
  ## Next float in [0, 1) from the mulberry32 PRNG (public-domain algorithm
  ## by Tommy Ettinger). Deterministic: the same rngState always produces
  ## the same next value and the same state transition.
  rngState = rngState + 0x6D2B79F5'u32
  var mixedBits = rngState
  mixedBits = jsImul(mixedBits xor (mixedBits shr 15), mixedBits or 1'u32)
  mixedBits = mixedBits xor
    (mixedBits + jsImul(mixedBits xor (mixedBits shr 7), mixedBits or 61'u32))
  float(mixedBits xor (mixedBits shr 14)) / 4294967296.0

proc setRandomSeed*(seed: int) =
  ## Route jsRandom() (and anything built on it, e.g. gaussian()) through a
  ## seeded, deterministic PRNG instead of Math.random(). Call once, at
  ## startup, before any randomness is drawn - see app.nim's ?seed= handling.
  rngState = uint32(seed)
  rngSeeded = true

proc jsRandom*(): float =
  ## Get random number [0, 1). Deterministic once setRandomSeed() has been
  ## called; Math.random() otherwise (default, unseeded behavior).
  if rngSeeded:
    mulberry32Next()
  else:
    mathRandom()

proc jsFloor*(value: float): int {.importjs: "Math.floor(#)".}
  ## Floor a number.

proc jsCeil*(value: float): int {.importjs: "Math.ceil(#)".}
  ## Ceiling a number.

proc jsRound*(value: float): int {.importjs: "Math.round(#)".}
  ## Round a number.

proc jsAbs*(value: float): float {.importjs: "Math.abs(#)".}
  ## Absolute value.

proc jsMin*(first, second: float): float {.importjs: "Math.min(#, #)".}
  ## Minimum of two numbers.

proc jsMax*(first, second: float): float {.importjs: "Math.max(#, #)".}
  ## Maximum of two numbers.

proc jsSqrt*(value: float): float {.importjs: "Math.sqrt(#)".}
  ## Square root.

proc jsPow*(base, exp: float): float {.importjs: "Math.pow(#, #)".}
  ## Power.

proc jsLog*(value: float): float {.importjs: "Math.log(#)".}
  ## Natural logarithm.

proc jsSin*(radians: float): float {.importjs: "Math.sin(#)".}
  ## Sine.

proc jsCos*(radians: float): float {.importjs: "Math.cos(#)".}
  ## Cosine.

proc jsAtan2*(yComponent, xComponent: float): float {.importjs: "Math.atan2(#, #)".}
  ## Arc tangent of y/x.

const jsPi* = 3.141592653589793
  ## Pi constant.

proc gaussian*(): float =
  ## Standard normal sample (mean 0, std 1) via Box-Muller.
  let uniform1 = jsMax(jsRandom(), 1e-12)   # guard ln(0)
  let uniform2 = jsRandom()
  jsSqrt(-2.0 * jsLog(uniform1)) * jsCos(2.0 * jsPi * uniform2)

# ==============================================================================
# SECTION 12: UTILITY MACROS AND TEMPLATES
# ==============================================================================

template withPerformanceTiming*(label: string, body: untyped): float =
  ## Execute body and return elapsed time in milliseconds.
  let t0 = performanceNow()
  body
  performanceNow() - t0

template jsBlock*(code: string): untyped =
  ## Emit raw JavaScript code block.
  {.emit: code.}
