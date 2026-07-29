# ==============================================================================
# PARTICLE GARDEN - RESPONSE PROBE TESTS
# ==============================================================================
#
# Two layers. The coverage relations pin that the probe apparatus reaches the
# WHOLE descriptor table — every parameter probed or exempted with a reason,
# every carried probe id resolving, no orphans — before any metric runs. The
# sweep then measures every probed descriptor on every declared slice at the
# calibrated thresholds and asserts the whole table passes, except the
# feed/kill joint group, which no whole-track metric can serve: its members
# are judged by the group's own guarantees — entry evidence (their live
# boundaries move with the partner across the regime-point slices by more
# than the neighbourhood) and point liveness (each member measures live
# within JointPointNeighbourhood of every named point, on that point's
# slice).
#
# Every assertion and the emitted report read ONE shared measuring pass
# (allSliceMeasurements), so the stepped field probes integrate their grids
# once however many claims are checked against them.
#
# Run with: just test
#
# ==============================================================================

import std/[os, sets, strutils, tables, unittest]

const RESPONSE_PROBE_TESTS_LOADED* = true

import ../src/config_ranges
import ../src/ui/api/param_descriptor
import ../src/ui/api/response_probe
import ../src/ui/api/slider_curve

let descriptors = buildParamDescriptors()
let registry = probeRegistry()
let measured = allSliceMeasurements()

proc descriptorById(id: string): ParamDescriptor =
  for descriptor in descriptors:
    if descriptor.id == id:
      return descriptor
  raiseAssert "no descriptor with id " & id

suite "Every Descriptor Is Probed Or Exempted":
  # The coverage relation is TOTAL over the table: a descriptor added
  # without a probe fails here before any metric could quietly skip it.

  test "every descriptor is either probed or exempted":
    for descriptor in descriptors:
      if descriptor.probe.len == 0 and descriptor.exemption.len == 0:
        checkpoint("descriptor " & descriptor.id &
          " carries neither a probe nor an exemption")
      check descriptor.probe.len > 0 or descriptor.exemption.len > 0

  test "no descriptor is both probed and exempted":
    for descriptor in descriptors:
      check not (descriptor.probe.len > 0 and descriptor.exemption.len > 0)

  test "every carried probe id resolves to a registered function":
    for descriptor in descriptors:
      if descriptor.probe.len > 0:
        if descriptor.probe notin registry:
          checkpoint(descriptor.id & " names unregistered probe \"" &
            descriptor.probe & "\"")
        check descriptor.probe in registry

  test "every registered probe is carried by some descriptor":
    var carried = initHashSet[string]()
    for descriptor in descriptors:
      if descriptor.probe.len > 0:
        carried.incl descriptor.probe
    for probeId in registry.keys:
      if probeId notin carried:
        checkpoint("registry entry \"" & probeId &
          "\" is carried by no descriptor")
      check probeId in carried

  test "the exemptions are exactly the three declared ones, with reasons":
    # The exempt set is a declaration; a fourth exemption is a decision this
    # test makes loud rather than a default anyone can drift into. Two
    # structural counts, and the substep count whose written reason names
    # where its ceiling consequence stays measured (sphStiffness's
    # deriving-box corner slices).
    var exempted: seq[string]
    for descriptor in descriptors:
      if descriptor.exemption.len > 0:
        exempted.add descriptor.id
        check descriptor.exemption.len > 0
    check exempted == @["particleCount", "speciesCount", "sphSubsteps"]

const
  MustPass = ["friction", "fieldOpacity", "exposure", "contrast",
    "sphViscosity"]
    ## Live across their whole range by inspection of the math they feed; a
    ## metric that fails one of these is measuring wrong, and the remedy is
    ## the probe or the metric, never the threshold.

proc metricsNote(m: SliceMeasurement): string =
  "slice=" & m.sliceName & " span=" & $m.span & " live=" & $m.liveFraction &
    " cliff=" & $m.cliff

suite "The Sweep At Calibrated Thresholds":
  test "every measured slice carries finite metrics in range":
    for id, rows in measured:
      for m in rows:
        checkpoint(id & ": " & metricsNote(m))
        check m.span >= 0.0
        check m.liveFraction >= 0.0 and m.liveFraction <= 1.0
        check m.cliff >= 0.0

  test "every must-pass anchor passes":
    for id in MustPass:
      for m in measured[id]:
        if not m.passes:
          checkpoint(id & " failed: " & metricsNote(m))
        check m.passes

  test "every probed descriptor outside the joint group passes every slice":
    for id, rows in measured:
      if id in JointMembers:
        continue
      for m in rows:
        if not m.passes:
          checkpoint(id & " failed: " & metricsNote(m))
        check m.passes

