# ==============================================================================
# EMERGENT GARDEN - TYPED ARRAY BINDINGS
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
    ## JavaScript ArrayBuffer - fixed-length raw binary data buffer

  SharedArrayBuffer* = ref object of JsObject
    ## JavaScript SharedArrayBuffer - shareable between workers

# ==============================================================================
# SECTION 2: TYPED ARRAY VIEW TYPES
# ==============================================================================

type
  Float32Array* = ref object of JsObject
    ## 32-bit IEEE floating point array view

  Float64Array* = ref object of JsObject
    ## 64-bit IEEE floating point array view

  Int8Array* = ref object of JsObject
    ## 8-bit signed integer array view

  Int16Array* = ref object of JsObject
    ## 16-bit signed integer array view

  Int32Array* = ref object of JsObject
    ## 32-bit signed integer array view

  Uint8Array* = ref object of JsObject
    ## 8-bit unsigned integer array view

  Uint8ClampedArray* = ref object of JsObject
    ## 8-bit unsigned clamped integer array view (clamps to 0-255)

  Uint16Array* = ref object of JsObject
    ## 16-bit unsigned integer array view

  Uint32Array* = ref object of JsObject
    ## 32-bit unsigned integer array view

# ==============================================================================
# SECTION 3: WEBASSEMBLY MEMORY TYPE
# ==============================================================================

type
  WebAssemblyMemory* = ref object of JsObject
    ## WebAssembly.Memory object with SharedArrayBuffer backing
    buffer* {.importjs: "buffer".}: JsObject

# ==============================================================================
# SECTION 4: ARRAYBUFFER CONSTRUCTORS
# ==============================================================================

proc newArrayBuffer*(byteLength: int): ArrayBuffer {.importjs: "new ArrayBuffer(#)".}
  ## Create a new ArrayBuffer with the specified byte length

proc newSharedArrayBuffer*(byteLength: int): SharedArrayBuffer {.importjs: "new SharedArrayBuffer(#)".}
  ## Create a new SharedArrayBuffer with the specified byte length

# ==============================================================================
# SECTION 5: FLOAT32ARRAY CONSTRUCTORS
# ==============================================================================

proc newFloat32Array*(length: int): Float32Array {.importjs: "new Float32Array(#)".}
  ## Create a new Float32Array with the specified number of elements

proc newFloat32Array*(buffer: JsObject, byteOffset: int, length: int): Float32Array {.importjs: "new Float32Array(#, #, #)".}
  ## Create a Float32Array view over a buffer at specified byte offset and length

proc newFloat32Array*(buffer: JsObject): Float32Array {.importjs: "new Float32Array(#)".}
  ## Create a Float32Array view over an entire buffer

proc newFloat32Array*(buffer: JsObject, byteOffset: int): Float32Array {.importjs: "new Float32Array(#, #)".}
  ## Create a Float32Array view from byteOffset to end of buffer

proc newFloat32Array*(values: seq[float]): Float32Array {.importjs: "new Float32Array(#)".}
  ## Create a Float32Array from a sequence of float values
  ## The sequence is converted to a JavaScript array which Float32Array accepts

proc newFloat32Array*(values: seq[float32]): Float32Array {.importjs: "new Float32Array(#)".}
  ## Create a Float32Array from a sequence of float32 values

# ==============================================================================
# SECTION 6: FLOAT64ARRAY CONSTRUCTORS
# ==============================================================================

proc newFloat64Array*(length: int): Float64Array {.importjs: "new Float64Array(#)".}
  ## Create a new Float64Array with the specified number of elements

proc newFloat64Array*(buffer: JsObject, byteOffset: int, length: int): Float64Array {.importjs: "new Float64Array(#, #, #)".}
  ## Create a Float64Array view over a buffer at specified byte offset and length

# ==============================================================================
# SECTION 7: INT32ARRAY CONSTRUCTORS
# ==============================================================================

proc newInt32Array*(length: int): Int32Array {.importjs: "new Int32Array(#)".}
  ## Create a new Int32Array with the specified number of elements

