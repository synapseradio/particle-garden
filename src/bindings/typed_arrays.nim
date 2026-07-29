# ==============================================================================
# PARTICLE GARDEN - TYPED ARRAY BINDINGS
# ==============================================================================
#
# Centralized bindings for JavaScript TypedArray and WebAssembly.Memory APIs.
#
# This module provides idiomatic Nim bindings for:
# - ArrayBuffer and SharedArrayBuffer
# - TypedArray constructors (Float32Array, Uint8Array, Int32Array, etc.)
# - Index access operators
# - Properties (length, buffer, byteOffset, byteLength)
# - Methods (subarray, set, slice)
# - WebAssembly.Memory construction
#
# USAGE:
#   import bindings/typed_arrays
#
#   let arr = newFloat32Array(100)
#   arr[0] = 1.5
#   let val = arr[0]
#   let sub = arr.subarray(10, 20)
#
# ==============================================================================

import std/jsffi

# ==============================================================================
# SECTION 1: BUFFER TYPES
# ==============================================================================

type
  ArrayBuffer* = ref object of JsObject

  SharedArrayBuffer* = ref object of JsObject

# ==============================================================================
# SECTION 2: TYPED ARRAY VIEW TYPES
# ==============================================================================

type
  Float32Array* = ref object of JsObject

  Float64Array* = ref object of JsObject

  Int8Array* = ref object of JsObject

  Int16Array* = ref object of JsObject

  Int32Array* = ref object of JsObject

  Uint8Array* = ref object of JsObject

  Uint8ClampedArray* = ref object of JsObject

  Uint16Array* = ref object of JsObject

  Uint32Array* = ref object of JsObject

# ==============================================================================
# SECTION 3: WEBASSEMBLY MEMORY TYPE
# ==============================================================================

type
  WebAssemblyMemory* = ref object of JsObject
    buffer* {.importjs: "buffer".}: JsObject

# ==============================================================================
# SECTION 4: ARRAYBUFFER CONSTRUCTORS
# ==============================================================================

proc newArrayBuffer*(byteLength: int): ArrayBuffer {.importjs: "new ArrayBuffer(#)".}

proc newSharedArrayBuffer*(byteLength: int): SharedArrayBuffer {.importjs: "new SharedArrayBuffer(#)".}

# ==============================================================================
# SECTION 5: FLOAT32ARRAY CONSTRUCTORS
# ==============================================================================

proc newFloat32Array*(length: int): Float32Array {.importjs: "new Float32Array(#)".}

proc newFloat32Array*(buffer: JsObject, byteOffset: int, length: int): Float32Array {.importjs: "new Float32Array(#, #, #)".}

proc newFloat32Array*(buffer: JsObject): Float32Array {.importjs: "new Float32Array(#)".}

proc newFloat32Array*(buffer: JsObject, byteOffset: int): Float32Array {.importjs: "new Float32Array(#, #)".}

proc newFloat32Array*(values: seq[float]): Float32Array {.importjs: "new Float32Array(#)".}

proc newFloat32Array*(values: seq[float32]): Float32Array {.importjs: "new Float32Array(#)".}

# ==============================================================================
# SECTION 6: FLOAT64ARRAY CONSTRUCTORS
# ==============================================================================

proc newFloat64Array*(length: int): Float64Array {.importjs: "new Float64Array(#)".}

proc newFloat64Array*(buffer: JsObject, byteOffset: int, length: int): Float64Array {.importjs: "new Float64Array(#, #, #)".}

# ==============================================================================
# SECTION 7: INT32ARRAY CONSTRUCTORS
# ==============================================================================

proc newInt32Array*(length: int): Int32Array {.importjs: "new Int32Array(#)".}

proc newInt32Array*(buffer: JsObject, byteOffset: int, length: int): Int32Array {.importjs: "new Int32Array(#, #, #)".}

proc newInt32Array*(buffer: JsObject): Int32Array {.importjs: "new Int32Array(#)".}

proc newInt32Array*(buffer: JsObject, byteOffset: int): Int32Array {.importjs: "new Int32Array(#, #)".}

# ==============================================================================
# SECTION 8: INT16ARRAY CONSTRUCTORS
# ==============================================================================