suite "The Feed/Kill Joint Group Holds Its Guarantees":
  # Beyond the two guarantees asserted here, the group adopts guarantees
  # already pinned elsewhere, referenced rather than copied: joint
  # reachability by the notch-lattice assertions
  # (tests/test_param_descriptor.nim), attractor fidelity by `The Regime
  # Deposit Floor Preserves The Regime` (tests/test_field_core.nim), and
  # continuity of travel between points by the climate tour's continuity
  # and easing tests (tests/test_climate_core.nim).

  test "each member's regime slices align with the regime table":
    for member in JointMembers:
      let rows = measured[member]
      check rows.len == RD_REGIMES.len
      for i in 0 ..< RD_REGIMES.len:
        check rows[i].sliceName == RD_REGIMES[i].id

  test "entry evidence: the live region moves with the partner":
    # A partner-independent curve could serve a member whose live region
    # sat still across the named-point slices. Entry is the measured
    # boundary shift: some live boundary moves across the slices by more
    # than the neighbourhood the group's own liveness bar uses. Hull
    # non-overlap is NOT the instrument — hulls can overlap while the
    # region inside them shifts with the partner. A failure here is not a
    # bug to patch around: it says the group must be dissolved and the
    # pair given ordinary curves.
    for member in JointMembers:
      var minStart = 1.0
      var maxStart = 0.0
      var minEnd = 1.0
      var maxEnd = 0.0
      for m in measured[member]:
        checkpoint(member & " on " & m.sliceName & ": live " &
          $m.liveStart & "-" & $m.liveEnd)
        minStart = min(minStart, m.liveStart)
        maxStart = max(maxStart, m.liveStart)
        minEnd = min(minEnd, m.liveEnd)
        maxEnd = max(maxEnd, m.liveEnd)
      let boundaryShift = max(maxStart - minStart, maxEnd - minEnd)
      checkpoint(member & " boundary shift " & $boundaryShift)
      check boundaryShift > JointPointNeighbourhood

  test "each member is live around every named point on that point's slice":
    # The group's own liveness bar: the regime coordinates are the positions
    # the notches send the user to, so the member must respond there — on
    # the slice holding its partner at that same regime.
    for member in JointMembers:
      let descriptor = descriptorById(member)
      let rows = measured[member]
      for i in 0 ..< RD_REGIMES.len:
        let regime = RD_REGIMES[i]
        let pointValue =
          if member == "rdFeed": regime.feed else: regime.kill
        let pointPosition = positionOf(descriptor, pointValue)
        let m = rows[i]
        if m.liveEnd <= m.liveStart:
          checkpoint(member & " has no live interval on slice " &
            m.sliceName)
        check m.liveEnd > m.liveStart
        if pointPosition < m.liveStart - JointPointNeighbourhood or
            pointPosition > m.liveEnd + JointPointNeighbourhood:
          checkpoint(member & " point " & regime.id & " at position " &
            $pointPosition & " sits outside live " & $m.liveStart & "-" &
            $m.liveEnd & " widened by " & $JointPointNeighbourhood)
        check pointPosition >= m.liveStart - JointPointNeighbourhood
        check pointPosition <= m.liveEnd + JointPointNeighbourhood

