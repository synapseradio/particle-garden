# ==============================================================================
# PARTICLE GARDEN - CONTROL MATRIX
# ==============================================================================
#
# The row model, validation, arbitration, takeover, excursions, the mapping
# document and learn. Pure: no FFI, no DOM, no family module, compiled on both
# backends and exercised natively by tests/test_control_matrix.nim.
#
# Past delivery this module cannot tell one source family from another. A
# family registers its sources under its own id prefix and delivers values and
# events; everything downstream is decided here, and the boundary
# (src/web_api.nim) applies the outcome one flush returns through the paths it
# already owns. Which sources ship, and the default mapping over them, live in
# src/ui/input/shipped_mapping.nim, because those name MIDI.
#
# ==============================================================================

import std/[tables, sets, math, json, strutils]

import ../api/param_descriptor
import ../api/param_fields
import ../api/slider_curve
import ../state/render_state
import ../state/simulation_state
import ../../climate_core
import ../../config_ranges

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------

const REGIME_ACTION_PREFIX* = "regime:"
  ## What a regime-selecting action id carries ahead of the regime's own id, so
  ## one namespace holds both the six regimes and the actions that take no
  ## payload.

const
  DEPTH_MIN* = -1.0
  DEPTH_MAX* = 1.0
    ## A depth is a signed fraction of the track: full travel in either
    ## direction and nothing wider, since the sum clamps to the track anyway.
  GRID_MIN* = 1
    ## A grid with no column or no row lays no cell, so it would index nothing.
  BASE_NOTE_MIN* = 0
  BASE_NOTE_MAX* = 127
    ## MIDI note numbers are seven bits, so nothing outside this can arrive.

const MS_PER_SECOND = 1000.0
  ## Attack and release travel on a row in milliseconds, the unit a musician
  ## reads; every time constant is honoured in seconds against the frame delta.

const ENVELOPE_FLOOR* = 1e-4
  ## An enveloped value under this magnitude snaps to zero, so an exponential
  ## release reaches the base instead of approaching it forever. Under a
  ## seventh of the finest position step any targetable parameter serves
  ## (expRepulsionAlpha, 7.1e-4; the count parameters are refused as targets),
  ## so the snap moves no lattice value; the suite sweeps the table for it.

# ------------------------------------------------------------------------------
# Sources
# ------------------------------------------------------------------------------

type
  SourceKind* = enum
    skContinuous  ## a latest value in [0, 1], coalesced between flushes
    skEvent       ## a queued (magnitude, ordinal), drained in arrival order

  SourceDeclaration* = object
    id*, label*: string
    kind*: SourceKind

  SourceEvent* = object
    sourceId*: string
    magnitude*: float  ## [0, 1]
    ordinal*: int      ## where the event sits in the source's own space

# ------------------------------------------------------------------------------
# Rows
# ------------------------------------------------------------------------------

type
  RowKind* = enum rkModulate, rkWrite, rkFire, rkTouch, rkTour

  ControlRow* = object
    ## One mapping. Row-kind legality is typed: modulating an action names a
    ## field no branch carries and fails the compile.
    sourceId*: string          ## resolved against the source declarations
    case kind*: RowKind
    of rkModulate:
      modParamId*: string
      depth*: float            ## [-1, 1]; 0 is ordinary and inert
      attackMs*: float         ## constant while the source rises; 0 passes raw
      releaseMs*: float        ## constant while the source falls; 0 passes raw
    of rkWrite:
      writeParamId*: string
      jump*: bool              ## false = soft takeover
      rank*: int               ## collision order among writers on one id
    of rkFire:
      actionId*: string
      ordinal*: int            ## which event of the source's space fires it
    of rkTouch:
      gridCols*, gridRows*: int
      baseNote*: int
    of rkTour:
      tourId*: string
      runningParamId*: string  ## the declared gate id gating the advance
      tourSpeedParamId*: string
      # Nim forbids one field name in two branches, so the tour's precedence
      # field is its own name and arbitration reads whichever the kind carries.
      tourRank*: int

func `==`*(left, right: ControlRow): bool =
  ## Nim generates no equality for a case object (its field iterator refuses
  ## one), and "the same mapping row for row" is what a round-trip means, so
  ## the comparison is written out per branch.
  if left.kind != right.kind or left.sourceId != right.sourceId:
    return false
  case left.kind
  of rkModulate:
    left.modParamId == right.modParamId and left.depth == right.depth and
      left.attackMs == right.attackMs and left.releaseMs == right.releaseMs
  of rkWrite:
    left.writeParamId == right.writeParamId and left.jump == right.jump and
      left.rank == right.rank
  of rkFire:
    left.actionId == right.actionId and left.ordinal == right.ordinal
  of rkTouch:
    left.gridCols == right.gridCols and left.gridRows == right.gridRows and
      left.baseNote == right.baseNote
  of rkTour:
    left.tourId == right.tourId and
      left.runningParamId == right.runningParamId and
      left.tourSpeedParamId == right.tourSpeedParamId and
      left.tourRank == right.tourRank

type
  TourPointFn* = proc(phase: float): seq[float] {.noSideEffect, nimcall.}

  TourDeclaration* = object
    ## A tour is a phase-to-point function plus the parameter ids its axes
    ## write. How the point is computed is the registrar's business.
    tourId*: string
    axisParamIds*: seq[string]
    gateId*: string
    pointAt*: TourPointFn
    maxStepPerAxis*: seq[float]

