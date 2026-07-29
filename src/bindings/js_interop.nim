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

var jsUndefined* {.importjs: "undefined".}: JsObject

var jsNull* {.importjs: "null".}: JsObject

proc isUndefined*(obj: JsObject): bool {.importjs: "(# === undefined)".}

proc isNull*(obj: JsObject): bool {.importjs: "(# === null)".}

proc isNullOrUndefined*(obj: JsObject): bool {.importjs: "(# == null)".}

proc isDefined*(obj: JsObject): bool {.importjs: "(# !== undefined)".}

# ==============================================================================
# SECTION 2: TYPE CHECKING UTILITIES
# ==============================================================================

proc jsTypeof*(obj: JsObject): cstring {.importjs: "(typeof #)".}

proc isJsFunction*(obj: JsObject): bool {.importjs: "(typeof # === 'function')".}

proc isJsObject*(obj: JsObject): bool {.importjs: "(typeof # === 'object' && # !== null)".}

proc isJsArray*(obj: JsObject): bool {.importjs: "Array.isArray(#)".}

proc isJsString*(obj: JsObject): bool {.importjs: "(typeof # === 'string')".}

proc isJsNumber*(obj: JsObject): bool {.importjs: "(typeof # === 'number')".}

proc isJsBoolean*(obj: JsObject): bool {.importjs: "(typeof # === 'boolean')".}

proc instanceOf*(obj: JsObject, constructor: JsObject): bool {.importjs: "(# instanceof #)".}

# ==============================================================================
# SECTION 3: TYPE CONVERSIONS
# ==============================================================================

proc toJsObject*(value: int): JsObject {.importjs: "(#)".}

proc toJsObject*(value: float): JsObject {.importjs: "(#)".}

proc toJsObject*(value: bool): JsObject {.importjs: "(#)".}

proc toJsObject*(value: cstring): JsObject {.importjs: "(#)".}

proc toJsObject*(value: string): JsObject {.importjs: "(#)".}

proc toInt*(obj: JsObject): int {.importjs: "(#|0)".}

proc toFloat*(obj: JsObject): float {.importjs: "(+#)".}

proc toBool*(obj: JsObject): bool {.importjs: "(!!#)".}

# Generic `to` converter for method-call syntax: obj.to(int), obj.to(float), etc.
proc to*(obj: JsObject, T: typedesc[int]): int {.inline.} = obj.toInt
proc to*(obj: JsObject, T: typedesc[float]): float {.inline.} = obj.toFloat
proc to*(obj: JsObject, T: typedesc[bool]): bool {.inline.} = obj.toBool

proc toCstring*(obj: JsObject): cstring {.importjs: "String(#)".}

proc toJsString*(obj: JsObject): JsObject {.importjs: "String(#)".}

proc parseJsonJs*(jsonText: cstring): JsObject {.importjs: "JSON.parse(#)".}

proc stringifyJs*(obj: JsObject): cstring {.importjs: "JSON.stringify(#)".}

proc stringifyJsPretty*(obj: JsObject, indent: int = 2): cstring {.importjs: "JSON.stringify(#, null, #)".}

# ==============================================================================
# SECTION 4: OBJECT UTILITIES
# ==============================================================================

proc jsKeys*(obj: JsObject): JsObject {.importjs: "Object.keys(#)".}

proc jsValues*(obj: JsObject): JsObject {.importjs: "Object.values(#)".}

proc jsEntries*(obj: JsObject): JsObject {.importjs: "Object.entries(#)".}

proc jsAssign*(target: JsObject, source: JsObject): JsObject {.importjs: "Object.assign(#, #)".}

proc jsFreeze*(obj: JsObject): JsObject {.importjs: "Object.freeze(#)".}

proc hasOwnProperty*(obj: JsObject, key: cstring): bool {.importjs: "#.hasOwnProperty(#)".}

proc deleteProperty*(obj: JsObject, key: cstring) {.importjs: "delete #[#]".}

proc newJsObject*(): JsObject {.importjs: "({})".}

proc newJsArray*(): JsObject {.importjs: "([])".}