const PreCalibrationTable = """
## Before calibration

The same sweep at the provisional thresholds — SPAN_MIN=0.05,
LIVE_FRACTION_MIN=0.6, CLIFF_MAX=0.25, RESPONSE_EPSILON=0.0001 — before the
probe repairs, the substep exemption, and the feed/kill joint group. Kept
beside the calibrated table because every remedy answers to a FAIL row here:
five probe observables were repaired to read their control's shipped
consequence (maxVelocity, attractionPeak, paletteLightness,
sphRadiusFraction, sphRestDensity), sphSubsteps left the probe set with its
written exemption, and rdFeed/rdKill moved to the joint group's
regime-point slices.

| parameter | slice | span | live | cliff | dead run | verdict |
|---|---|---|---|---|---|---|
| interactionRadius | default | 0.9333 | 1.000 | 0.097 | none | pass |
| forceStrength | default | 1.0000 | 1.000 | 0.020 | none | pass |
| crowdingStrength | default | 1.0000 | 1.000 | 0.030 | none | pass |
| friction | default | 1.0000 | 1.000 | 0.020 | none | pass |
| timeScale | default | 0.9800 | 1.000 | 0.020 | none | pass |
| ruleTemperature | default | 0.8333 | 1.000 | 0.020 | none | pass |
| maxVelocity | default | 1.0000 | 0.500 | 0.040 | 0.50-1.00 | FAIL |
| particleSize | zoomFloor | 0.7778 | 1.000 | 0.143 | none | pass |
| particleSize | zoomCeiling | 0.7778 | 1.000 | 0.143 | none | pass |
| trailLength | default | 1.0000 | 1.000 | 0.005 | none | pass |
| glowIntensity | default | 1.0000 | 1.000 | 0.064 | none | pass |
| velocityGlowScale | default | 0.9540 | 1.000 | 0.039 | none | pass |
| glowRadiusScale | default | 0.9961 | 1.000 | 0.025 | none | pass |
| glowFalloff | default | 0.8072 | 1.000 | 0.041 | none | pass |
| glowWarmth | default | 1.0000 | 1.000 | 0.010 | none | pass |
| bloomIntensity | default | 0.4714 | 1.000 | 0.007 | none | pass |
| exposure | default | 0.8860 | 1.000 | 0.011 | none | pass |
| saturation | default | 1.0000 | 1.000 | 0.005 | none | pass |
| contrast | default | 0.7500 | 1.000 | 0.007 | none | pass |
| temperature | default | 0.6938 | 1.000 | 0.005 | none | pass |
| repulsionEnd | default | 1.4311 | 1.000 | 0.024 | none | pass |
| attractionPeak | default | 0.1625 | 1.000 | 0.572 | none | FAIL |
| expRepulsionAlpha | default | 0.9698 | 1.000 | 0.014 | none | pass |
| expAttractionBeta | default | 0.9982 | 0.875 | 0.024 | 0.87-1.00 | pass |
| paletteSaturation | default | 1.0000 | 1.000 | 0.010 | none | pass |
| paletteLightness | default | 0.0000 | 0.000 | 0.000 | none | FAIL |
| fluidStrength | default | 1.0000 | 1.000 | 0.010 | none | pass |
| sphRadiusFraction | default | 0.1307 | 0.978 | 1.251 | 0.00-0.02 | FAIL |
| sphRestDensity | default | 1.0000 | 0.102 | 0.395 | 0.10-1.00 | FAIL |
| sphStiffness | default | 0.9667 | 1.000 | 0.004 | none | pass |
| sphStiffness | fraction=0.1 substeps=1 | 0.3333 | 1.000 | 0.200 | none | pass |
| sphStiffness | fraction=0.1 substeps=3 | 0.7778 | 1.000 | 0.029 | none | pass |
| sphStiffness | fraction=1.0 substeps=1 | 0.9333 | 1.000 | 0.007 | none | pass |
| sphStiffness | fraction=1.0 substeps=3 | 0.9750 | 1.000 | 0.004 | none | pass |
| sphViscosity | default | 0.6667 | 1.000 | 0.010 | none | pass |
| sphSubsteps | default | 0.6250 | 1.000 | 0.600 | none | FAIL |
| rdFeed | default | 0.1305 | 0.873 | 1.364 | 0.00-0.13 | FAIL |
| rdKill | default | 1.0000 | 0.514 | 0.151 | 0.74-1.00 | FAIL |
| rdDeposit | default | 0.2105 | 1.000 | 0.013 | none | pass |
| rdFieldForce | default | 1.0000 | 1.000 | 0.004 | none | pass |
| climateSpeed | default | 0.9750 | 1.000 | 0.005 | none | pass |
| fieldOpacity | default | 1.0000 | 1.000 | 0.010 | none | pass |
| secretion | default | 2.0000 | 1.000 | 0.005 | none | pass |
| tropism | default | 1.5000 | 1.000 | 0.007 | none | pass |
| cameraZoom | default | 0.8750 | 1.000 | 0.004 | none | pass |
"""

suite "The Measured Table Is The Deliverable":
  test "the report emits with the pre-calibration table frozen beside it":
    let markdown = legibilityReportMarkdown(measured)
    check ("| parameter | slice | span | live | cliff | dead run | " &
      "live interval | verdict |") in markdown
    check "rdFeed" in markdown
    check "coral" in markdown
    check "sphStiffness" in markdown
    let reportPath = currentSourcePath().parentDir.parentDir /
      "docs" / "control-legibility-report.md"
    writeFile(reportPath, markdown & "\n" & PreCalibrationTable)
    check fileExists(reportPath)
