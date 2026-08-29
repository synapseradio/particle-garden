# in-app-help

## Purpose

The feature documentation and the help panel that displays it: markdown authored once under
`docs/help/`, one file per descriptor group plus an orientation file and a glossary, compiled into
the frontend and served across the `gardenAPI` boundary. It is one capability rather than two
because the repository reader and the panel reader read the same file, and the coverage relations
that keep a control from shipping undocumented run over the same descriptor table the panel draws
its sliders from.

## Requirements

### Requirement: One markdown source serves both the help panel and the feature documentation

Feature documentation SHALL be authored once as markdown under `docs/help/`, one file per descriptor
group plus an orientation file and a glossary, each declaring the group id it documents in front
matter of exactly three lines (`src/ui/api/help_content.nim:14-40`, parsed by `parseHelpEntry` at
`:46-52`). Those files SHALL be `staticRead` into the frontend at Nim-compile time and served
through the boundary (`src/ui/api/help_content.nim:79-87`, served as `help()` at
`src/web_api.nim:1132-1139`); no second copy of the same prose exists anywhere. The gesture and key
reference is the one section not authored as a file: `bindingReferenceBody()` generates it from the
binding table and the `HelpEntries` block splices it in just before the glossary
(`src/ui/api/help_content.nim:64-77, 79-87`).

`staticRead` is the mechanism the render shaders and the UI bundle already use. It costs a few
kilobytes in the frontend bundle and removes a way to fail at runtime: help that fails to load is
worse than help that is slightly larger.

Enforcement: the Nim build, plus the native suite. `HelpEntries` parses every file inside a `const`
block, so a file whose front matter is malformed trips `parseHelpEntry`'s `doAssert` during
compilation (`src/ui/api/help_content.nim:46-52, 79-87`), and `tests/test_help_content.nim:29-38`
holds the directory listing equal to `HelpFileNames` and the entry keys unique. That the panel
displays the served body and holds no fallback prose of its own is **agent-checkable**: launch the
app, open help, and compare a section's rendered text against its file under `docs/help/`;
`HelpPanel` reads `ctrl.api.help()` and parses each entry's body
(`web-ui/src/components/HelpPanel.tsx:75-77`).

#### Scenario: Documentation and help cannot disagree
- **WHEN** a feature's description is edited
- **THEN** both the repository documentation and the in-app help change, because they are one file

#### Scenario: Help is present without the server
- **WHEN** the help panel opens
- **THEN** its content is already in the frontend bundle and no fetch occurs

#### Scenario: A malformed help file stops the build
- **WHEN** a file under `docs/help/` carries front matter that is not exactly `---`,
  `group: <key>`, `---`
- **THEN** `just happen` fails at the Nim compile step on the front-matter assertion

### Requirement: Help coverage is enforced in both directions

Native tests SHALL assert four relations between the help files and the descriptor table
(`tests/test_help_content.nim:41-63`): every descriptor group has a help file; every help file's
declared group id exists as a descriptor group or is one of the reserved keys (`ReservedHelpKeys`,
`src/ui/api/help_content.nim:38-40`, whose three entries `orientation`, `reference` and `glossary`
name no descriptor group by design); every descriptor in a group is named by that group's help file,
recognised from its `` - `id` `` list line (`namedControlIds`, `src/ui/api/help_content.nim:54-62`);
and no help file names an id that is not a descriptor.

These four are what keep the documentation true. A control renamed without its documentation
following turns the suite red at the moment of the rename, not at the moment somebody reads it.

Enforcement: `tests/test_help_content.nim`, under `just test`. Three of the four assertions carry a
`checkpoint` naming the offending descriptor, group, or file; the fourth does not, and its scenario
below says so. `tests/test_help_content.nim:65-76` proves the sweep can fail, exercising a bogus
control line, a malformed front matter, and a well-formed round trip.

#### Scenario: A new control without documentation goes red
- **WHEN** a descriptor is added and its group's help file does not name it
- **THEN** `just test` fails, naming the descriptor and stating that its group's file does not
  name it

#### Scenario: An orphaned help file goes red
- **WHEN** a help file declares a group id that is neither a descriptor group nor a reserved key
- **THEN** `just test` fails at "every declared key is a descriptor group or reserved", which
  reports the assertion's line without naming the file

