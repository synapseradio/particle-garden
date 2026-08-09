import std/jsffi

type
  ArrayBuffer* = ref object of JsObject

  SharedArrayBuffer* = ref object of JsObject

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

type
  WebAssemblyMemory* = ref object of JsObject
    buffer* {.importjs: "buffer".}: JsObject

proc newArrayBuffer*(byteLength: int): ArrayBuffer {.importjs: "new ArrayBuffer(#)".}

proc newSharedArrayBuffer*(byteLength: int): SharedArrayBuffer {.importjs: "new SharedArrayBuffer(#)".}

proc newFloat32Array*(length: int): Float32Array {.importjs: "new Float32Array(#)".}

proc newFloat32Array*(buffer: JsObject, byteOffset: int, length: int): Float32Array {.importjs: "new Float32Array(#, #, #)".}

proc newFloat32Array*(buffer: JsObject): Float32Array {.importjs: "new Float32Array(#)".}

proc newFloat32Array*(buffer: JsObject, byteOffset: int): Float32Array {.importjs: "new Float32Array(#, #)".}

proc newFloat32Array*(values: seq[float]): Float32Array {.importjs: "new Float32Array(#)".}

proc newFloat32Array*(values: seq[float32]): Float32Array {.importjs: "new Float32Array(#)".}

proc newFloat64Array*(length: int): Float64Array {.importjs: "new Float64Array(#)".}

proc newFloat64Array*(buffer: JsObject, byteOffset: int, length: int): Float64Array {.importjs: "new Float64Array(#, #, #)".}

proc newInt32Array*(length: int): Int32Array {.importjs: "new Int32Array(#)".}

proc newInt32Array*(buffer: JsObject, byteOffset: int, length: int): Int32Array {.importjs: "new Int32Array(#, #, #)".}

proc newInt32Array*(buffer: JsObject): Int32Array {.importjs: "new Int32Array(#)".}

proc newInt32Array*(buffer: JsObject, byteOffset: int): Int32Array {.importjs: "new Int32Array(#, #)".}

proc newInt16Array*(length: int): Int16Array {.importjs: "new Int16Array(#)".}

proc newInt16Array*(buffer: JsObject, byteOffset: int, length: int): Int16Array {.importjs: "new Int16Array(#, #, #)".}

proc newInt8Array*(length: int): Int8Array {.importjs: "new Int8Array(#)".}

proc newInt8Array*(buffer: JsObject, byteOffset: int, length: int): Int8Array {.importjs: "new Int8Array(#, #, #)".}

proc newUint32Array*(length: int): Uint32Array {.importjs: "new Uint32Array(#)".}

proc newUint32Array*(buffer: JsObject, byteOffset: int, length: int): Uint32Array {.importjs: "new Uint32Array(#, #, #)".}

proc newUint32Array*(buffer: JsObject): Uint32Array {.importjs: "new Uint32Array(#)".}

proc newUint32Array*(buffer: JsObject, byteOffset: int): Uint32Array {.importjs: "new Uint32Array(#, #)".}

proc newUint16Array*(length: int): Uint16Array {.importjs: "new Uint16Array(#)".}

proc newUint16Array*(buffer: JsObject, byteOffset: int, length: int): Uint16Array {.importjs: "new Uint16Array(#, #, #)".}

proc newUint8Array*(length: int): Uint8Array {.importjs: "new Uint8Array(#)".}

proc newUint8Array*(buffer: JsObject, byteOffset: int, length: int): Uint8Array {.importjs: "new Uint8Array(#, #, #)".}

proc newUint8Array*(buffer: JsObject): Uint8Array {.importjs: "new Uint8Array(#)".}

proc newUint8Array*(buffer: JsObject, byteOffset: int): Uint8Array {.importjs: "new Uint8Array(#, #)".}

proc newUint8ClampedArray*(length: int): Uint8ClampedArray {.importjs: "new Uint8ClampedArray(#)".}

proc newUint8ClampedArray*(buffer: JsObject, byteOffset: int, length: int): Uint8ClampedArray {.importjs: "new Uint8ClampedArray(#, #, #)".}

proc `[]`*(arr: Float32Array, idx: int): float {.importjs: "#[#]".}

proc `[]=`*(arr: Float32Array, idx: int, val: float) {.importjs: "#[#] = #".}

proc `[]`*(arr: Float64Array, idx: int): float {.importjs: "#[#]".}

proc `[]=`*(arr: Float64Array, idx: int, val: float) {.importjs: "#[#] = #".}

proc `[]`*(arr: Int32Array, idx: int): int {.importjs: "#[#]".}

proc `[]=`*(arr: Int32Array, idx: int, val: int) {.importjs: "#[#] = #".}

proc `[]`*(arr: Int16Array, idx: int): int {.importjs: "#[#]".}

proc `[]=`*(arr: Int16Array, idx: int, val: int) {.importjs: "#[#] = #".}

proc `[]`*(arr: Int8Array, idx: int): int {.importjs: "#[#]".}

proc `[]=`*(arr: Int8Array, idx: int, val: int) {.importjs: "#[#] = #".}

proc `[]`*(arr: Uint32Array, idx: int): int {.importjs: "#[#]".}

proc `[]=`*(arr: Uint32Array, idx: int, val: int) {.importjs: "#[#] = #".}