proc newInt32Array*(buffer: JsObject, byteOffset: int, length: int): Int32Array {.importjs: "new Int32Array(#, #, #)".}
  ## Create an Int32Array view over a buffer at specified byte offset and length

proc newInt32Array*(buffer: JsObject): Int32Array {.importjs: "new Int32Array(#)".}
  ## Create an Int32Array view over an entire buffer

proc newInt32Array*(buffer: JsObject, byteOffset: int): Int32Array {.importjs: "new Int32Array(#, #)".}
  ## Create an Int32Array view from byteOffset to end of buffer

# ==============================================================================
# SECTION 8: INT16ARRAY CONSTRUCTORS
# ==============================================================================

proc newInt16Array*(length: int): Int16Array {.importjs: "new Int16Array(#)".}
  ## Create a new Int16Array with the specified number of elements

proc newInt16Array*(buffer: JsObject, byteOffset: int, length: int): Int16Array {.importjs: "new Int16Array(#, #, #)".}
  ## Create an Int16Array view over a buffer at specified byte offset and length

# ==============================================================================
# SECTION 9: INT8ARRAY CONSTRUCTORS
# ==============================================================================

proc newInt8Array*(length: int): Int8Array {.importjs: "new Int8Array(#)".}
  ## Create a new Int8Array with the specified number of elements

proc newInt8Array*(buffer: JsObject, byteOffset: int, length: int): Int8Array {.importjs: "new Int8Array(#, #, #)".}
  ## Create an Int8Array view over a buffer at specified byte offset and length

# ==============================================================================
# SECTION 10: UINT32ARRAY CONSTRUCTORS
# ==============================================================================

proc newUint32Array*(length: int): Uint32Array {.importjs: "new Uint32Array(#)".}
  ## Create a new Uint32Array with the specified number of elements

proc newUint32Array*(buffer: JsObject, byteOffset: int, length: int): Uint32Array {.importjs: "new Uint32Array(#, #, #)".}
  ## Create a Uint32Array view over a buffer at specified byte offset and length

proc newUint32Array*(buffer: JsObject): Uint32Array {.importjs: "new Uint32Array(#)".}
  ## Create a Uint32Array view over an entire buffer

proc newUint32Array*(buffer: JsObject, byteOffset: int): Uint32Array {.importjs: "new Uint32Array(#, #)".}
  ## Create a Uint32Array view from byteOffset to end of buffer

# ==============================================================================
# SECTION 11: UINT16ARRAY CONSTRUCTORS
# ==============================================================================

proc newUint16Array*(length: int): Uint16Array {.importjs: "new Uint16Array(#)".}
  ## Create a new Uint16Array with the specified number of elements

proc newUint16Array*(buffer: JsObject, byteOffset: int, length: int): Uint16Array {.importjs: "new Uint16Array(#, #, #)".}
  ## Create a Uint16Array view over a buffer at specified byte offset and length

# ==============================================================================
# SECTION 12: UINT8ARRAY CONSTRUCTORS
# ==============================================================================

proc newUint8Array*(length: int): Uint8Array {.importjs: "new Uint8Array(#)".}
  ## Create a new Uint8Array with the specified number of elements

proc newUint8Array*(buffer: JsObject, byteOffset: int, length: int): Uint8Array {.importjs: "new Uint8Array(#, #, #)".}
  ## Create a Uint8Array view over a buffer at specified byte offset and length

proc newUint8Array*(buffer: JsObject): Uint8Array {.importjs: "new Uint8Array(#)".}
  ## Create a Uint8Array view over an entire buffer

proc newUint8Array*(buffer: JsObject, byteOffset: int): Uint8Array {.importjs: "new Uint8Array(#, #)".}
  ## Create a Uint8Array view from byteOffset to end of buffer

# ==============================================================================
# SECTION 13: UINT8CLAMPEDARRAY CONSTRUCTORS
# ==============================================================================

