# ==============================================================================
# EMERGENT GARDEN - ATOMICS API BINDINGS
# ==============================================================================
#
# Centralized bindings for JavaScript Atomics API used for SharedArrayBuffer
# synchronization in the worker pool architecture.
#
# This module provides idiomatic Nim bindings for:
# - Atomic read/write operations (load, store)
# - Atomic read-modify-write operations (add, sub, exchange, compareExchange)
# - Wait/notify synchronization primitives
# - Async wait for non-blocking worker coordination
#
# USAGE:
#   import bindings/atomics
#
#   let arr = newInt32Array(sharedBuffer, 0, 10)
#   atomicStore(arr, 0, 42)
#   let val = atomicLoad(arr, 0)
#   atomicNotify(arr, 0)  # Wake all waiters
#
# THREAD SAFETY:
#   All operations in this module are atomic and safe for concurrent access
#   from multiple workers sharing the same SharedArrayBuffer.
#
# ==============================================================================

from std/jsffi import JsObject
import ./js_interop
import ./typed_arrays

# ==============================================================================
# SECTION 1: WAIT RESULT TYPES
# ==============================================================================

type
  AtomicsWaitResultKind* = enum
    ## Result of a synchronous Atomics.wait() call.
    ##
    ## - awrOk: The wait was woken by a notify call
    ## - awrNotEqual: The value at the index was not equal to the expected value
    ## - awrTimedOut: The timeout expired before being notified
    awrOk = "ok"
    awrNotEqual = "not-equal"
    awrTimedOut = "timed-out"

  AtomicsWaitAsyncResult* = ref object of JsObject
    ## Result object from Atomics.waitAsync().
    ##
    ## The `async` field indicates whether the wait is asynchronous:
    ## - If true, `value` is a Promise that resolves to "ok" or "timed-out"
    ## - If false, `value` is the immediate result string
    async* {.importjs: "async".}: bool
    value* {.importjs: "value".}: JsObject

# ==============================================================================
# SECTION 2: ATOMIC LOAD AND STORE
# ==============================================================================

proc atomicLoad*(arr: Int32Array, index: int): int {.importjs: "Atomics.load(#, #)".}
  ## Atomically read the value at the given index.
  ##
  ## Returns the value at arr[index] with acquire semantics.
  ##
  ## Parameters:
  ##   arr - An Int32Array view over a SharedArrayBuffer
  ##   index - The element index to read

proc atomicStore*(arr: Int32Array, index: int, value: int): int {.importjs: "Atomics.store(#, #, #)".}
  ## Atomically write a value at the given index.
  ##
  ## Returns the value that was written (for chaining).
  ##
  ## Parameters:
  ##   arr - An Int32Array view over a SharedArrayBuffer
  ##   index - The element index to write
  ##   value - The value to store

# ==============================================================================
# SECTION 3: ATOMIC READ-MODIFY-WRITE OPERATIONS
# ==============================================================================

proc atomicAdd*(arr: Int32Array, index: int, value: int): int {.importjs: "Atomics.add(#, #, #)".}
  ## Atomically add a value and return the old value.
  ##
  ## Equivalent to: old = arr[index]; arr[index] += value; return old
  ##
  ## Parameters:
  ##   arr - An Int32Array view over a SharedArrayBuffer
  ##   index - The element index
  ##   value - The value to add
  ##
  ## Returns: The previous value at the index (before addition)

proc atomicSub*(arr: Int32Array, index: int, value: int): int {.importjs: "Atomics.sub(#, #, #)".}
  ## Atomically subtract a value and return the old value.
  ##
  ## Equivalent to: old = arr[index]; arr[index] -= value; return old
  ##
  ## Parameters:
  ##   arr - An Int32Array view over a SharedArrayBuffer
  ##   index - The element index
  ##   value - The value to subtract
  ##
  ## Returns: The previous value at the index (before subtraction)

proc atomicAnd*(arr: Int32Array, index: int, value: int): int {.importjs: "Atomics.and(#, #, #)".}
  ## Atomically perform bitwise AND and return the old value.
  ##
  ## Equivalent to: old = arr[index]; arr[index] &= value; return old
  ##
  ## Parameters:
  ##   arr - An Int32Array view over a SharedArrayBuffer
  ##   index - The element index
  ##   value - The value to AND with
  ##
  ## Returns: The previous value at the index (before AND)

proc atomicOr*(arr: Int32Array, index: int, value: int): int {.importjs: "Atomics.or(#, #, #)".}
  ## Atomically perform bitwise OR and return the old value.
  ##
  ## Equivalent to: old = arr[index]; arr[index] |= value; return old
  ##
  ## Parameters:
  ##   arr - An Int32Array view over a SharedArrayBuffer
  ##   index - The element index
  ##   value - The value to OR with
  ##
  ## Returns: The previous value at the index (before OR)