# ------------------------------------------------------------------------------
# Actions
# ------------------------------------------------------------------------------

type
  ActionKind* = enum
    akRegime
    akRandomizeMatrix
    akResetParticles
    akReseedField
    akToggleTrails
    akToggleBloom
    akToggleClimateDrift
    akToggleForceWeather
    akToggleCameraDrift

const ACTIONS_WITHOUT_PAYLOAD: array[8, tuple[id: string, kind: ActionKind]] = [
  ("randomizeMatrix", akRandomizeMatrix),
  ("resetParticles", akResetParticles),
  ("reseedField", akReseedField),
  ("toggleTrails", akToggleTrails),
  ("toggleBloom", akToggleBloom),
  ("toggleClimateDrift", akToggleClimateDrift),
  ("toggleForceWeather", akToggleForceWeather),
  ("toggleCameraDrift", akToggleCameraDrift),
]
  ## Every action whose whole content is which path it runs. The regimes carry
  ## a payload and resolve through the prefix above instead.

func actionOf*(id: string):
    tuple[found: bool, kind: ActionKind, payload: string] =
  ## The action an id names. `found` is the discriminator: an unresolved id
  ## carries no kind worth reading, and the boundary's dispatch is a case over
  ## the enum, so a kind without an arm fails the compile.
  if id.startsWith(REGIME_ACTION_PREFIX):
    let regimeId = id[REGIME_ACTION_PREFIX.len .. ^1]
    for regime in RD_REGIMES:
      if regime.id == regimeId:
        return (true, akRegime, regimeId)
    return (false, akRegime, "")
  for action in ACTIONS_WITHOUT_PAYLOAD:
    if action.id == id:
      return (true, action.kind, "")
  (false, akRegime, "")

func actionIds(): seq[string] =
  for regime in RD_REGIMES:
    result.add REGIME_ACTION_PREFIX & regime.id
  for action in ACTIONS_WITHOUT_PAYLOAD:
    result.add action.id

const ACTION_IDS* = actionIds()
  ## Every id `actionOf` resolves, for the editor's list. Derived from the
  ## regime table and the array above, so neither can grow without it.

# ------------------------------------------------------------------------------
# State
# ------------------------------------------------------------------------------

type
  RowRuntime = object
    ## What one row carries from frame to frame, keyed by the row's index.
    envelope: float
    phase: float
    engaged: bool
    hasPrevious: bool
    previousSourceTravel: float
    lastWrittenTravel: float

  SourceFamily = object
    id: string
    declarations: seq[SourceDeclaration]

  LearnArming = object
    armed: bool
    slot: ControlRow
    capture: HashSet[string]
      ## Sources that had already spoken when the arming was made, and which
      ## therefore never bind it.

  MatrixState* = object
    rows*: seq[ControlRow]
    families: seq[SourceFamily]
      ## A seq rather than a table: "registration order" is what the editor's
      ## source list reads, and a seq says so without depending on any table's
      ## iteration.
    tours: Table[string, TourDeclaration]
    values: Table[string, float]
    delivered: seq[string]
      ## Continuous sources that have delivered since the last flush, in
      ## first-delivery order.
    deliveredSet: HashSet[string]
    drainedLastFlush: HashSet[string]
    events: seq[SourceEvent]
    runtime: seq[RowRuntime]
    wasLive: bool
      ## An excursion was live at the previous flush, so this frame still
      ## re-mirrors and the return to base lands.
    learn: LearnArming

func initMatrixState*(): MatrixState =
  MatrixState(
    tours: initTable[string, TourDeclaration](),
    values: initTable[string, float](),
    deliveredSet: initHashSet[string](),
    drainedLastFlush: initHashSet[string](),
    learn: LearnArming(capture: initHashSet[string]()))

func alignRuntime(state: var MatrixState) =
  ## Per-row state is keyed by index, so a mapping whose length moved outside
  ## the edit path (the boundary assigning `rows` at startup) starts clean.
  if state.runtime.len != state.rows.len:
    state.runtime = newSeq[RowRuntime](state.rows.len)

func resetRuntime(state: var MatrixState) =
  state.runtime = newSeq[RowRuntime](state.rows.len)

# ------------------------------------------------------------------------------
# Registration
# ------------------------------------------------------------------------------

func registerSourceFamily*(state: var MatrixState; familyId: string;
    declarations: openArray[SourceDeclaration]) =
  ## Replaces this family's declared set whole, which is how a family declares
  ## lazily and grows as its devices arrive, and leaves every other family's
  ## alone. A declaration outside the family's own prefix is dropped: one
  ## family cannot mint another's ids.
  let prefix = familyId & ":"
  var kept: seq[SourceDeclaration]
  for declaration in declarations:
    if declaration.id.startsWith(prefix):
      kept.add declaration
  for index in 0 ..< state.families.len:
    if state.families[index].id == familyId:
      state.families[index].declarations = kept
      return
  state.families.add SourceFamily(id: familyId, declarations: kept)

func registerTour*(state: var MatrixState; tour: TourDeclaration) =
  ## Replaces by tour id, on the same terms a family's registration replaces.
  state.tours[tour.tourId] = tour

func declaredSources*(state: MatrixState): seq[SourceDeclaration] =
  ## Every declaration, in registration order across families.
  for family in state.families:
    for declaration in family.declarations:
      result.add declaration

func declarationOf*(state: MatrixState; sourceId: string):
    tuple[found: bool, decl: SourceDeclaration] =
  for family in state.families:
    for declaration in family.declarations:
      if declaration.id == sourceId:
        return (true, declaration)
  (false, SourceDeclaration())