proc newUint8ClampedArray*(length: int): Uint8ClampedArray {.importjs: "new Uint8ClampedArray(#)".}
  ## Create a new Uint8ClampedArray with the specified number of elements

proc newUint8ClampedArray*(buffer: JsObject, byteOffset: int, length: int): Uint8ClampedArray {.importjs: "new Uint8ClampedArray(#, #, #)".}
  ## Create a Uint8ClampedArray view over a buffer at specified byte offset and length

# ==============================================================================
# SECTION 14: FLOAT32ARRAY INDEX ACCESS
# ==============================================================================

proc `[]`*(arr: Float32Array, idx: int): float {.importjs: "#[#]".}
  ## Get element at index

proc `[]=`*(arr: Float32Array, idx: int, val: float) {.importjs: "#[#] = #".}
  ## Set element at index

# ==============================================================================
# SECTION 15: FLOAT64ARRAY INDEX ACCESS
# ==============================================================================

proc `[]`*(arr: Float64Array, idx: int): float {.importjs: "#[#]".}
  ## Get element at index

proc `[]=`*(arr: Float64Array, idx: int, val: float) {.importjs: "#[#] = #".}
  ## Set element at index

# ==============================================================================
# SECTION 16: INT32ARRAY INDEX ACCESS
# ==============================================================================

proc `[]`*(arr: Int32Array, idx: int): int {.importjs: "#[#]".}
  ## Get element at index

proc `[]=`*(arr: Int32Array, idx: int, val: int) {.importjs: "#[#] = #".}
  ## Set element at index

# ==============================================================================
# SECTION 17: INT16ARRAY INDEX ACCESS
# ==============================================================================

proc `[]`*(arr: Int16Array, idx: int): int {.importjs: "#[#]".}
  ## Get element at index

proc `[]=`*(arr: Int16Array, idx: int, val: int) {.importjs: "#[#] = #".}
  ## Set element at index

# ==============================================================================
# SECTION 18: INT8ARRAY INDEX ACCESS
# ==============================================================================

proc `[]`*(arr: Int8Array, idx: int): int {.importjs: "#[#]".}
  ## Get element at index

proc `[]=`*(arr: Int8Array, idx: int, val: int) {.importjs: "#[#] = #".}
  ## Set element at index

# ==============================================================================
# SECTION 19: UINT32ARRAY INDEX ACCESS
# ==============================================================================

proc `[]`*(arr: Uint32Array, idx: int): int {.importjs: "#[#]".}
  ## Get element at index

proc `[]=`*(arr: Uint32Array, idx: int, val: int) {.importjs: "#[#] = #".}
  ## Set element at index

# ==============================================================================
# SECTION 20: UINT16ARRAY INDEX ACCESS
# ==============================================================================

proc `[]`*(arr: Uint16Array, idx: int): int {.importjs: "#[#]".}
  ## Get element at index

proc `[]=`*(arr: Uint16Array, idx: int, val: int) {.importjs: "#[#] = #".}
  ## Set element at index

# ==============================================================================
# SECTION 21: UINT8ARRAY INDEX ACCESS
# ==============================================================================

proc `[]`*(arr: Uint8Array, idx: int): int {.importjs: "#[#]".}
  ## Get element at index

proc `[]=`*(arr: Uint8Array, idx: int, val: int) {.importjs: "#[#] = #".}
  ## Set element at index

# ==============================================================================
# SECTION 22: UINT8CLAMPEDARRAY INDEX ACCESS
# ==============================================================================

proc `[]`*(arr: Uint8ClampedArray, idx: int): int {.importjs: "#[#]".}
  ## Get element at index

proc `[]=`*(arr: Uint8ClampedArray, idx: int, val: int) {.importjs: "#[#] = #".}
  ## Set element at index (clamped to 0-255)

# ==============================================================================
# SECTION 23: LENGTH PROPERTY
# ==============================================================================

proc len*(arr: Float32Array): int {.importjs: "#.length".}
  ## Get the number of elements in the array

proc len*(arr: Float64Array): int {.importjs: "#.length".}
  ## Get the number of elements in the array