proc newJsArray*(length: int): JsObject {.importjs: "new Array(#)".}

proc push*(arr: JsObject, val: JsObject): int {.importjs: "#.push(#)", discardable.}

# ==============================================================================
# SECTION 5: CONSOLE BINDINGS
# ==============================================================================

type
  Console* = ref object of JsObject

var console* {.importjs: "console".}: Console

proc log*(console: Console, args: varargs[JsObject, toJs]) {.importjs: "#.log(...@)".}

proc warn*(console: Console, args: varargs[JsObject, toJs]) {.importjs: "#.warn(...@)".}

proc error*(console: Console, args: varargs[JsObject, toJs]) {.importjs: "#.error(...@)".}

proc info*(console: Console, args: varargs[JsObject, toJs]) {.importjs: "#.info(...@)".}

proc debug*(console: Console, args: varargs[JsObject, toJs]) {.importjs: "#.debug(...@)".}

proc trace*(console: Console) {.importjs: "#.trace()".}

proc clear*(console: Console) {.importjs: "#.clear()".}

proc group*(console: Console, label: cstring) {.importjs: "#.group(#)".}

proc groupEnd*(console: Console) {.importjs: "#.groupEnd()".}

proc time*(console: Console, label: cstring) {.importjs: "#.time(#)".}

proc timeEnd*(console: Console, label: cstring) {.importjs: "#.timeEnd(#)".}

proc table*(console: Console, data: JsObject) {.importjs: "#.table(#)".}

# Convenience procs that use the global console
proc consoleLog*(args: varargs[JsObject, toJs]) {.importjs: "console.log(...@)".}

proc consoleWarn*(args: varargs[JsObject, toJs]) {.importjs: "console.warn(...@)".}

proc consoleError*(args: varargs[JsObject, toJs]) {.importjs: "console.error(...@)".}

# ==============================================================================
# SECTION 6: GLOBALTHIS ACCESS
# ==============================================================================

var globalThis* {.importjs: "globalThis".}: JsObject

var window* {.importjs: "window".}: JsObject

var document* {.importjs: "document".}: JsObject

proc setGlobal*(name: cstring, value: JsObject) {.importjs: "globalThis[#] = #".}

proc getGlobal*(name: cstring): JsObject {.importjs: "globalThis[#]".}

proc hasGlobal*(name: cstring): bool {.importjs: "(# in globalThis)".}

# ==============================================================================
# SECTION 7: PERFORMANCE TIMING
# ==============================================================================

type
  Performance* = ref object of JsObject

var performance* {.importjs: "performance".}: Performance

proc now*(performance: Performance): float {.importjs: "#.now()".}

proc performanceNow*(): float {.importjs: "performance.now()".}

proc mark*(performance: Performance, name: cstring) {.importjs: "#.mark(#)".}

proc measure*(performance: Performance, name: cstring, startMark: cstring, endMark: cstring) {.importjs: "#.measure(#, #, #)".}

# ==============================================================================
# SECTION 8: PROMISE/FUTURE INTEROP
# ==============================================================================

type
  JsPromise*[T] = ref object of JsObject

proc newPromise*[T](executor: proc(resolve: proc(value: T), reject: proc(reason: JsObject))): JsPromise[T] {.importjs: "new Promise(#)".}

proc jsResolve*[T](value: T): JsPromise[T] {.importjs: "Promise.resolve(#)".}

proc jsReject*(reason: JsObject): JsPromise[JsObject] {.importjs: "Promise.reject(#)".}

proc jsThen*[T, U](promise: JsPromise[T], onFulfilled: proc(value: T): U): JsPromise[U] {.importjs: "#.then(#)".}

proc jsCatch*[T](promise: JsPromise[T], onRejected: proc(reason: JsObject): T): JsPromise[T] {.importjs: "#.catch(#)".}

proc jsFinally*[T](promise: JsPromise[T], onFinally: proc()): JsPromise[T] {.importjs: "#.finally(#)".}

proc jsAll*(promises: JsObject): JsPromise[JsObject] {.importjs: "Promise.all(#)".}