func rowTarget*(row: ControlRow): string =
  ## What this row acts on, for a refusal message or the editor's one-line
  ## summary. The kinds keep their own field names; this is the one place that
  ## reads them as one thing.
  case row.kind
  of rkModulate: row.modParamId
  of rkWrite: row.writeParamId
  of rkFire: row.actionId
  of rkTouch: "a " & $row.gridCols & " by " & $row.gridRows & " grid"
  of rkTour: row.tourId

func neededKind*(kind: RowKind): SourceKind =
  ## Which kind of source a row of this kind reads. A tour rides the clock,
  ## which is continuous, so the gesture kinds are the two that need events.
  case kind
  of rkModulate, rkWrite, rkTour: skContinuous
  of rkFire, rkTouch: skEvent

func rowResolved*(state: MatrixState; row: ControlRow): bool =
  ## Whether the row's source is declared with a kind its row kind reads. A
  ## row that is not resolved keeps its place and sits inert at the flush.
  let declaration = declarationOf(state, row.sourceId)
  if not declaration.found:
    return false
  # A Modulate row reads either kind: a continuous source drives its envelope,
  # an event source makes it an impulse.
  row.kind == rkModulate or declaration.decl.kind == neededKind(row.kind)

func tourAxisIds*(state: MatrixState; tourId: string): seq[string] =
  ## The parameters a registered tour writes; empty for an id no registration
  ## covers, which is what a Tour row on such an id can report.
  if tourId in state.tours: state.tours[tourId].axisParamIds else: @[]

func writtenParamIds*(state: MatrixState): seq[string] =
  ## Every parameter the mapping writes through the store: each Write target
  ## and each axis of each Tour row's registered tour, in row order without
  ## repeats. A Modulate row moves the world without moving the stored value,
  ## so it is not here.
  for row in state.rows:
    case row.kind
    of rkWrite:
      if row.writeParamId notin result:
        result.add row.writeParamId
    of rkTour:
      for axisId in tourAxisIds(state, row.tourId):
        if axisId notin result:
          result.add axisId
    of rkModulate, rkFire, rkTouch:
      discard

# ------------------------------------------------------------------------------
# Validation
# ------------------------------------------------------------------------------

func targetRefusal(descriptors: Table[string, ParamDescriptor];
    paramId: string; storeConfined: bool): string =
  ## Why this parameter cannot be a row's target, or "" when it can.
  if paramId notin descriptors:
    return "no descriptor serves the parameter id " & paramId
  let descriptor = descriptors[paramId]
  if descriptor.reinitOnCommit:
    # particleCount and speciesCount: their effect rides the slider-release
    # side effect, which a matrix write never produces.
    return paramId & " applies on release, and a matrix write produces no " &
      "release side effect"
  if descriptor.store == psSpeciesChemistry:
    # setParam does not route these; the panel writes those cells by
    # reference, so no row can reach them.
    return paramId & " is written per species by reference, not through setParam"
  if storeConfined and descriptor.store notin {psSimulation, psRender}:
    return "a modulate row reaches the simulation and render stores alone, " &
      "and " & paramId & " is written through " & $descriptor.store
  ""

func validateTarget(state: MatrixState;
    descriptors: Table[string, ParamDescriptor];
    row: ControlRow): tuple[ok: bool, reason: string] =
  ## The relations that hold whatever is declared: they are about the row's
  ## target, not about any source. Decode checks exactly these, so a row whose
  ## source is absent this session survives while a row naming nothing served
  ## drops.
  case row.kind
  of rkModulate:
    let refusal = targetRefusal(descriptors, row.modParamId, true)
    if refusal.len > 0: return (false, refusal)
  of rkWrite:
    let refusal = targetRefusal(descriptors, row.writeParamId, false)
    if refusal.len > 0: return (false, refusal)
  of rkFire:
    if not actionOf(row.actionId).found:
      return (false, "no action resolves the id " & row.actionId)
  of rkTouch:
    if row.gridCols < GRID_MIN or row.gridRows < GRID_MIN:
      return (false, "a pad grid needs at least one column and one row")
    if row.baseNote < BASE_NOTE_MIN or row.baseNote > BASE_NOTE_MAX:
      return (false, "base note " & $row.baseNote & " sits outside [" &
        $BASE_NOTE_MIN & ", " & $BASE_NOTE_MAX & "]")
  of rkTour:
    if row.tourId notin state.tours:
      return (false, "no tour is registered under the id " & row.tourId)
    let tour = state.tours[row.tourId]
    if row.runningParamId != tour.gateId:
      return (false, "the tour " & row.tourId & " gates on " & tour.gateId &
        ", not on " & row.runningParamId)
    if row.tourSpeedParamId notin descriptors:
      return (false, "no descriptor serves the speed id " &
        row.tourSpeedParamId)
    if descriptors[row.tourSpeedParamId].minValue < 0.0:
      return (false, "the speed descriptor " & row.tourSpeedParamId &
        " reaches negative values, which would run the tour backwards")
  (true, "")