proc len*(arr: Int32Array): int {.importjs: "#.length".}
  ## Get the number of elements in the array

proc len*(arr: Int16Array): int {.importjs: "#.length".}
  ## Get the number of elements in the array

proc len*(arr: Int8Array): int {.importjs: "#.length".}
  ## Get the number of elements in the array

proc len*(arr: Uint32Array): int {.importjs: "#.length".}
  ## Get the number of elements in the array

proc len*(arr: Uint16Array): int {.importjs: "#.length".}
  ## Get the number of elements in the array

proc len*(arr: Uint8Array): int {.importjs: "#.length".}
  ## Get the number of elements in the array

proc len*(arr: Uint8ClampedArray): int {.importjs: "#.length".}
  ## Get the number of elements in the array

# ==============================================================================
# SECTION 24: BUFFER PROPERTY
# ==============================================================================

proc buffer*(arr: Float32Array): JsObject {.importjs: "#.buffer".}
  ## Get the underlying ArrayBuffer

proc buffer*(arr: Float64Array): JsObject {.importjs: "#.buffer".}
  ## Get the underlying ArrayBuffer

proc buffer*(arr: Int32Array): JsObject {.importjs: "#.buffer".}
  ## Get the underlying ArrayBuffer

proc buffer*(arr: Int16Array): JsObject {.importjs: "#.buffer".}
  ## Get the underlying ArrayBuffer

proc buffer*(arr: Int8Array): JsObject {.importjs: "#.buffer".}
  ## Get the underlying ArrayBuffer

proc buffer*(arr: Uint32Array): JsObject {.importjs: "#.buffer".}
  ## Get the underlying ArrayBuffer

proc buffer*(arr: Uint16Array): JsObject {.importjs: "#.buffer".}
  ## Get the underlying ArrayBuffer

proc buffer*(arr: Uint8Array): JsObject {.importjs: "#.buffer".}
  ## Get the underlying ArrayBuffer

proc buffer*(arr: Uint8ClampedArray): JsObject {.importjs: "#.buffer".}
  ## Get the underlying ArrayBuffer

# ==============================================================================
# SECTION 25: BYTEOFFSET PROPERTY
# ==============================================================================

proc byteOffset*(arr: Float32Array): int {.importjs: "#.byteOffset".}
  ## Get the byte offset from the start of the buffer

proc byteOffset*(arr: Float64Array): int {.importjs: "#.byteOffset".}
  ## Get the byte offset from the start of the buffer

proc byteOffset*(arr: Int32Array): int {.importjs: "#.byteOffset".}
  ## Get the byte offset from the start of the buffer

proc byteOffset*(arr: Int16Array): int {.importjs: "#.byteOffset".}
  ## Get the byte offset from the start of the buffer

proc byteOffset*(arr: Int8Array): int {.importjs: "#.byteOffset".}
  ## Get the byte offset from the start of the buffer

proc byteOffset*(arr: Uint32Array): int {.importjs: "#.byteOffset".}
  ## Get the byte offset from the start of the buffer

proc byteOffset*(arr: Uint16Array): int {.importjs: "#.byteOffset".}
  ## Get the byte offset from the start of the buffer

proc byteOffset*(arr: Uint8Array): int {.importjs: "#.byteOffset".}
  ## Get the byte offset from the start of the buffer

proc byteOffset*(arr: Uint8ClampedArray): int {.importjs: "#.byteOffset".}
  ## Get the byte offset from the start of the buffer

# ==============================================================================
# SECTION 26: BYTELENGTH PROPERTY
# ==============================================================================

proc byteLength*(arr: Float32Array): int {.importjs: "#.byteLength".}
  ## Get the length in bytes

proc byteLength*(arr: Float64Array): int {.importjs: "#.byteLength".}
  ## Get the length in bytes

proc byteLength*(arr: Int32Array): int {.importjs: "#.byteLength".}
  ## Get the length in bytes

proc byteLength*(arr: Int16Array): int {.importjs: "#.byteLength".}
  ## Get the length in bytes

