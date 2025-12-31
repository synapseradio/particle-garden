# ==============================================================================
# PARTICLE GARDEN - SYNC PROTOCOL TESTS
# ==============================================================================
#
# Unit tests for sync buffer protocol offset calculations.
# Verifies that workers.nim and worker.nim will compute matching offsets.
#
# Run with: nimble test
#
# ==============================================================================

import std/unittest
import ../src/sync_protocol
import ../src/memory_layout

# Export a constant so test_all.nim can reference it
const SYNC_PROTOCOL_TESTS_LOADED* = true

# ==============================================================================
# FIXED INDEX TESTS
# ==============================================================================

suite "Sync Protocol Fixed Indices":
  test "frame counter is at index 0":
    check SYNC_FRAME_COUNTER == 0

  test "worker count is at index 1":
    check SYNC_WORKER_COUNT == 1

  test "worker pairs start at index 2":
    check SYNC_WORKER_PAIRS_START == 2

# ==============================================================================
# WORKER RANGE OFFSET TESTS
# ==============================================================================

suite "Sync Protocol Worker Range Offsets":
  test "worker 0 range is at indices 2 and 3":
    let (start, fin) = workerRangeOffset(0)
    check start == 2
    check fin == 3

  test "worker 1 range is at indices 4 and 5":
    let (start, fin) = workerRangeOffset(1)
    check start == 4
    check fin == 5

  test "worker N range is at indices 2+N*2 and 3+N*2":
    for n in 0 ..< 16:
      let (start, fin) = workerRangeOffset(n)
      check start == 2 + n * 2
      check fin == 3 + n * 2

# ==============================================================================
# CONFIG OFFSET TESTS
# ==============================================================================

suite "Sync Protocol Config Offsets":
  test "config offset with 1 worker is 4":
    # workerCount=1: pairs occupy [2,3], config starts at 4
    check configOffset(1) == 4

  test "config offset with 4 workers is 10":
    # workerCount=4: pairs occupy [2..9], config starts at 10
    check configOffset(4) == 10

  test "config offset with 16 workers is 34":
    # workerCount=16: pairs occupy [2..33], config starts at 34
    check configOffset(16) == 34

  test "config offset formula is 2 + workerCount * 2":
    for w in 1 .. MAX_WORKERS:
      check configOffset(w) == 2 + w * 2

# ==============================================================================
# CONFIG FIELD INDEX TESTS
# ==============================================================================

suite "Sync Protocol Config Field Indices":
  test "width is at configOffset + 0":
    check configFieldIndex(4, scfWidth) == configOffset(4) + 0

  test "height is at configOffset + 1":
    check configFieldIndex(4, scfHeight) == configOffset(4) + 1

  test "particle count is at configOffset + 13":
    check configFieldIndex(4, scfParticleCount) == configOffset(4) + 13

  test "all fields have correct relative offsets":
    let co = configOffset(8)
    check configFieldIndex(8, scfWidth) == co + 0
    check configFieldIndex(8, scfHeight) == co + 1
    check configFieldIndex(8, scfRadius) == co + 2
    check configFieldIndex(8, scfGridW) == co + 3
    check configFieldIndex(8, scfGridH) == co + 4
    check configFieldIndex(8, scfCellSize) == co + 5
    check configFieldIndex(8, scfForceStrength) == co + 6
    check configFieldIndex(8, scfDt) == co + 7
    check configFieldIndex(8, scfMouseX) == co + 8
    check configFieldIndex(8, scfMouseY) == co + 9
    check configFieldIndex(8, scfMouseDown) == co + 10
    check configFieldIndex(8, scfMouseRightDown) == co + 11
    check configFieldIndex(8, scfParity) == co + 12
    check configFieldIndex(8, scfParticleCount) == co + 13

# ==============================================================================
# DONE OFFSET TESTS
# ==============================================================================

suite "Sync Protocol Done Flag Offsets":
  test "done offset is configOffset + 16":
    for w in 1 .. MAX_WORKERS:
      check doneOffset(w) == configOffset(w) + SYNC_CONFIG_SIZE

  test "done flag index for worker 0 is doneOffset":
    check doneFlagIndex(4, 0) == doneOffset(4)

  test "done flag indices are consecutive":
    let base = doneOffset(8)
    for i in 0 ..< 8:
      check doneFlagIndex(8, i) == base + i