func validateRow*(state: MatrixState;
    descriptors: Table[string, ParamDescriptor];
    row: ControlRow): tuple[ok: bool, reason: string] =
  ## The five relations. The source-kind relation is checked only where the
  ## source is declared and the row is not a Modulate row, which reads either
  ## kind: a declared source of the wrong kind refuses, and an undeclared
  ## source passes and reports unresolved, since a family may declare lazily
  ## and a stored mapping must survive a session without its device.
  result = validateTarget(state, descriptors, row)
  if not result.ok:
    return
  let declaration = declarationOf(state, row.sourceId)
  if row.kind != rkModulate and declaration.found and
      declaration.decl.kind != neededKind(row.kind):
    let needed = neededKind(row.kind)
    return (false, "the source " & row.sourceId & " is declared " &
      $declaration.decl.kind & " where this row kind needs " & $needed)

# ------------------------------------------------------------------------------
# Delivery
# ------------------------------------------------------------------------------

func setSourceValue*(state: var MatrixState; sourceId: string; value: float) =
  ## Latest wins: a sweep between two flushes collapses here, and a value
  ## outside [0, 1] is clamped at this boundary so no consumer sees the raw
  ## number. First-delivery order is recorded as a seq, so which source learn
  ## binds and which rows count as fresh never depend on a table's iteration.
  state.values[sourceId] = clamp(value, 0.0, 1.0)
  if sourceId notin state.deliveredSet:
    state.deliveredSet.incl sourceId
    state.delivered.add sourceId

func withdrawSourceFamily*(state: var MatrixState; familyId: string) =
  ## Zeroes the family's sources so their Modulate envelopes release toward
  ## base; records no delivery, so a Write row on one of them writes nothing
  ## at the next flush. An unknown familyId is a no-op.
  for family in state.families:
    if family.id != familyId:
      continue
    for declaration in family.declarations:
      state.values[declaration.id] = 0.0
    return

func emitSourceEvent*(state: var MatrixState; sourceId: string;
    magnitude: float; ordinal: int) =
  ## Queued in arrival order and drained at the next flush.
  state.events.add SourceEvent(sourceId: sourceId,
    magnitude: clamp(magnitude, 0.0, 1.0), ordinal: ordinal)

func armLearn*(state: var MatrixState; slot: ControlRow) =
  ## Arms learn for a slot: the row minus its binding. The arming captures
  ## every continuous source that has already spoken — what delivered since
  ## the last flush plus what the last flush drained — and no source in that
  ## set binds this arming, so a family delivering every frame, or a control
  ## streaming with no hand on it, never binds by arriving first. No timeout.
  var capture = state.drainedLastFlush
  for sourceId in state.delivered:
    capture.incl sourceId
  state.learn = LearnArming(armed: true, slot: slot, capture: capture)

func cancelLearn*(state: var MatrixState) =
  state.learn = LearnArming(capture: initHashSet[string]())

func learnState*(state: MatrixState):
    tuple[armed: bool, slot: ControlRow] =
  (state.learn.armed, state.learn.slot)

func latestValue*(state: MatrixState; sourceId: string): float =
  ## The staged value behind a continuous source. Zero before first delivery,
  ## which is what a row reads then.
  state.values.getOrDefault(sourceId, 0.0)

func stagedEvents*(state: MatrixState): seq[SourceEvent] =
  ## The queue as it stands, in arrival order.
  state.events

# ------------------------------------------------------------------------------
# Mapping edits
# ------------------------------------------------------------------------------

func setRows*(state: var MatrixState; rows: seq[ControlRow]) =
  ## Whole-mapping replace, for a decoded document. Per-row state is keyed by
  ## index, so it starts clean.
  state.rows = rows
  resetRuntime(state)

func setRow*(state: var MatrixState; index: int; row: ControlRow;
    descriptors: Table[string, ParamDescriptor]):
    tuple[ok: bool, reason: string] =
  if index < 0 or index >= state.rows.len:
    return (false, "no row sits at index " & $index)
  let verdict = validateRow(state, descriptors, row)
  if not verdict.ok:
    return verdict
  state.rows[index] = row
  resetRuntime(state)
  (true, "")

func addRow*(state: var MatrixState; row: ControlRow;
    descriptors: Table[string, ParamDescriptor]):
    tuple[ok: bool, reason: string] =
  let verdict = validateRow(state, descriptors, row)
  if not verdict.ok:
    return verdict
  state.rows.add row
  resetRuntime(state)
  (true, "")

func removeRow*(state: var MatrixState; index: int):
    tuple[ok: bool, reason: string] =
  if index < 0 or index >= state.rows.len:
    return (false, "no row sits at index " & $index)
  state.rows.delete(index)
  resetRuntime(state)
  (true, "")

func setRank*(state: var MatrixState; index: int; rank: int;
    descriptors: Table[string, ParamDescriptor]):
    tuple[ok: bool, reason: string] =
  ## Rank orders writers against each other, so only the two writing kinds
  ## carry one.
  if index < 0 or index >= state.rows.len:
    return (false, "no row sits at index " & $index)
  var row = state.rows[index]
  case row.kind
  of rkWrite: row.rank = rank
  of rkTour: row.tourRank = rank
  else:
    return (false, "a " & $row.kind & " row orders against no other writer")
  setRow(state, index, row, descriptors)

# ------------------------------------------------------------------------------
# The mapping document
# ------------------------------------------------------------------------------
#
# Versioned in preset.nim's image, and for the same reason: std/json's `[]` and
# `hasKey` guard their JObject invariant with `assert`, which `-d:release`
# strips, so nothing here touches an untrusted node except through `field` and
# `getElems`, whose kind checks are a real `if`.

