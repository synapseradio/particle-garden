## MODIFIED Requirements

### Requirement: Up-gradient feedback stays bounded

Tropism SHALL be bounded asymmetrically, granting less authority to up-gradient motion than to
down-gradient motion, because agents that climb their own deposited gradient form a positive
feedback loop that admits chemotactic collapse while agents that descend one do not. The shipped
bounds are `TROPISM_MIN = -1.0` and `TROPISM_MAX = 0.5` (`src/config_ranges.nim:431-435`), and a
static assertion holds `TROPISM_MAX < -TROPISM_MIN` so a later tidying to a symmetric range fails
the build instead of shipping unmeasured up-gradient authority (`src/config_ranges.nim:721`).

The bound SHALL hold at every step of the pattern-scale band (`field-scale`, "The pattern-scale band
is measured before its constants are set"), with scent at strength 1. A smaller pattern steepens the
inhibitor gradient per field cell, so the collapse bracket is measured at each step, not carried over
from scale 1. At each step, the tropism × deposit bracket where collapse begins SHALL be recorded
beside `TROPISM_MAX`, and its lower deposit edge SHALL sit above `RD_DEPOSIT_MAX`.

Native tests warrant the bound by bracketing where collapse lives (`tests/test_field_core.nim`,
suite "Chemotactic Collapse Bound", `:970-1171`), run at every pattern-scale step. Inside the deposit
range the sliders offer, no tropism collapses the field — a thousandfold the bound stays finite and
bounded. Divergence needs a deposit bracketed above `RD_DEPOSIT_MAX`, at (10x, 15x] at scale 1 with
the field-force scale at its pre-contract maximum, in a bracket recorded per step. A
frozen-population control at that same deposit proves the divergence chemotactic and not the
deposit's own flooding. The deposit ceiling therefore carries more of the protection than the tropism
bound does, and the tests state that scope.

#### Scenario: Maximum tropism stays stable
- **WHEN** every species sits at the positive tropism bound with the maximum deposit, scent at
  strength 1, at any step of the pattern-scale band
- **THEN** the field does not diverge and no unbounded concentration forms

#### Scenario: Collapse stays outside the reachable world
- **WHEN** the deposit ceiling, the tropism bound, the scent gain or the pattern-scale floor changes
- **THEN** the bracketing tests still pass at every step: every reachable deposit-tropism combination
  stays finite and bounded, and the frozen-population control still separates chemotaxis from the
  deposit's own flooding

#### Scenario: A smaller pattern moves the bracket into reach
- **WHEN** at some step of the band the collapse bracket's lower deposit edge falls to or below
  `RD_DEPOSIT_MAX`
- **THEN** the suite fails naming the step, and the remedy is the band's floor, the scent gain or the
  deposit ceiling, measured again, never a skipped step