proc byteLength*(arr: Int8Array): int {.importjs: "#.byteLength".}
  ## Get the length in bytes

proc byteLength*(arr: Uint32Array): int {.importjs: "#.byteLength".}
  ## Get the length in bytes

proc byteLength*(arr: Uint16Array): int {.importjs: "#.byteLength".}
  ## Get the length in bytes

proc byteLength*(arr: Uint8Array): int {.importjs: "#.byteLength".}
  ## Get the length in bytes

proc byteLength*(arr: Uint8ClampedArray): int {.importjs: "#.byteLength".}
  ## Get the length in bytes

proc byteLength*(buf: ArrayBuffer): int {.importjs: "#.byteLength".}
  ## Get the length in bytes

proc byteLength*(buf: SharedArrayBuffer): int {.importjs: "#.byteLength".}
  ## Get the length in bytes

# ==============================================================================
# SECTION 27: SUBARRAY METHOD
# ==============================================================================

proc subarray*(arr: Float32Array, begin: int, `end`: int): Float32Array {.importjs: "#.subarray(#, #)".}
  ## Return a new TypedArray view on the same buffer from begin to end (exclusive)

proc subarray*(arr: Float32Array, begin: int): Float32Array {.importjs: "#.subarray(#)".}
  ## Return a new TypedArray view on the same buffer from begin to end

proc subarray*(arr: Float64Array, begin: int, `end`: int): Float64Array {.importjs: "#.subarray(#, #)".}
  ## Return a new TypedArray view on the same buffer from begin to end (exclusive)

proc subarray*(arr: Float64Array, begin: int): Float64Array {.importjs: "#.subarray(#)".}
  ## Return a new TypedArray view on the same buffer from begin to end

proc subarray*(arr: Int32Array, begin: int, `end`: int): Int32Array {.importjs: "#.subarray(#, #)".}
  ## Return a new TypedArray view on the same buffer from begin to end (exclusive)

proc subarray*(arr: Int32Array, begin: int): Int32Array {.importjs: "#.subarray(#)".}
  ## Return a new TypedArray view on the same buffer from begin to end

proc subarray*(arr: Uint32Array, begin: int, `end`: int): Uint32Array {.importjs: "#.subarray(#, #)".}
  ## Return a new TypedArray view on the same buffer from begin to end (exclusive)

proc subarray*(arr: Uint32Array, begin: int): Uint32Array {.importjs: "#.subarray(#)".}
  ## Return a new TypedArray view on the same buffer from begin to end

proc subarray*(arr: Uint16Array, begin: int, `end`: int): Uint16Array {.importjs: "#.subarray(#, #)".}
  ## Return a new TypedArray view on the same buffer from begin to end (exclusive)

proc subarray*(arr: Uint16Array, begin: int): Uint16Array {.importjs: "#.subarray(#)".}
  ## Return a new TypedArray view on the same buffer from begin to end

proc subarray*(arr: Uint8Array, begin: int, `end`: int): Uint8Array {.importjs: "#.subarray(#, #)".}
  ## Return a new TypedArray view on the same buffer from begin to end (exclusive)

proc subarray*(arr: Uint8Array, begin: int): Uint8Array {.importjs: "#.subarray(#)".}
  ## Return a new TypedArray view on the same buffer from begin to end

# ==============================================================================
# SECTION 28: SET METHOD
# ==============================================================================

proc set*(arr: Float32Array, source: Float32Array, offset: int = 0) {.importjs: "#.set(#, #)".}
  ## Copy values from source array into this array at specified offset

proc set*(arr: Float64Array, source: Float64Array, offset: int = 0) {.importjs: "#.set(#, #)".}
  ## Copy values from source array into this array at specified offset

proc set*(arr: Int32Array, source: Int32Array, offset: int = 0) {.importjs: "#.set(#, #)".}
  ## Copy values from source array into this array at specified offset

proc set*(arr: Uint32Array, source: Uint32Array, offset: int = 0) {.importjs: "#.set(#, #)".}
  ## Copy values from source array into this array at specified offset