const MATRIX_SCHEMA_VERSION* = 1
  ## The schema version this build writes and fully understands. `parseDocument`
  ## refuses any document claiming a higher one, since this build cannot know
  ## what a newer version's fields mean. A bump adds a branch to `migrate`.

const MAPPING_STORAGE_KEY* = "pg.mapping"
  ## The localStorage key the panel keeps the one user mapping under. Distinct
  ## from every `pg.presets.` key, since a mapping configures the instrument
  ## while a preset is a point in the world's parameter space.

const ROW_KIND_IDS: array[RowKind, string] = [
  rkModulate: "modulate",
  rkWrite: "write",
  rkFire: "fire",
  rkTouch: "touch",
  rkTour: "tour",
]
  ## What each kind serializes as. Written here rather than derived from the
  ## enum's spelling, so renaming a member cannot silently rename a stored
  ## document's contents. Every other key in a row is the field's own name.

type
  MappingErrorKind* = enum
    mekNone               ## decoded cleanly (rows may still have been dropped)
    mekInvalidJson        ## not parseable JSON, or a root that is not an object
    mekNewerSchemaVersion ## a version this build cannot interpret

  MappingLoadResult* = object
    ok*: bool
    rows*: seq[ControlRow]
    error*: string
    errorKind*: MappingErrorKind

proc field(node: JsonNode; key: string): JsonNode =
  ## Nil-safe field lookup on `getOrDefault`, for the reason the section header
  ## states.
  node.getOrDefault(key)

proc stringField(node: JsonNode; key: string): tuple[ok: bool, value: string] =
  let child = field(node, key)
  if child == nil or child.kind != JString: (false, "")
  else: (true, child.getStr(""))

proc numberField(node: JsonNode; key: string): tuple[ok: bool, value: float] =
  ## A JSON document may carry a whole number for a float field, so both
  ## numeric kinds answer.
  let child = field(node, key)
  if child == nil: return (false, 0.0)
  case child.kind
  of JInt: (true, child.getInt(0).float)
  of JFloat: (true, child.getFloat(0.0))
  else: (false, 0.0)

proc intField(node: JsonNode; key: string): tuple[ok: bool, value: int] =
  let child = field(node, key)
  if child == nil or child.kind != JInt: (false, 0)
  else: (true, child.getInt(0))

proc boolField(node: JsonNode; key: string): tuple[ok: bool, value: bool] =
  let child = field(node, key)
  if child == nil or child.kind != JBool: (false, false)
  else: (true, child.getBool(false))

proc rowToJson(row: ControlRow): JsonNode =
  result = newJObject()
  result["kind"] = %ROW_KIND_IDS[row.kind]
  result["source"] = %row.sourceId
  case row.kind
  of rkModulate:
    result["modParamId"] = %row.modParamId
    result["depth"] = %row.depth
    result["attackMs"] = %row.attackMs
    result["releaseMs"] = %row.releaseMs
  of rkWrite:
    result["writeParamId"] = %row.writeParamId
    result["jump"] = %row.jump
    result["rank"] = %row.rank
  of rkFire:
    result["actionId"] = %row.actionId
    result["ordinal"] = %row.ordinal
  of rkTouch:
    result["gridCols"] = %row.gridCols
    result["gridRows"] = %row.gridRows
    result["baseNote"] = %row.baseNote
  of rkTour:
    result["tourId"] = %row.tourId
    result["runningParamId"] = %row.runningParamId
    result["tourSpeedParamId"] = %row.tourSpeedParamId
    result["tourRank"] = %row.tourRank

proc toDocumentText*(rows: seq[ControlRow]): string =
  ## The one user mapping as its document text, for storage and for handing to
  ## another player.
  var document = newJObject()
  document["schemaVersion"] = %MATRIX_SCHEMA_VERSION
  var rowArray = newJArray()
  for row in rows:
    rowArray.add rowToJson(row)
  document["rows"] = rowArray
  $document

proc rowFromJson*(node: JsonNode): tuple[ok: bool, row: ControlRow] =
  ## Validate-first: a row missing a field its kind needs, or carrying one of
  ## the wrong JSON kind, is malformed and drops. Every field a range bounds
  ## clamps into it instead, so a document written by a build with wider
  ## bounds loses the excess rather than the row. Shape only: the target
  ## relations are `validateRow`'s, so an edit can answer their reason.
  if node == nil or node.kind != JObject:
    return (false, ControlRow())
  let kindId = stringField(node, "kind")
  let source = stringField(node, "source")
  if not kindId.ok or not source.ok:
    return (false, ControlRow())
  var kind: RowKind
  var known = false
  for candidate in RowKind:
    if ROW_KIND_IDS[candidate] == kindId.value:
      kind = candidate
      known = true
      break
  if not known:
    return (false, ControlRow())
  case kind
  of rkModulate:
    let paramId = stringField(node, "modParamId")
    let depth = numberField(node, "depth")
    let attack = numberField(node, "attackMs")
    let release = numberField(node, "releaseMs")
    if not (paramId.ok and depth.ok and attack.ok and release.ok):
      return (false, ControlRow())
    (true, ControlRow(sourceId: source.value, kind: rkModulate,
      modParamId: paramId.value,
      depth: clamp(depth.value, DEPTH_MIN, DEPTH_MAX),
      attackMs: max(attack.value, 0.0),
      releaseMs: max(release.value, 0.0)))
  of rkWrite:
    let paramId = stringField(node, "writeParamId")
    let jump = boolField(node, "jump")
    let rank = intField(node, "rank")
    if not (paramId.ok and jump.ok and rank.ok):
      return (false, ControlRow())
    (true, ControlRow(sourceId: source.value, kind: rkWrite,
      writeParamId: paramId.value, jump: jump.value, rank: rank.value))
  of rkFire:
    let actionId = stringField(node, "actionId")
    let ordinal = intField(node, "ordinal")
    if not (actionId.ok and ordinal.ok):
      return (false, ControlRow())
    (true, ControlRow(sourceId: source.value, kind: rkFire,
      actionId: actionId.value, ordinal: max(ordinal.value, 0)))
  of rkTouch:
    let cols = intField(node, "gridCols")
    let rows = intField(node, "gridRows")
    let baseNote = intField(node, "baseNote")
    if not (cols.ok and rows.ok and baseNote.ok):
      return (false, ControlRow())
    (true, ControlRow(sourceId: source.value, kind: rkTouch,
      gridCols: max(cols.value, GRID_MIN), gridRows: max(rows.value, GRID_MIN),
      baseNote: clamp(baseNote.value, BASE_NOTE_MIN, BASE_NOTE_MAX)))
  of rkTour:
    let tourId = stringField(node, "tourId")
    let gateId = stringField(node, "runningParamId")
    let speedId = stringField(node, "tourSpeedParamId")
    let rank = intField(node, "tourRank")
    if not (tourId.ok and gateId.ok and speedId.ok and rank.ok):
      return (false, ControlRow())
    (true, ControlRow(sourceId: source.value, kind: rkTour,
      tourId: tourId.value, runningParamId: gateId.value,
      tourSpeedParamId: speedId.value, tourRank: rank.value))