proc newInt16Array*(length: int): Int16Array {.importjs: "new Int16Array(#)".}

proc newInt16Array*(buffer: JsObject, byteOffset: int, length: int): Int16Array {.importjs: "new Int16Array(#, #, #)".}

# ==============================================================================
# SECTION 9: INT8ARRAY CONSTRUCTORS
# ==============================================================================

proc newInt8Array*(length: int): Int8Array {.importjs: "new Int8Array(#)".}

proc newInt8Array*(buffer: JsObject, byteOffset: int, length: int): Int8Array {.importjs: "new Int8Array(#, #, #)".}

# ==============================================================================
# SECTION 10: UINT32ARRAY CONSTRUCTORS
# ==============================================================================

proc newUint32Array*(length: int): Uint32Array {.importjs: "new Uint32Array(#)".}

proc newUint32Array*(buffer: JsObject, byteOffset: int, length: int): Uint32Array {.importjs: "new Uint32Array(#, #, #)".}

proc newUint32Array*(buffer: JsObject): Uint32Array {.importjs: "new Uint32Array(#)".}

proc newUint32Array*(buffer: JsObject, byteOffset: int): Uint32Array {.importjs: "new Uint32Array(#, #)".}

# ==============================================================================
# SECTION 11: UINT16ARRAY CONSTRUCTORS
# ==============================================================================

proc newUint16Array*(length: int): Uint16Array {.importjs: "new Uint16Array(#)".}

proc newUint16Array*(buffer: JsObject, byteOffset: int, length: int): Uint16Array {.importjs: "new Uint16Array(#, #, #)".}

# ==============================================================================
# SECTION 12: UINT8ARRAY CONSTRUCTORS
# ==============================================================================

proc newUint8Array*(length: int): Uint8Array {.importjs: "new Uint8Array(#)".}

proc newUint8Array*(buffer: JsObject, byteOffset: int, length: int): Uint8Array {.importjs: "new Uint8Array(#, #, #)".}

proc newUint8Array*(buffer: JsObject): Uint8Array {.importjs: "new Uint8Array(#)".}

proc newUint8Array*(buffer: JsObject, byteOffset: int): Uint8Array {.importjs: "new Uint8Array(#, #)".}

# ==============================================================================
# SECTION 13: UINT8CLAMPEDARRAY CONSTRUCTORS
# ==============================================================================

proc newUint8ClampedArray*(length: int): Uint8ClampedArray {.importjs: "new Uint8ClampedArray(#)".}

proc newUint8ClampedArray*(buffer: JsObject, byteOffset: int, length: int): Uint8ClampedArray {.importjs: "new Uint8ClampedArray(#, #, #)".}

# ==============================================================================
# SECTION 14: FLOAT32ARRAY INDEX ACCESS
# ==============================================================================

proc `[]`*(arr: Float32Array, idx: int): float {.importjs: "#[#]".}

proc `[]=`*(arr: Float32Array, idx: int, val: float) {.importjs: "#[#] = #".}

# ==============================================================================
# SECTION 15: FLOAT64ARRAY INDEX ACCESS
# ==============================================================================

proc `[]`*(arr: Float64Array, idx: int): float {.importjs: "#[#]".}

proc `[]=`*(arr: Float64Array, idx: int, val: float) {.importjs: "#[#] = #".}

# ==============================================================================
# SECTION 16: INT32ARRAY INDEX ACCESS
# ==============================================================================

proc `[]`*(arr: Int32Array, idx: int): int {.importjs: "#[#]".}

proc `[]=`*(arr: Int32Array, idx: int, val: int) {.importjs: "#[#] = #".}

# ==============================================================================
# SECTION 17: INT16ARRAY INDEX ACCESS
# ==============================================================================

proc `[]`*(arr: Int16Array, idx: int): int {.importjs: "#[#]".}

proc `[]=`*(arr: Int16Array, idx: int, val: int) {.importjs: "#[#] = #".}

# ==============================================================================
# SECTION 18: INT8ARRAY INDEX ACCESS
# ==============================================================================

proc `[]`*(arr: Int8Array, idx: int): int {.importjs: "#[#]".}

