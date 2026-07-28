## ADDED Requirements

### Requirement: One markdown source serves both the help panel and the feature documentation

Feature documentation SHALL be authored once as markdown under `docs/help/`, one file per descriptor
group plus an orientation file and a glossary, each declaring the group id it documents. Those files
SHALL be `staticRead` into the frontend at Nim-compile time and served through the boundary; no second
copy of the same prose exists anywhere.

`staticRead` is the mechanism the render shaders and the UI bundle already use. It costs a few
kilobytes in the frontend bundle and removes a runtime failure mode: help that fails to load is worse
than help that is slightly larger.

#### Scenario: Documentation and help cannot disagree
- **WHEN** a feature's description is edited
- **THEN** both the repository documentation and the in-app help change, because they are one file

#### Scenario: Help is present without the server
- **WHEN** the help panel opens
- **THEN** its content is already in the frontend bundle and no fetch occurs

### Requirement: Help coverage is enforced in both directions

Native tests SHALL assert four relations between the help files and the descriptor table: every
descriptor group has a help file; every help file's declared group id exists; every descriptor in a
group is named by that group's help file; and no help file names an id that is not a descriptor.

These four are what keep the documentation true. A control renamed without its documentation following
turns the suite red at the moment of the rename rather than at the moment somebody reads it.

#### Scenario: A new control without documentation goes red
- **WHEN** a descriptor is added and its group's help file does not name it
- **THEN** `just test` fails naming the descriptor and the file

#### Scenario: An orphaned help file goes red
- **WHEN** a help file declares a group id no descriptor uses
- **THEN** `just test` fails naming the file

#### Scenario: A stale id reference goes red
- **WHEN** a help file names a descriptor id that no longer exists
- **THEN** `just test` fails naming the file and the id

### Requirement: The gesture and key reference is generated from the binding table

Every mouse gesture, touch gesture, and key binding SHALL be declared once in a pure binding table
consumed both by the input handlers and by the help panel's reference section, so a binding cannot
exist without appearing in help.

This is the relation `controlGroupsFor` already establishes between what a frame dispatches and what
the panel offers, applied to input.

#### Scenario: A new binding documents itself
- **WHEN** a key binding is added to the table
- **THEN** it appears in the help reference without the reference being edited

#### Scenario: An undescribed binding goes red
- **WHEN** a binding table entry carries an empty description
- **THEN** `just test` fails naming the entry

### Requirement: The help panel opens on demand and renders a restricted markdown subset

Help SHALL open from a panel control and from the `?` key, and SHALL render headings, paragraphs,
lists, emphasis, code spans, and internal links — nothing further. The renderer is pinned by the
TypeScript suite.

The subset is a bound on the help itself as much as on the renderer: help that needs more than this is
doing something a help panel should not.

#### Scenario: Opening help
- **WHEN** the user presses `?` or activates the help control
- **THEN** the help panel opens over the control panel and closes on `Escape`

#### Scenario: Unsupported markup renders as text
- **WHEN** a help file contains markup outside the subset
- **THEN** it renders as its literal text rather than executing or vanishing

### Requirement: The help content answers what the app is before it answers how to use it

The orientation file SHALL describe what is on screen, what the user can do with a pointer, and one
thing worth trying, before any control is named — and SHALL do so without requiring the reader to know
the underlying mathematics.

Naming a regime, a reaction, or a force model is permitted; requiring the reader to already know one
is not. Where a named regime carries published coordinates, the source is cited in the glossary rather
than presented as the app's own claim.

#### Scenario: A reader with no background
- **WHEN** someone opens help having never seen the application
- **THEN** the first section names what they are looking at and one action to take, with no formula

#### Scenario: Cited coordinates
- **WHEN** the glossary lists a named regime's coordinates
- **THEN** it cites the source those coordinates come from