proc migrate*(node: JsonNode; fromVersion: int): JsonNode =
  ## Upgrades a document node to MATRIX_SCHEMA_VERSION. Steps fall through, so
  ## a document many versions old upgrades in one call. Version 1 is the first
  ## schema, so no branch exists yet and the node passes through.
  discard fromVersion
  node

proc parseDocument*(text: string;
    descriptors: Table[string, ParamDescriptor];
    state: MatrixState): MappingLoadResult =
  ## Validate-first decode. A malformed row drops, an out-of-range field
  ## clamps, and the one whole rejection is a version newer than this build
  ## writes. A row whose source no family declares keeps its place: the device
  ## may arrive later, and a mapping must survive a session without it.
  var node: JsonNode
  try:
    node = parseJson(text)
  except ValueError as err:
    return MappingLoadResult(ok: false, errorKind: mekInvalidJson,
      error: "malformed JSON: " & err.msg)
  if node == nil or node.kind != JObject:
    return MappingLoadResult(ok: false, errorKind: mekInvalidJson,
      error: "the mapping document's root is not a JSON object")
  let versionNode = field(node, "schemaVersion")
  let version =
    if versionNode != nil and versionNode.kind == JInt:
      versionNode.getInt(MATRIX_SCHEMA_VERSION)
    else:
      # A missing or wrong-typed version degrades to "assume current", the
      # defaulting stance every other field here takes.
      MATRIX_SCHEMA_VERSION
  if version > MATRIX_SCHEMA_VERSION:
    return MappingLoadResult(ok: false, errorKind: mekNewerSchemaVersion,
      error: "mapping schemaVersion " & $version &
        " is newer than the supported version " & $MATRIX_SCHEMA_VERSION)
  let working =
    if version < MATRIX_SCHEMA_VERSION: migrate(node, version) else: node
  result = MappingLoadResult(ok: true, errorKind: mekNone)
  for element in field(working, "rows").getElems():
    let decoded = rowFromJson(element)
    if not decoded.ok:
      continue
    # The target relations alone: the source-kind relation would drop a row
    # whose family is simply absent this session.
    if not validateTarget(state, descriptors, decoded.row).ok:
      continue
    result.rows.add decoded.row

proc loadMapping*(storedText: string; default: seq[ControlRow];
    descriptors: Table[string, ParamDescriptor];
    state: MatrixState): seq[ControlRow] =
  ## The stored document's rows, or `default` where storage is empty or its
  ## text is refused. A document that decodes to no rows is a decoded
  ## document: the user emptied their mapping, and the shipped rows stay out.
  if storedText.len == 0:
    return default
  let loaded = parseDocument(storedText, descriptors, state)
  if not loaded.ok:
    return default
  loaded.rows

# ------------------------------------------------------------------------------
# The flush
# ------------------------------------------------------------------------------

type
  ParamContext* = object
    ## One targeted parameter as the boundary reports it this frame.
    descriptor*: ParamDescriptor
    storedValue*: float
    ceiling*: float  ## NaN where the bound is bConstant

  FlushContext* = object
    dtSeconds*: float
      ## The frame's capped wall-clock delta: a tour named in minutes takes
      ## that many minutes whatever the simulation clock is doing.
    params*: Table[string, ParamContext]
    gates*: Table[string, bool]  ## by declared gate id

  ResolvedAction* = object
    kind*: ActionKind
    payload*: string

  Blast* = object
    u*, v*: float     ## view fraction: u right from the left edge, v up from
                      ## the bottom
    strength*: float

  FlushOutcome* = object
    ## What one flush consumed, for the boundary to apply through the paths it
    ## already owns. Nothing here reaches CONFIG from this module.
    writes*: Table[string, float]
    excursions*: Table[string, float]
    effective*: Table[string, float]
    remirror*: bool
    actions*: seq[ResolvedAction]
    hasBlast*: bool
    blast*: Blast
    learned*: bool