proc atomicXor*(arr: Int32Array, index: int, value: int): int {.importjs: "Atomics.xor(#, #, #)".}
  ## Atomically perform bitwise XOR and return the old value.
  ##
  ## Equivalent to: old = arr[index]; arr[index] ^= value; return old
  ##
  ## Parameters:
  ##   arr - An Int32Array view over a SharedArrayBuffer
  ##   index - The element index
  ##   value - The value to XOR with
  ##
  ## Returns: The previous value at the index (before XOR)

proc atomicExchange*(arr: Int32Array, index: int, value: int): int {.importjs: "Atomics.exchange(#, #, #)".}
  ## Atomically exchange the value at index and return the old value.
  ##
  ## Equivalent to: old = arr[index]; arr[index] = value; return old
  ##
  ## Parameters:
  ##   arr - An Int32Array view over a SharedArrayBuffer
  ##   index - The element index
  ##   value - The new value to store
  ##
  ## Returns: The previous value at the index

proc atomicCompareExchange*(arr: Int32Array, index: int, expectedValue: int, replacementValue: int): int {.importjs: "Atomics.compareExchange(#, #, #, #)".}
  ## Atomically compare and exchange (CAS operation).
  ##
  ## If arr[index] equals expectedValue, store replacementValue.
  ## Returns the original value regardless of success.
  ##
  ## To check if the exchange succeeded: result == expectedValue
  ##
  ## Parameters:
  ##   arr - An Int32Array view over a SharedArrayBuffer
  ##   index - The element index
  ##   expectedValue - The value expected at the index
  ##   replacementValue - The value to store if expectation matches
  ##
  ## Returns: The original value at the index (compare with expectedValue to check success)

# ==============================================================================
# SECTION 4: WAIT AND NOTIFY (SYNCHRONIZATION)
# ==============================================================================

proc atomicWait*(arr: Int32Array, index: int, value: int): cstring {.importjs: "Atomics.wait(#, #, #)".}
  ## Block until notified or the value changes.
  ##
  ## IMPORTANT: This is a BLOCKING call and can only be used in workers,
  ## not in the main thread where it will throw an error.
  ##
  ## The agent will sleep, blocking the thread, until:
  ## - Another agent calls atomicNotify on this index, OR
  ## - The value at index is no longer equal to value
  ##
  ## Parameters:
  ##   arr - An Int32Array view over a SharedArrayBuffer
  ##   index - The element index to watch
  ##   value - The expected value (returns immediately if different)
  ##
  ## Returns: "ok" | "not-equal" | "timed-out"

proc atomicWait*(arr: Int32Array, index: int, value: int, timeout: int): cstring {.importjs: "Atomics.wait(#, #, #, #)".}
  ## Block until notified, the value changes, or timeout expires.
  ##
  ## IMPORTANT: This is a BLOCKING call and can only be used in workers,
  ## not in the main thread where it will throw an error.
  ##
  ## Parameters:
  ##   arr - An Int32Array view over a SharedArrayBuffer
  ##   index - The element index to watch
  ##   value - The expected value (returns immediately if different)
  ##   timeout - Maximum wait time in milliseconds
  ##
  ## Returns: "ok" | "not-equal" | "timed-out"

proc atomicNotify*(arr: Int32Array, index: int): int {.importjs: "Atomics.notify(#, #)".}
  ## Wake all agents waiting on the given index.
  ##
  ## Returns the number of agents that were woken.
  ##
  ## Parameters:
  ##   arr - An Int32Array view over a SharedArrayBuffer
  ##   index - The element index where agents may be waiting
  ##
  ## Returns: Number of agents woken (0 if none were waiting)

proc atomicNotify*(arr: Int32Array, index: int, count: int): int {.importjs: "Atomics.notify(#, #, #)".}
  ## Wake up to `count` agents waiting on the given index.
  ##
  ## Use Infinity to wake all waiters (or use the overload without count).
  ##
  ## Parameters:
  ##   arr - An Int32Array view over a SharedArrayBuffer
  ##   index - The element index where agents may be waiting
  ##   count - Maximum number of agents to wake
  ##
  ## Returns: Number of agents actually woken

# ==============================================================================
# SECTION 5: ASYNC WAIT (NON-BLOCKING)
# ==============================================================================

