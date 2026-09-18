## MODIFIED Requirements

### Requirement: Dormancy evaluates where its state already lives

The boundary SHALL evaluate a dormancy predicate over panel-visible state (a strength, a toggle,
another parameter's value) synchronously against the state the panel already mirrors, and SHALL
evaluate a predicate over world state against the pushed stats it already streams. It SHALL add
neither a new subscription nor a per-frame call for either. `dormantParams()` answers id to verdict
in one synchronous call, reading the live simulation and render records field by field and the world
signals from the last stats push (`src/web_api.nim:1208-1249`), and the panel calls it on its own
writes and on each stats push (`web-ui/src/state.ts:65-69, 96, 126, 174, 203`).

The stats stream already runs on a loop-side cadence and the panel already holds every value it
sets; a second push path for either would duplicate a channel that exists.

Enforcement: `tests/test_dormancy.nim:29-40` holds every carried `dormantWhen` to a registered
predicate and every registered predicate to a carrier, and the suite walks each predicate's named
fields against the state records, so a renamed field breaks loudly. What a predicate means, and the
promise of no new subscription and no per-frame call, are **agent-checkable**: launch the app,
toggle bloom off, and confirm the grade controls dim in the same tick as the toggle with no stats
push in between; then, with feed and kill at a named regime, let the field ignite and confirm the
feed and kill controls (`rdFeed`, `rdKill`, dormant under `fieldSubcritical`,
`src/ui/api/dormancy.nim:57-62`) wake on the next stats push and no sooner.

#### Scenario: A config-conditioned control wakes in the same tick
- **WHEN** the user enables bloom
- **THEN** the grade controls leave dormancy in the same tick as the toggle, with no stats push in
  between

#### Scenario: A world-conditioned control follows the stats cadence
- **WHEN** the field ignites while the panel is open, with feed and kill at a named regime
- **THEN** the feed and kill controls leave dormancy on the next stats push

## ADDED Requirements

### Requirement: Every number and catalog the panel displays comes from Nim

The boundary SHALL serve, from Nim, every value the panel renders: the descriptor payload built once
at module-eval time (`src/web_api.nim:286-290`, exposed at `:1131`), the named reaction-diffusion
regime catalog carrying each regime's id, label, coordinates, and deposit floor, with one row per
pattern-scale step where a regime's coordinates drift across the band (`src/web_api.nim:644-654`,
served at `:1200-1202`, the table itself in `config_ranges.nim`), the palette-scheme catalog
(`src/web_api.nim:1260-1267`), the preset storage keys (`src/web_api.nim:1303-1308`), and the
species and matrix-cell colors computed by Nim color math (`src/web_api.nim:1261-1279`). TypeScript
SHALL restate none of them: `web-ui/src/garden-api.ts` declares types and no values.

Enforcement: the palette-scheme labels come from an exhaustive `case` over `PaletteScheme`
(`src/web_api.nim:1252-1258`), so a scheme with no label fails the Nim build. The served scheme list
is written out by hand (`src/web_api.nim:1262`), so a scheme left off it would be absent from the panel
with nothing failing; that is **unenforced**, closed by iterating `PaletteScheme`'s range. The
descriptor table's agreement with the range and default authorities is pinned by
`tests/test_param_descriptor.nim`. That TypeScript restates none of the served numbers is
**agent-checkable**: search `web-ui/src/` for a numeric or string literal standing in for a served
range, default, coordinate, label, or storage key, and confirm each candidate arrives from the
boundary instead.

#### Scenario: A slider is drawn entirely from served numbers
- **WHEN** the panel renders a parameter control
- **THEN** its range, step, precision, default, label, group, and hint all come from `descriptor()`

#### Scenario: An unlabelled palette scheme fails the build
- **WHEN** a palette scheme is added to `PaletteScheme` without a label branch
- **THEN** `just happen` fails at the Nim compile step

## REMOVED Requirements

### Requirement: The boundary serves every number and catalog the panel displays

**Reason**: The colormap catalog and the build assertion that guarded its labels leave with the colormap, because the reaction-diffusion field is no longer drawn. A MODIFIED block cannot drop the requirement's colormap scenario, so the requirement is restated under a new name.

**Migration**: "Every number and catalog the panel displays comes from Nim" carries every other clause unchanged. The regime catalog gains its per-scale rows. The palette-scheme label `case` takes over the build-time guard.
