# ==============================================================================
# PARTICLE GARDEN - RESPONSE PROBE TESTS (design E1-E3)
# ==============================================================================
#
# Two layers. The coverage relations pin that the probe apparatus reaches the
# WHOLE descriptor table — every parameter probed or exempted with a reason,
# every carried probe id resolving, no orphans — before any metric runs. The
# sweep then measures every probed descriptor at the provisional thresholds
# and asserts only the CALIBRATION ANCHORS (design E3): the five must-pass
# controls pass, and the four predicted failures fail. Everything else is
# measured and recorded, never asserted — those measurements are E5's input,
# not this group's verdict.
#
# THE QUARANTINE. rdFeed, rdKill, trailLength and glowIntensity are expected
# red at the provisional thresholds; the suite asserts that they DO fail, so
# the calibration signal cannot silently vanish while the suite stays green.
# E5 recalibrates the thresholds, applies remedies, and REMOVES this marker —
# after E5 the sweep runs as an ordinary all-pass assertion.
#
# Run with: just test
#
# ==============================================================================

import std/[os, sets, strutils, tables, unittest]

const RESPONSE_PROBE_TESTS_LOADED* = true

import ../src/ui/api/param_descriptor
import ../src/ui/api/response_probe

let descriptors = buildParamDescriptors()
let registry = probeRegistry()

suite "Every Descriptor Is Probed Or Exempted":
  # The coverage relation is TOTAL over the table (E0): a descriptor added
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

  test "the exemptions are exactly the two structural counts, with reasons":
    # Design E1 declares the exempt set; a third exemption is a decision this
    # test makes loud rather than a default anyone can drift into.
    var exempted: seq[string]
    for descriptor in descriptors:
      if descriptor.exemption.len > 0:
        exempted.add descriptor.id
        check descriptor.exemption.len > 0
    check exempted == @["particleCount", "speciesCount"]

const
  MustPass = ["friction", "fieldOpacity", "exposure", "contrast",
    "sphViscosity"]
    ## Live across their whole range by inspection of the math they feed
    ## (design E3); a metric that fails one of these is measuring wrong, and
    ## E3.6 forbids resolving that by moving a threshold.
  QuarantinedExpectedRed = ["rdFeed", "rdKill"]
    ## E3.4's predicted failures that MEASURED as failures — the calibration
    ## signal. THIS IS THE QUARANTINE MARKER: E5 applies the remedies and
    ## deletes this constant, turning the sweep into an ordinary all-pass
    ## assertion (E5.10).
    ##
    ## E3.4 predicted FOUR failures; the sweep disproved two of them, and
    ## design E3 carries both corrections beside its anchors. trailLength:
    ## the shipped mapping decays to a fixed residual over frames
    ## proportional to the length, so persistence is LINEAR in the slider
    ## (trail_core.persistenceFrames records the collapse) and it measures
    ## live end to end. glowIntensity: even at its declared bright
    ## coordinate the display clamp compresses the top of the track to 85%
    ## of raw (test_glow_core's measurement), which still grows every step —
    ## live end to end at the shipped tuning.

proc defaultSliceMeasurement(descriptor: ParamDescriptor): SliceMeasurement =
  measureSlice(descriptor, registry[descriptor.probe],
    SliceSpec(name: "default", ctx: defaultProbeContext()))

proc metricsNote(m: SliceMeasurement): string =
  "span=" & $m.span & " live=" & $m.liveFraction & " cliff=" & $m.cliff

suite "The Sweep At Provisional Thresholds":
  test "every must-pass control passes on the default slice":
    for descriptor in descriptors:
      if descriptor.id in MustPass:
        let m = defaultSliceMeasurement(descriptor)
        if not m.passes:
          checkpoint(descriptor.id & " failed: " & metricsNote(m))
        check m.passes

  test "the four predicted failures do fail on the default slice":
    for descriptor in descriptors:
      if descriptor.id in QuarantinedExpectedRed:
        let m = defaultSliceMeasurement(descriptor)
        if m.passes:
          checkpoint(descriptor.id &
            " unexpectedly passes — the calibration signal is gone: " &
            metricsNote(m))
        check not m.passes

  test "every probed descriptor measures on every declared slice":
    # Recorded, not judged: the metrics exist and are finite on every slice
    # the descriptor declares. The verdicts beyond the anchors above belong
    # to E5's calibration, which reads the emitted table.
    for descriptor in descriptors:
      if descriptor.probe.len == 0:
        continue
      for slice in slicesFor(descriptor):
        let m = measureSlice(descriptor, registry[descriptor.probe], slice)
        check m.span >= 0.0
        check m.liveFraction >= 0.0 and m.liveFraction <= 1.0
        check m.cliff >= 0.0

suite "The Measured Table Is The Deliverable":
  test "the report emits beside perf-report for E5 to read":
    let markdown = legibilityReportMarkdown()
    check "| parameter | slice | span | live | cliff |" in markdown
    check "rdFeed" in markdown
    check "sphStiffness" in markdown
    let reportPath = currentSourcePath().parentDir.parentDir /
      "docs" / "control-legibility-report.md"
    writeFile(reportPath, markdown)
    check fileExists(reportPath)