proc atomicWaitAsync*(arr: Int32Array, index: int, value: int): AtomicsWaitAsyncResult {.importjs: "Atomics.waitAsync(#, #, #)".}
  ## Asynchronously wait for a notification (non-blocking).
  ##
  ## Unlike atomicWait, this can be called from the main thread.
  ##
  ## Returns an object with:
  ## - async: true if waiting asynchronously, false if resolved immediately
  ## - value: A Promise (if async=true) or the result string (if async=false)
  ##
  ## When async=true, the promise resolves to "ok" or "timed-out".
  ## When async=false (value at index != expected), value is "not-equal".
  ##
  ## Parameters:
  ##   arr - An Int32Array view over a SharedArrayBuffer
  ##   index - The element index to watch
  ##   value - The expected value

proc atomicWaitAsync*(arr: Int32Array, index: int, value: int, timeout: int): AtomicsWaitAsyncResult {.importjs: "Atomics.waitAsync(#, #, #, #)".}
  ## Asynchronously wait with timeout (non-blocking).
  ##
  ## Parameters:
  ##   arr - An Int32Array view over a SharedArrayBuffer
  ##   index - The element index to watch
  ##   value - The expected value
  ##   timeout - Maximum wait time in milliseconds

# ==============================================================================
# SECTION 6: UTILITY FUNCTIONS
# ==============================================================================

proc atomicIsLockFree*(size: int): bool {.importjs: "Atomics.isLockFree(#)".}
  ## Check if atomic operations on the given byte size are lock-free.
  ##
  ## Lock-free operations are guaranteed to complete without blocking,
  ## typically implemented with native CPU atomic instructions.
  ##
  ## Parameters:
  ##   size - Byte size to check (1, 2, 4, or 8)
  ##
  ## Returns: true if operations are lock-free, false otherwise

# ==============================================================================
# SECTION 7: BIGINT64 VARIANTS (FOR 64-BIT ATOMICS)
# ==============================================================================

# Note: BigInt64Array atomics require BigInt values in JavaScript.
# These bindings use int64 which Nim compiles to BigInt in JS backend.

proc atomicLoad*(arr: JsObject, index: int): int64 {.importjs: "Atomics.load(#, #)".}
  ## Atomically read from BigInt64Array or BigUint64Array.
  ##
  ## Parameters:
  ##   arr - A BigInt64Array or BigUint64Array view
  ##   index - The element index to read

proc atomicStore64*(arr: JsObject, index: int, value: int64): int64 {.importjs: "Atomics.store(#, #, BigInt(#))".}
  ## Atomically write to BigInt64Array.
  ##
  ## Note: Converts Nim int64 to JavaScript BigInt.

# ==============================================================================
# SECTION 8: RESULT PARSING UTILITIES
# ==============================================================================

proc parseWaitResult*(waitResult: cstring): AtomicsWaitResultKind =
  ## Parse a wait result string into the enum type.
  ##
  ## Parameters:
  ##   waitResult - The string returned by atomicWait
  ##
  ## Returns: The corresponding AtomicsWaitResultKind value
  if waitResult == cstring"ok":
    awrOk
  elif waitResult == cstring"not-equal":
    awrNotEqual
  else:
    awrTimedOut

proc isWaitAsync*(waitResult: AtomicsWaitAsyncResult): bool =
  ## Check if the waitAsync result requires async handling.
  ##
  ## Returns true if waitResult.value is a Promise that needs to be awaited.
  waitResult.async

proc getWaitAsyncPromise*(waitResult: AtomicsWaitAsyncResult): JsPromise[cstring] =
  ## Get the promise from an async wait result.
  ##
  ## Only call this when isWaitAsync() returns true.
  cast[JsPromise[cstring]](waitResult.value)

# ==============================================================================
# SECTION 9: TYPE ALIASES FOR BACKWARDS COMPATIBILITY
# ==============================================================================

# Legacy naming from workers.nim (atomicsStore vs atomicStore)
proc atomicsStore*(arr: Int32Array, index: int, value: int): int {.importjs: "Atomics.store(#, #, #)".}
  ## Legacy alias for atomicStore (matches workers.nim naming)

proc atomicsLoad*(arr: Int32Array, index: int): int {.importjs: "Atomics.load(#, #)".}
  ## Legacy alias for atomicLoad (matches workers.nim naming)

proc atomicsNotify*(arr: Int32Array, index: int): int {.importjs: "Atomics.notify(#, #)".}
  ## Legacy alias for atomicNotify (matches workers.nim naming)

proc atomicsWaitAsync*(arr: Int32Array, index: int, value: int): AtomicsWaitAsyncResult {.importjs: "Atomics.waitAsync(#, #, #)".}
  ## Legacy alias for atomicWaitAsync (matches workers.nim naming)

# Note: Int32ArrayView is a type alias for Int32Array in typed_arrays.nim,
# so all Int32Array procs automatically work with Int32ArrayView.