proc `[]=`*(arr: Int8Array, idx: int, val: int) {.importjs: "#[#] = #".}

# ==============================================================================
# SECTION 19: UINT32ARRAY INDEX ACCESS
# ==============================================================================

proc `[]`*(arr: Uint32Array, idx: int): int {.importjs: "#[#]".}

proc `[]=`*(arr: Uint32Array, idx: int, val: int) {.importjs: "#[#] = #".}

# ==============================================================================
# SECTION 20: UINT16ARRAY INDEX ACCESS
# ==============================================================================

proc `[]`*(arr: Uint16Array, idx: int): int {.importjs: "#[#]".}

proc `[]=`*(arr: Uint16Array, idx: int, val: int) {.importjs: "#[#] = #".}

# ==============================================================================
# SECTION 21: UINT8ARRAY INDEX ACCESS
# ==============================================================================

proc `[]`*(arr: Uint8Array, idx: int): int {.importjs: "#[#]".}

proc `[]=`*(arr: Uint8Array, idx: int, val: int) {.importjs: "#[#] = #".}

# ==============================================================================
# SECTION 22: UINT8CLAMPEDARRAY INDEX ACCESS
# ==============================================================================

proc `[]`*(arr: Uint8ClampedArray, idx: int): int {.importjs: "#[#]".}

proc `[]=`*(arr: Uint8ClampedArray, idx: int, val: int) {.importjs: "#[#] = #".}

# ==============================================================================
# SECTION 23: LENGTH PROPERTY
# ==============================================================================

proc len*(arr: Float32Array): int {.importjs: "#.length".}

proc len*(arr: Float64Array): int {.importjs: "#.length".}

proc len*(arr: Int32Array): int {.importjs: "#.length".}

proc len*(arr: Int16Array): int {.importjs: "#.length".}

proc len*(arr: Int8Array): int {.importjs: "#.length".}

proc len*(arr: Uint32Array): int {.importjs: "#.length".}

proc len*(arr: Uint16Array): int {.importjs: "#.length".}

proc len*(arr: Uint8Array): int {.importjs: "#.length".}

proc len*(arr: Uint8ClampedArray): int {.importjs: "#.length".}

# ==============================================================================
# SECTION 24: BUFFER PROPERTY
# ==============================================================================

proc buffer*(arr: Float32Array): JsObject {.importjs: "#.buffer".}

proc buffer*(arr: Float64Array): JsObject {.importjs: "#.buffer".}

proc buffer*(arr: Int32Array): JsObject {.importjs: "#.buffer".}

proc buffer*(arr: Int16Array): JsObject {.importjs: "#.buffer".}

proc buffer*(arr: Int8Array): JsObject {.importjs: "#.buffer".}

proc buffer*(arr: Uint32Array): JsObject {.importjs: "#.buffer".}

proc buffer*(arr: Uint16Array): JsObject {.importjs: "#.buffer".}

proc buffer*(arr: Uint8Array): JsObject {.importjs: "#.buffer".}

proc buffer*(arr: Uint8ClampedArray): JsObject {.importjs: "#.buffer".}

# ==============================================================================
# SECTION 25: BYTEOFFSET PROPERTY
# ==============================================================================

proc byteOffset*(arr: Float32Array): int {.importjs: "#.byteOffset".}

proc byteOffset*(arr: Float64Array): int {.importjs: "#.byteOffset".}

proc byteOffset*(arr: Int32Array): int {.importjs: "#.byteOffset".}

proc byteOffset*(arr: Int16Array): int {.importjs: "#.byteOffset".}

proc byteOffset*(arr: Int8Array): int {.importjs: "#.byteOffset".}

proc byteOffset*(arr: Uint32Array): int {.importjs: "#.byteOffset".}

proc byteOffset*(arr: Uint16Array): int {.importjs: "#.byteOffset".}

proc byteOffset*(arr: Uint8Array): int {.importjs: "#.byteOffset".}

proc byteOffset*(arr: Uint8ClampedArray): int {.importjs: "#.byteOffset".}

# ==============================================================================
# SECTION 26: BYTELENGTH PROPERTY
# ==============================================================================