#### Scenario: A stale id reference goes red
- **WHEN** a help file names a descriptor id that no longer exists
- **THEN** `just test` fails, naming the file's key and the unknown control id

### Requirement: The gesture and key reference is generated from the binding table

Every mouse gesture, wheel gesture, touch gesture, and key binding SHALL be declared once in
`InputBindings` (`src/ui/input/binding_table.nim:34-78`), whose every row the help panel's reference
section renders (`bindingReferenceBody`, `src/ui/api/help_content.nim:64-77`), so a binding cannot
exist without appearing in help. `cameraKeyFor` derives its dispatch from the key rows that name a
camera action (`src/ui/input/key_handler.nim:46-51`). The two key rows carrying no camera action,
`?` and `Esc` (`src/ui/input/binding_table.nim:72-77`), are wired in the panel instead.

This is the single-declaration relation the descriptor table already establishes for parameters, one
table consumed by everything that needs the fact, applied to input.

Enforcement: `tests/test_input.nim:314-344`, under `just test`, holds every row to a non-empty
description naming the offending gesture, holds no two rows to one key, and holds every camera-key
row to dispatching through `cameraKeyFor`, with a non-vacuity count so an emptied table cannot pass.
The mouse, wheel, and touch rows describe listeners `canvas_input` wires, which no test reads:
**agent-checkable**. Launch the app and perform each mouse, wheel, and touch row's gesture on the
canvas, confirming the world answers as that row's description states.

#### Scenario: A new binding documents itself
- **WHEN** a key binding is added to the table
- **THEN** it appears in the help reference without the reference being edited

#### Scenario: An undescribed binding goes red
- **WHEN** a binding table entry carries an empty description
- **THEN** `just test` fails, naming that entry's gesture

### Requirement: The help panel opens on demand and renders a restricted markdown subset

Help SHALL open from a panel control and from the `?` key, and SHALL render headings at levels one
through three, paragraphs, unordered list items, emphasis, strong emphasis, code spans, and links
whose target begins with `#` (`web-ui/src/lib/markdown.ts:18-19, 53-97`). Markup outside that subset
SHALL render as its literal text.

The subset is a bound on the help itself as much as on the renderer: help that needs more than this
is doing something a help panel should not.

Enforcement: the TypeScript suite pins the renderer. `web-ui/test/markdown.test.ts:5-66` covers each
block and inline kind and holds an external link, raw HTML, an image, and a level-four heading to
plain text; `just check` runs it. The open and close wiring is **agent-checkable**: launch the app,
press `?` with focus outside a text field and confirm the panel opens, press `Escape` and confirm it
closes, then click into a matrix cell, type `?`, and confirm the panel stays shut. The handlers are
`web-ui/src/components/Panel.tsx:46-54`, which skips `INPUT` and `TEXTAREA` targets, and
`web-ui/src/components/HelpPanel.tsx:79-83`, which closes on `Escape`.

#### Scenario: Opening help
- **WHEN** the user presses `?` or activates the help control
- **THEN** the help panel opens over the control panel and closes on `Escape`

#### Scenario: Unsupported markup renders as text
- **WHEN** a help file contains markup outside the subset
- **THEN** it renders as its literal text, neither executing nor vanishing

### Requirement: The help content answers what the app is before it answers how to use it

The orientation file SHALL describe what is on screen, what the user can do with a pointer, and one
thing worth trying, before any control is named, and SHALL do so without requiring the reader to
know the underlying mathematics (`docs/help/00-orientation.md:7-24`). Naming a regime, a reaction,
or a force model is permitted; requiring the reader to already know one is not. Where a named regime
carries published coordinates, the glossary cites the source those coordinates come from
(`docs/help/90-glossary.md:22-30`).

Enforcement: **agent-checkable**. No test reads the prose for its order, its reading level, or its
citations; `tests/test_help_content.nim` holds only which ids a file names. The procedure: read
`docs/help/00-orientation.md` from the top and confirm its opening section names what is on screen
and one action to take before any descriptor id or formula appears, then read
`docs/help/90-glossary.md` and confirm each named regime's coordinates carry a cited source.

#### Scenario: A reader with no background
- **WHEN** someone opens help having never seen the application
- **THEN** the first section names what they are looking at and one action to take, with no formula

#### Scenario: Cited coordinates
- **WHEN** the glossary lists a named regime's coordinates
- **THEN** it cites the source those coordinates come from