proc `[]`*(arr: Uint16Array, idx: int): int {.importjs: "#[#]".}

proc `[]=`*(arr: Uint16Array, idx: int, val: int) {.importjs: "#[#] = #".}

proc `[]`*(arr: Uint8Array, idx: int): int {.importjs: "#[#]".}

proc `[]=`*(arr: Uint8Array, idx: int, val: int) {.importjs: "#[#] = #".}

proc `[]`*(arr: Uint8ClampedArray, idx: int): int {.importjs: "#[#]".}

proc `[]=`*(arr: Uint8ClampedArray, idx: int, val: int) {.importjs: "#[#] = #".}

proc len*(arr: Float32Array): int {.importjs: "#.length".}

proc len*(arr: Float64Array): int {.importjs: "#.length".}

proc len*(arr: Int32Array): int {.importjs: "#.length".}

proc len*(arr: Int16Array): int {.importjs: "#.length".}

proc len*(arr: Int8Array): int {.importjs: "#.length".}

proc len*(arr: Uint32Array): int {.importjs: "#.length".}

proc len*(arr: Uint16Array): int {.importjs: "#.length".}

proc len*(arr: Uint8Array): int {.importjs: "#.length".}

proc len*(arr: Uint8ClampedArray): int {.importjs: "#.length".}

proc buffer*(arr: Float32Array): JsObject {.importjs: "#.buffer".}

proc buffer*(arr: Float64Array): JsObject {.importjs: "#.buffer".}

proc buffer*(arr: Int32Array): JsObject {.importjs: "#.buffer".}

proc buffer*(arr: Int16Array): JsObject {.importjs: "#.buffer".}

proc buffer*(arr: Int8Array): JsObject {.importjs: "#.buffer".}

proc buffer*(arr: Uint32Array): JsObject {.importjs: "#.buffer".}

proc buffer*(arr: Uint16Array): JsObject {.importjs: "#.buffer".}

proc buffer*(arr: Uint8Array): JsObject {.importjs: "#.buffer".}

proc buffer*(arr: Uint8ClampedArray): JsObject {.importjs: "#.buffer".}

proc byteOffset*(arr: Float32Array): int {.importjs: "#.byteOffset".}

proc byteOffset*(arr: Float64Array): int {.importjs: "#.byteOffset".}

proc byteOffset*(arr: Int32Array): int {.importjs: "#.byteOffset".}

proc byteOffset*(arr: Int16Array): int {.importjs: "#.byteOffset".}

proc byteOffset*(arr: Int8Array): int {.importjs: "#.byteOffset".}

proc byteOffset*(arr: Uint32Array): int {.importjs: "#.byteOffset".}

proc byteOffset*(arr: Uint16Array): int {.importjs: "#.byteOffset".}

proc byteOffset*(arr: Uint8Array): int {.importjs: "#.byteOffset".}

proc byteOffset*(arr: Uint8ClampedArray): int {.importjs: "#.byteOffset".}

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

proc set*(arr: Float32Array, source: Float32Array, offset: int = 0) {.importjs: "#.set(#, #)".}

proc set*(arr: Float64Array, source: Float64Array, offset: int = 0) {.importjs: "#.set(#, #)".}

proc set*(arr: Int32Array, source: Int32Array, offset: int = 0) {.importjs: "#.set(#, #)".}

proc set*(arr: Uint32Array, source: Uint32Array, offset: int = 0) {.importjs: "#.set(#, #)".}

proc set*(arr: Uint16Array, source: Uint16Array, offset: int = 0) {.importjs: "#.set(#, #)".}

proc set*(arr: Uint8Array, source: Uint8Array, offset: int = 0) {.importjs: "#.set(#, #)".}

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

proc newWebAssemblyMemory*(initial: int, maximum: int, shared: bool): WebAssemblyMemory {.importjs: "new WebAssembly.Memory({initial: #, maximum: #, shared: #})".}
  ## `initial` and `maximum` count 64KiB pages, the unit WebAssembly linear memory grows by.
  ## https://webassembly.github.io/spec/core/exec/runtime.html

proc newWebAssemblyMemory*(initial: int, maximum: int): WebAssemblyMemory {.importjs: "new WebAssembly.Memory({initial: #, maximum: #})".}

proc newWebAssemblyMemory*(initial: int): WebAssemblyMemory {.importjs: "new WebAssembly.Memory({initial: #})".}

proc grow*(mem: WebAssemblyMemory, delta: int): int {.importjs: "#.grow(#)".}

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

proc copyWithin*(arr: Float32Array, target: int, start: int, `end`: int): Float32Array {.importjs: "#.copyWithin(#, #, #)".}

proc copyWithin*(arr: Float32Array, target: int, start: int): Float32Array {.importjs: "#.copyWithin(#, #)".}

proc copyWithin*(arr: Int32Array, target: int, start: int, `end`: int): Int32Array {.importjs: "#.copyWithin(#, #, #)".}

proc copyWithin*(arr: Uint32Array, target: int, start: int, `end`: int): Uint32Array {.importjs: "#.copyWithin(#, #, #)".}

proc copyWithin*(arr: Uint8Array, target: int, start: int, `end`: int): Uint8Array {.importjs: "#.copyWithin(#, #, #)".}