func storedContext*(descriptor: ParamDescriptor; sim: SimulationState;
    render: RenderState): ParamContext =
  ## The frame's context for one targeted parameter, based on what the user
  ## stored rather than on the mirror a previous excursion already moved.
  ParamContext(
    descriptor: descriptor,
    storedValue: storedParamValue(sim, render, descriptor).value,
    ceiling:
      if descriptor.bound.kind == bDerived:
        evaluateCeiling(descriptor.bound.ceilingId, ceilingInputs(sim))
      else: NaN)

func isFiniteValue(value: float): bool =
  classify(value) notin {fcNan, fcInf, fcNegInf}

func approach(value, target, seconds, dtSeconds: float): float =
  ## The audio core's shape: the same elapsed span covers the same fraction of
  ## the gap however the frame delta moves.
  target + (value - target) * exp(-dtSeconds / seconds)

func envelopeStep(envelope, target, attackMs, releaseMs,
    dtSeconds: float): float =
  ## One frame of the row's exponential approach toward the latest source
  ## value, asymmetric because a transient wants the rise kept and the fall
  ## lengthened. A zero constant passes the raw value on its side.
  let seconds =
    (if target > envelope: attackMs else: releaseMs) / MS_PER_SECOND
  result = if seconds <= 0.0: target
           else: approach(envelope, target, seconds, dtSeconds)
  if abs(result) < ENVELOPE_FLOOR:
    result = 0.0

func effectiveValue(context: ParamContext; travel: float): float =
  ## The value the handle at `travel` names, under the live ceiling where the
  ## bound is derived. One call, so nothing clamps twice.
  if context.descriptor.bound.kind == bDerived and
      isFiniteValue(context.ceiling):
    valueAt(context.descriptor, travel, boundMax = context.ceiling)
  else:
    valueAt(context.descriptor, travel)