proc set*(arr: Uint16Array, source: Uint16Array, offset: int = 0) {.importjs: "#.set(#, #)".}
  ## Copy values from source array into this array at specified offset

proc set*(arr: Uint8Array, source: Uint8Array, offset: int = 0) {.importjs: "#.set(#, #)".}
  ## Copy values from source array into this array at specified offset

# ==============================================================================
# SECTION 29: SLICE METHOD
# ==============================================================================

proc slice*(arr: Float32Array, begin: int, `end`: int): Float32Array {.importjs: "#.slice(#, #)".}
  ## Return a new TypedArray containing a copy of elements from begin to end

proc slice*(arr: Float32Array, begin: int): Float32Array {.importjs: "#.slice(#)".}
  ## Return a new TypedArray containing a copy of elements from begin to end

proc slice*(arr: Int32Array, begin: int, `end`: int): Int32Array {.importjs: "#.slice(#, #)".}
  ## Return a new TypedArray containing a copy of elements from begin to end

proc slice*(arr: Int32Array, begin: int): Int32Array {.importjs: "#.slice(#)".}
  ## Return a new TypedArray containing a copy of elements from begin to end

proc slice*(arr: Uint32Array, begin: int, `end`: int): Uint32Array {.importjs: "#.slice(#, #)".}
  ## Return a new TypedArray containing a copy of elements from begin to end

proc slice*(arr: Uint32Array, begin: int): Uint32Array {.importjs: "#.slice(#)".}
  ## Return a new TypedArray containing a copy of elements from begin to end

proc slice*(arr: Uint8Array, begin: int, `end`: int): Uint8Array {.importjs: "#.slice(#, #)".}
  ## Return a new TypedArray containing a copy of elements from begin to end

proc slice*(arr: Uint8Array, begin: int): Uint8Array {.importjs: "#.slice(#)".}
  ## Return a new TypedArray containing a copy of elements from begin to end

proc slice*(buf: ArrayBuffer, begin: int, `end`: int): ArrayBuffer {.importjs: "#.slice(#, #)".}
  ## Return a new ArrayBuffer containing a copy of bytes from begin to end

proc slice*(buf: ArrayBuffer, begin: int): ArrayBuffer {.importjs: "#.slice(#)".}
  ## Return a new ArrayBuffer containing a copy of bytes from begin to end

# ==============================================================================
# SECTION 30: WEBASSEMBLY.MEMORY CONSTRUCTOR
# ==============================================================================

proc newWebAssemblyMemory*(initial: int, maximum: int, shared: bool): WebAssemblyMemory {.importjs: "new WebAssembly.Memory({initial: #, maximum: #, shared: #})".}
  ## Create a new WebAssembly.Memory with initial pages, maximum pages, and shared flag
  ##
  ## Parameters:
  ##   initial - Initial memory size in 64KB pages
  ##   maximum - Maximum memory size in 64KB pages
  ##   shared - If true, creates a SharedArrayBuffer-backed memory

proc newWebAssemblyMemory*(initial: int, maximum: int): WebAssemblyMemory {.importjs: "new WebAssembly.Memory({initial: #, maximum: #})".}
  ## Create a new WebAssembly.Memory with initial and maximum pages (non-shared)

proc newWebAssemblyMemory*(initial: int): WebAssemblyMemory {.importjs: "new WebAssembly.Memory({initial: #})".}
  ## Create a new growable WebAssembly.Memory with initial pages

# ==============================================================================
# SECTION 31: WEBASSEMBLY.MEMORY METHODS
# ==============================================================================

proc grow*(mem: WebAssemblyMemory, delta: int): int {.importjs: "#.grow(#)".}
  ## Grow memory by delta pages, returns previous size in pages

# ==============================================================================
# SECTION 32: FILL METHOD
# ==============================================================================

proc fill*(arr: Float32Array, value: float, start: int, `end`: int) {.importjs: "#.fill(#, #, #)".}
  ## Fill all elements from start to end with the given value