proc byteLength*(arr: Float32Array): int {.importjs: "#.byteLength".}

proc byteLength*(arr: Float64Array): int {.importjs: "#.byteLength".}

proc byteLength*(arr: Int32Array): int {.importjs: "#.byteLength".}

proc byteLength*(arr: Int16Array): int {.importjs: "#.byteLength".}

proc byteLength*(arr: Int8Array): int {.importjs: "#.byteLength".}

proc byteLength*(arr: Uint32Array): int {.importjs: "#.byteLength".}

proc byteLength*(arr: Uint16Array): int {.importjs: "#.byteLength".}

proc byteLength*(arr: Uint8Array): int {.importjs: "#.byteLength".}

proc byteLength*(arr: Uint8ClampedArray): int {.importjs: "#.byteLength".}

proc byteLength*(buf: ArrayBuffer): int {.importjs: "#.byteLength".}

proc byteLength*(buf: SharedArrayBuffer): int {.importjs: "#.byteLength".}

# ==============================================================================
# SECTION 27: SUBARRAY METHOD
# ==============================================================================

proc subarray*(arr: Float32Array, begin: int, `end`: int): Float32Array {.importjs: "#.subarray(#, #)".}

proc subarray*(arr: Float32Array, begin: int): Float32Array {.importjs: "#.subarray(#)".}

proc subarray*(arr: Float64Array, begin: int, `end`: int): Float64Array {.importjs: "#.subarray(#, #)".}

proc subarray*(arr: Float64Array, begin: int): Float64Array {.importjs: "#.subarray(#)".}

proc subarray*(arr: Int32Array, begin: int, `end`: int): Int32Array {.importjs: "#.subarray(#, #)".}

proc subarray*(arr: Int32Array, begin: int): Int32Array {.importjs: "#.subarray(#)".}

proc subarray*(arr: Uint32Array, begin: int, `end`: int): Uint32Array {.importjs: "#.subarray(#, #)".}

proc subarray*(arr: Uint32Array, begin: int): Uint32Array {.importjs: "#.subarray(#)".}

proc subarray*(arr: Uint16Array, begin: int, `end`: int): Uint16Array {.importjs: "#.subarray(#, #)".}

proc subarray*(arr: Uint16Array, begin: int): Uint16Array {.importjs: "#.subarray(#)".}

proc subarray*(arr: Uint8Array, begin: int, `end`: int): Uint8Array {.importjs: "#.subarray(#, #)".}

proc subarray*(arr: Uint8Array, begin: int): Uint8Array {.importjs: "#.subarray(#)".}

# ==============================================================================
# SECTION 28: SET METHOD
# ==============================================================================

proc set*(arr: Float32Array, source: Float32Array, offset: int = 0) {.importjs: "#.set(#, #)".}

proc set*(arr: Float64Array, source: Float64Array, offset: int = 0) {.importjs: "#.set(#, #)".}

proc set*(arr: Int32Array, source: Int32Array, offset: int = 0) {.importjs: "#.set(#, #)".}

proc set*(arr: Uint32Array, source: Uint32Array, offset: int = 0) {.importjs: "#.set(#, #)".}

proc set*(arr: Uint16Array, source: Uint16Array, offset: int = 0) {.importjs: "#.set(#, #)".}

proc set*(arr: Uint8Array, source: Uint8Array, offset: int = 0) {.importjs: "#.set(#, #)".}

# ==============================================================================
# SECTION 29: SLICE METHOD
# ==============================================================================

proc slice*(arr: Float32Array, begin: int, `end`: int): Float32Array {.importjs: "#.slice(#, #)".}

proc slice*(arr: Float32Array, begin: int): Float32Array {.importjs: "#.slice(#)".}

proc slice*(arr: Int32Array, begin: int, `end`: int): Int32Array {.importjs: "#.slice(#, #)".}

proc slice*(arr: Int32Array, begin: int): Int32Array {.importjs: "#.slice(#)".}

proc slice*(arr: Uint32Array, begin: int, `end`: int): Uint32Array {.importjs: "#.slice(#, #)".}

proc slice*(arr: Uint32Array, begin: int): Uint32Array {.importjs: "#.slice(#)".}