proc jsRace*(promises: JsObject): JsPromise[JsObject] {.importjs: "Promise.race(#)".}

proc jsAllSettled*(promises: JsObject): JsPromise[JsObject] {.importjs: "Promise.allSettled(#)".}

proc jsAny*(promises: JsObject): JsPromise[JsObject] {.importjs: "Promise.any(#)".}

# Conversion between Future and Promise
# Note: std/asyncjs Future is already a Promise wrapper, so these are for clarity

proc toPromise*[T](future: Future[T]): JsPromise[T] =
  cast[JsPromise[T]](future)

proc toFuture*[T](promise: JsPromise[T]): Future[T] =
  cast[Future[T]](promise)

# ==============================================================================
# SECTION 9: TIMERS
# ==============================================================================

type
  TimeoutId* = distinct int
  IntervalId* = distinct int

proc setTimeout*(callback: proc(), ms: int): TimeoutId {.importjs: "setTimeout(#, #)".}

proc clearTimeout*(id: TimeoutId) {.importjs: "clearTimeout(#)".}

proc setInterval*(callback: proc(), ms: int): IntervalId {.importjs: "setInterval(#, #)".}

proc clearInterval*(id: IntervalId) {.importjs: "clearInterval(#)".}

proc requestAnimationFrame*(callback: proc(timestamp: float)): int {.importjs: "requestAnimationFrame(#)".}

proc cancelAnimationFrame*(id: int) {.importjs: "cancelAnimationFrame(#)".}

# ==============================================================================
# SECTION 10: ERROR HANDLING
# ==============================================================================

type
  JsError* = ref object of JsObject
    message* {.importjs: "message".}: cstring
    name* {.importjs: "name".}: cstring
    stack* {.importjs: "stack".}: cstring

proc newJsError*(message: cstring): JsError {.importjs: "new Error(#)".}

proc newJsTypeError*(message: cstring): JsError {.importjs: "new TypeError(#)".}

proc newJsRangeError*(message: cstring): JsError {.importjs: "new RangeError(#)".}

proc throwJs*(error: JsError) {.importjs: "throw #".}

# ==============================================================================
# SECTION 11: MATH UTILITIES
# ==============================================================================

var jsMath* {.importjs: "Math".}: JsObject

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
  ## Deterministic: the same rngState always produces the same next value
  ## and the same state transition.
  ## https://gist.github.com/tommyettinger/46a874533244883189143505d203312c
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

proc jsCeil*(value: float): int {.importjs: "Math.ceil(#)".}

proc jsRound*(value: float): int {.importjs: "Math.round(#)".}

proc jsAbs*(value: float): float {.importjs: "Math.abs(#)".}

proc jsMin*(first, second: float): float {.importjs: "Math.min(#, #)".}

proc jsMax*(first, second: float): float {.importjs: "Math.max(#, #)".}

proc jsSqrt*(value: float): float {.importjs: "Math.sqrt(#)".}

proc jsPow*(base, exp: float): float {.importjs: "Math.pow(#, #)".}

proc jsLog*(value: float): float {.importjs: "Math.log(#)".}

proc jsSin*(radians: float): float {.importjs: "Math.sin(#)".}

proc jsCos*(radians: float): float {.importjs: "Math.cos(#)".}

proc jsAtan2*(yComponent, xComponent: float): float {.importjs: "Math.atan2(#, #)".}

const jsPi* = 3.141592653589793

proc gaussian*(): float =
  ## Standard normal sample (mean 0, std 1) via Box-Muller.
  let uniform1 = jsMax(jsRandom(), 1e-12)   # guard ln(0)
  let uniform2 = jsRandom()
  jsSqrt(-2.0 * jsLog(uniform1)) * jsCos(2.0 * jsPi * uniform2)

# ==============================================================================
# SECTION 12: UTILITY MACROS AND TEMPLATES
# ==============================================================================

template withPerformanceTiming*(label: string, body: untyped): float =
  let t0 = performanceNow()
  body
  performanceNow() - t0

template jsBlock*(code: string): untyped =
  {.emit: code.}