proc fill*(arr: Float32Array, value: float) {.importjs: "#.fill(#)".}
  ## Fill all elements with the given value

proc fill*(arr: Int32Array, value: int, start: int, `end`: int) {.importjs: "#.fill(#, #, #)".}
  ## Fill all elements from start to end with the given value

proc fill*(arr: Int32Array, value: int) {.importjs: "#.fill(#)".}
  ## Fill all elements with the given value

proc fill*(arr: Uint32Array, value: int, start: int, `end`: int) {.importjs: "#.fill(#, #, #)".}
  ## Fill all elements from start to end with the given value

proc fill*(arr: Uint32Array, value: int) {.importjs: "#.fill(#)".}
  ## Fill all elements with the given value

proc fill*(arr: Uint16Array, value: int, start: int, `end`: int) {.importjs: "#.fill(#, #, #)".}
  ## Fill all elements from start to end with the given value

proc fill*(arr: Uint16Array, value: int) {.importjs: "#.fill(#)".}
  ## Fill all elements with the given value

proc fill*(arr: Uint8Array, value: int, start: int, `end`: int) {.importjs: "#.fill(#, #, #)".}
  ## Fill all elements from start to end with the given value

proc fill*(arr: Uint8Array, value: int) {.importjs: "#.fill(#)".}
  ## Fill all elements with the given value

# ==============================================================================
# SECTION 33: COPYWITHIN METHOD
# ==============================================================================

proc copyWithin*(arr: Float32Array, target: int, start: int, `end`: int): Float32Array {.importjs: "#.copyWithin(#, #, #)".}
  ## Copy elements within the array to target position from start to end

proc copyWithin*(arr: Float32Array, target: int, start: int): Float32Array {.importjs: "#.copyWithin(#, #)".}
  ## Copy elements within the array to target position from start to end

proc copyWithin*(arr: Int32Array, target: int, start: int, `end`: int): Int32Array {.importjs: "#.copyWithin(#, #, #)".}
  ## Copy elements within the array to target position from start to end

proc copyWithin*(arr: Uint32Array, target: int, start: int, `end`: int): Uint32Array {.importjs: "#.copyWithin(#, #, #)".}
  ## Copy elements within the array to target position from start to end

proc copyWithin*(arr: Uint8Array, target: int, start: int, `end`: int): Uint8Array {.importjs: "#.copyWithin(#, #, #)".}
  ## Copy elements within the array to target position from start to end

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

# ==============================================================================
# SECTION 35: LEGACY CONSTRUCTOR ALIASES
# ==============================================================================

# These match the naming conventions in existing codebase (buffers.nim, grid.nim)
proc newFloat32ArrayView*(buffer: JsObject, byteOffset: int, length: int): Float32Array {.importjs: "new Float32Array(#, #, #)".}
  ## Legacy alias for newFloat32Array

proc newUint8ArrayView*(buffer: JsObject, byteOffset: int, length: int): Uint8Array {.importjs: "new Uint8Array(#, #, #)".}
  ## Legacy alias for newUint8Array

proc newUint16ArrayView*(buffer: JsObject, byteOffset: int, length: int): Uint16Array {.importjs: "new Uint16Array(#, #, #)".}
  ## Legacy alias for newUint16Array

proc newUint32ArrayView*(buffer: JsObject, byteOffset: int, length: int): Uint32Array {.importjs: "new Uint32Array(#, #, #)".}
  ## Legacy alias for newUint32Array

proc newInt32ArrayView*(buffer: JsObject, byteOffset: int, length: int): Int32Array {.importjs: "new Int32Array(#, #, #)".}
  ## Legacy alias for newInt32Array

proc newUint32ArrayLocal*(length: int): Uint32Array {.importjs: "new Uint32Array(#)".}
  ## Legacy alias for newUint32Array (local allocation)

proc newFloat32ArrayLocal*(length: int): Float32Array {.importjs: "new Float32Array(#)".}
  ## Legacy alias for newFloat32Array (local allocation)