proc slice*(arr: Uint8Array, begin: int, `end`: int): Uint8Array {.importjs: "#.slice(#, #)".}

proc slice*(arr: Uint8Array, begin: int): Uint8Array {.importjs: "#.slice(#)".}

proc slice*(buf: ArrayBuffer, begin: int, `end`: int): ArrayBuffer {.importjs: "#.slice(#, #)".}

proc slice*(buf: ArrayBuffer, begin: int): ArrayBuffer {.importjs: "#.slice(#)".}

# ==============================================================================
# SECTION 30: WEBASSEMBLY.MEMORY CONSTRUCTOR
# ==============================================================================

proc newWebAssemblyMemory*(initial: int, maximum: int, shared: bool): WebAssemblyMemory {.importjs: "new WebAssembly.Memory({initial: #, maximum: #, shared: #})".}
  ## `initial` and `maximum` count 64KiB pages, the unit WebAssembly linear memory grows by.
  ## https://webassembly.github.io/spec/core/exec/runtime.html

proc newWebAssemblyMemory*(initial: int, maximum: int): WebAssemblyMemory {.importjs: "new WebAssembly.Memory({initial: #, maximum: #})".}

proc newWebAssemblyMemory*(initial: int): WebAssemblyMemory {.importjs: "new WebAssembly.Memory({initial: #})".}

# ==============================================================================
# SECTION 31: WEBASSEMBLY.MEMORY METHODS
# ==============================================================================

proc grow*(mem: WebAssemblyMemory, delta: int): int {.importjs: "#.grow(#)".}

# ==============================================================================
# SECTION 32: FILL METHOD
# ==============================================================================

proc fill*(arr: Float32Array, value: float, start: int, `end`: int) {.importjs: "#.fill(#, #, #)".}

proc fill*(arr: Float32Array, value: float) {.importjs: "#.fill(#)".}

proc fill*(arr: Int32Array, value: int, start: int, `end`: int) {.importjs: "#.fill(#, #, #)".}

proc fill*(arr: Int32Array, value: int) {.importjs: "#.fill(#)".}

proc fill*(arr: Uint32Array, value: int, start: int, `end`: int) {.importjs: "#.fill(#, #, #)".}

proc fill*(arr: Uint32Array, value: int) {.importjs: "#.fill(#)".}

proc fill*(arr: Uint16Array, value: int, start: int, `end`: int) {.importjs: "#.fill(#, #, #)".}

proc fill*(arr: Uint16Array, value: int) {.importjs: "#.fill(#)".}

proc fill*(arr: Uint8Array, value: int, start: int, `end`: int) {.importjs: "#.fill(#, #, #)".}

proc fill*(arr: Uint8Array, value: int) {.importjs: "#.fill(#)".}

# ==============================================================================
# SECTION 33: COPYWITHIN METHOD
# ==============================================================================

proc copyWithin*(arr: Float32Array, target: int, start: int, `end`: int): Float32Array {.importjs: "#.copyWithin(#, #, #)".}

proc copyWithin*(arr: Float32Array, target: int, start: int): Float32Array {.importjs: "#.copyWithin(#, #)".}

proc copyWithin*(arr: Int32Array, target: int, start: int, `end`: int): Int32Array {.importjs: "#.copyWithin(#, #, #)".}

proc copyWithin*(arr: Uint32Array, target: int, start: int, `end`: int): Uint32Array {.importjs: "#.copyWithin(#, #, #)".}

proc copyWithin*(arr: Uint8Array, target: int, start: int, `end`: int): Uint8Array {.importjs: "#.copyWithin(#, #, #)".}

# ==============================================================================
# SECTION 34: TYPE ALIASES FOR BACKWARDS COMPATIBILITY
# ==============================================================================

# Legacy type aliases used in existing codebase
type
  Float32ArrayView* = Float32Array
  Float64ArrayView* = Float64Array
  Int32ArrayView* = Int32Array
  Int16ArrayView* = Int16Array
  Int8ArrayView* = Int8Array
  Uint32ArrayView* = Uint32Array
  Uint16ArrayView* = Uint16Array
  Uint8ArrayView* = Uint8Array