# ==============================================================================
# PARTICLE DIVISION TESTS
# ==============================================================================

suite "Sync Protocol Particle Division":
  test "divides particles evenly among workers":
    let ranges = divideParticles(1000, 4)
    check ranges.len == 4
    check ranges[0] == (startIdx: 0, endIdx: 250)
    check ranges[1] == (startIdx: 250, endIdx: 500)
    check ranges[2] == (startIdx: 500, endIdx: 750)
    check ranges[3] == (startIdx: 750, endIdx: 1000)

  test "handles uneven division (last worker gets remainder)":
    let ranges = divideParticles(1003, 4)
    # perWorker = ceil(1003/4) = 251
    check ranges[0] == (startIdx: 0, endIdx: 251)
    check ranges[1] == (startIdx: 251, endIdx: 502)
    check ranges[2] == (startIdx: 502, endIdx: 753)
    check ranges[3] == (startIdx: 753, endIdx: 1003)  # Clamped to particleCount

  test "handles single worker":
    let ranges = divideParticles(16000, 1)
    check ranges.len == 1
    check ranges[0] == (startIdx: 0, endIdx: 16000)

  test "handles more workers than particles":
    let ranges = divideParticles(3, 8)
    check ranges.len == 8
    # perWorker = ceil(3/8) = 1
    check ranges[0] == (startIdx: 0, endIdx: 1)
    check ranges[1] == (startIdx: 1, endIdx: 2)
    check ranges[2] == (startIdx: 2, endIdx: 3)
    # Remaining workers get empty ranges
    for i in 3 ..< 8:
      check ranges[i].startIdx >= ranges[i].endIdx  # Empty range

  test "all particles are covered exactly once":
    for particleCount in [100, 1000, 16000, 64000]:
      for workerCount in [1, 2, 4, 8, 16]:
        let ranges = divideParticles(particleCount, workerCount)

        # Count total particles across all ranges
        var totalCovered = 0
        for r in ranges:
          if r.endIdx > r.startIdx:
            totalCovered += r.endIdx - r.startIdx

        check totalCovered == particleCount

# ==============================================================================
# BUFFER SIZE TESTS
# ==============================================================================

suite "Sync Protocol Buffer Size":
  test "total buffer size for 16 workers":
    # 1 (frame) + 1 (count) + 16*2 (pairs) + 16 (config) + 16 (done) = 66
    check totalSyncBufferSize(16) == 66

  test "total buffer size for 1 worker":
    # 1 + 1 + 1*2 + 16 + 1 = 21
    check totalSyncBufferSize(1) == 21

  test "buffer size fits in 256 Int32s":
    # We allocate 256 Int32s in the sync buffer
    check totalSyncBufferSize(MAX_WORKERS) <= 256

# ==============================================================================
# MATCH WORKERS.NIM / WORKER.NIM TESTS
# ==============================================================================

suite "Sync Protocol Matches Implementation":
  # These tests verify the protocol matches what workers.nim and worker.nim expect

  test "matches workers.nim line 170 calculation":
    # From workers.nim: let configOffset = 2 + workerCount * 2
    for w in 1 .. 16:
      check configOffset(w) == 2 + w * 2

  test "matches workers.nim line 187 calculation":
    # From workers.nim: let doneOffset = configOffset + 16
    for w in 1 .. 16:
      let co = 2 + w * 2
      check doneOffset(w) == co + 16

  test "matches worker.nim line 125 calculation":
    # From worker.nim: let configOffset = 2 + workerCount * 2
    for w in 1 .. 16:
      check configOffset(w) == 2 + w * 2

  test "matches worker.nim line 151 calculation":
    # From worker.nim: let doneOffset = configOffset + 16 + myIndex
    for w in 1 .. 16:
      for i in 0 ..< w:
        let co = 2 + w * 2
        check doneFlagIndex(w, i) == co + 16 + i