func flushMatrix*(state: var MatrixState; ctx: FlushContext): FlushOutcome =
  ## One frame: drain what delivered, arbitrate, and answer what the boundary
  ## should apply. The frame's only parameter writer.
  alignRuntime(state)
  result = FlushOutcome(
    writes: initTable[string, float](),
    excursions: initTable[string, float](),
    effective: initTable[string, float]())
  let dt = max(ctx.dtSeconds, 0.0)
  var fresh = state.delivered
  var freshSet = state.deliveredSet
  var events = state.events

  # Learn, ahead of every arm: the binding delivery is suppressed from
  # ordinary effect, though its value stays staged for the rows that already
  # read that source.
  if state.learn.armed:
    # Learn arms a Modulate slot for continuous sources alone; an event source
    # binds to a Modulate row by document or addMappingRow only.
    case neededKind(state.learn.slot.kind)
    of skContinuous:
      for position in 0 ..< fresh.len:
        let sourceId = fresh[position]
        if sourceId in state.learn.capture:
          continue
        let declaration = declarationOf(state, sourceId)
        if not declaration.found or declaration.decl.kind != skContinuous:
          continue
        var bound = state.learn.slot
        bound.sourceId = sourceId
        state.rows.add bound
        state.runtime.add RowRuntime()
        fresh.delete(position)
        freshSet.excl sourceId
        result.learned = true
        break
    of skEvent:
      for position in 0 ..< events.len:
        let declaration = declarationOf(state, events[position].sourceId)
        if not declaration.found or declaration.decl.kind != skEvent:
          continue
        var bound = state.learn.slot
        bound.sourceId = events[position].sourceId
        case bound.kind
        of rkFire: bound.ordinal = events[position].ordinal
        of rkTouch: bound.baseNote = events[position].ordinal
        else: discard
        state.rows.add bound
        state.runtime.add RowRuntime()
        events.delete(position)
        result.learned = true
        break
    if result.learned:
      state.learn = LearnArming(capture: initHashSet[string]())

  # Envelopes and the summed travel offset per modulated parameter.
  var offsets = initTable[string, float]()
  var modulated: seq[string]
  for index in 0 ..< state.rows.len:
    let row = state.rows[index]
    if row.kind != rkModulate or not rowResolved(state, row):
      continue
    if declarationOf(state, row.sourceId).decl.kind == skEvent:
      # An impulse: release toward base first, then lift to the loudest event
      # this frame carries, so the hit frame lands the whole magnitude and two
      # hits inside one release never dip. The events stay staged for the Fire
      # and Touch rows on the same source.
      var envelope = envelopeStep(state.runtime[index].envelope, 0.0, 0.0,
        row.releaseMs, dt)
      for event in events:
        if event.sourceId == row.sourceId:
          envelope = max(envelope, event.magnitude)
      state.runtime[index].envelope = envelope
    else:
      state.runtime[index].envelope = envelopeStep(
        state.runtime[index].envelope,
        state.values.getOrDefault(row.sourceId, 0.0), row.attackMs,
        row.releaseMs, dt)
    if row.modParamId notin ctx.params:
      continue
    if row.modParamId notin offsets:
      offsets[row.modParamId] = 0.0
      modulated.add row.modParamId
    offsets[row.modParamId] = offsets[row.modParamId] +
      row.depth * state.runtime[index].envelope

  var travels = initTable[string, float]()
  var live = false
  for paramId in modulated:
    let context = ctx.params[paramId]
    let base = positionOf(context.descriptor, context.storedValue)
    let travel = clamp(base + offsets[paramId], 0.0, 1.0)
    travels[paramId] = travel
    if travel != base:
      live = true
      result.excursions[paramId] = travel - base
  result.remirror = live or state.wasLive
  state.wasLive = live
  if result.remirror:
    # Every modulated parameter, not only the moved ones: the frame after the
    # last excursion is what lands the return to base.
    for paramId in modulated:
      result.effective[paramId] = effectiveValue(ctx.params[paramId],
        travels[paramId])

  # Writers, collected with their rank and settled per parameter.
  var candidates: seq[tuple[rank: int, paramId: string, value: float]]
  for index in 0 ..< state.rows.len:
    let row = state.rows[index]
    if not rowResolved(state, row):
      continue
    case row.kind
    of rkWrite:
      if row.writeParamId notin ctx.params or row.sourceId notin freshSet:
        # A quiet frame carries no ownership: a row whose source did not
        # deliver writes nothing, and does not disengage either.
        continue
      let context = ctx.params[row.writeParamId]
      let sourceTravel = state.values.getOrDefault(row.sourceId, 0.0)
      # No bound argument: the store takes the value travel names and the
      # effect-time clamp keeps the world under the live ceiling.
      let value = valueAt(context.descriptor, sourceTravel)
      let writtenTravel = positionOf(context.descriptor, value)
      let currentTravel = positionOf(context.descriptor, context.storedValue)
      let step = positionStep(context.descriptor)
      var takeover = state.runtime[index]
      if takeover.engaged and
          abs(currentTravel - takeover.lastWrittenTravel) > step:
        # The parameter moved further than this row put it: a slider, a preset
        # or another row, all one mechanism.
        takeover.engaged = false
      if row.jump or abs(sourceTravel - currentTravel) <= step or
          (takeover.hasPrevious and
           (takeover.previousSourceTravel - currentTravel) *
           (sourceTravel - currentTravel) < 0.0):
        takeover.engaged = true
      takeover.previousSourceTravel = sourceTravel
      takeover.hasPrevious = true
      if takeover.engaged:
        candidates.add (row.rank, row.writeParamId, value)
        takeover.lastWrittenTravel = writtenTravel
      state.runtime[index] = takeover
    of rkTour:
      if row.tourId notin state.tours:
        continue
      let tour = state.tours[row.tourId]
      if tour.pointAt.isNil or
          not ctx.gates.getOrDefault(row.runningParamId, false) or
          row.tourSpeedParamId notin ctx.params:
        # A false gate leaves the phase where it is and writes nothing.
        continue
      state.runtime[index].phase = tourAdvance(state.runtime[index].phase,
        ctx.params[row.tourSpeedParamId].storedValue, dt)
      let point = tour.pointAt(state.runtime[index].phase)
      for axis in 0 ..< min(point.len, tour.axisParamIds.len):
        let axisId = tour.axisParamIds[axis]
        if axisId notin ctx.params:
          continue
        # An integer axis takes the rounded point: the tour interpolates in
        # floats and a count of world units is where the two meet.
        let value =
          if ctx.params[axisId].descriptor.kind == pkInt: round(point[axis])
          else: point[axis]
        candidates.add (row.tourRank, axisId, value)
    else:
      discard

  # Ascending rank, so the highest rank lands last and owns the frame. Ties
  # keep row order, which is what a stable sort by rank would give.
  var winners = initTable[string, tuple[rank: int, value: float]]()
  for candidate in candidates:
    if candidate.paramId notin winners or
        candidate.rank >= winners[candidate.paramId].rank:
      winners[candidate.paramId] = (candidate.rank, candidate.value)
  for paramId, winner in winners:
    result.writes[paramId] = winner.value

  # Fires, in the events' arrival order. Regime selections collapse to the
  # last one seen, at that one's position; every other action runs in order.
  var fired: seq[ResolvedAction]
  for event in events:
    for row in state.rows:
      if row.kind != rkFire or row.sourceId != event.sourceId or
          row.ordinal != event.ordinal or not rowResolved(state, row):
        continue
      let action = actionOf(row.actionId)
      if action.found:
        fired.add ResolvedAction(kind: action.kind, payload: action.payload)
  var lastRegime = -1
  for position in 0 ..< fired.len:
    if fired[position].kind == akRegime:
      lastRegime = position
  for position in 0 ..< fired.len:
    if fired[position].kind == akRegime and position != lastRegime:
      continue
    result.actions.add fired[position]

  # Touches. One blast slot, so the later event of a frame wins, the way a
  # second tap replaces the first.
  for event in events:
    for row in state.rows:
      if row.kind != rkTouch or row.sourceId != event.sourceId or
          not rowResolved(state, row):
        continue
      let cell = event.ordinal - row.baseNote
      if cell < 0 or cell >= row.gridCols * row.gridRows:
        continue
      # Row-major from the bottom left, so the cell's own centre is where the
      # blast lands in the visible view.
      let column = cell mod row.gridCols
      let gridRow = cell div row.gridCols
      result.hasBlast = true
      result.blast = Blast(
        u: (column.float + 0.5) / row.gridCols.float,
        v: (gridRow.float + 0.5) / row.gridRows.float,
        strength: event.magnitude)

  # Drain. Latest values persist; what arrived is what the next arming reads
  # as already speaking.
  state.drainedLastFlush = freshSet
  for event in state.events:
    state.drainedLastFlush.incl event.sourceId
  state.delivered = @[]
  state.deliveredSet = initHashSet[string]()
  state.events = @[]
