# ==============================================================================
#
# A dormant control dims, names its missing precondition, and stays movable.
# Each predicate declares the simulation fields, render fields, and pushed
# world signals it reads, and evaluates purely over a table keyed by those
# names — the native suite walks the names against the state records, so a
# rename breaks loudly; what a predicate MEANS is review-enforced. Families
# are shared predicates: members dim together because they name the same one.
# A strength's own control declares none — the slider at zero is the way back.

import std/tables

type
  DormancyPredicate* = object
    id*: string
    line*: string             ## The precondition line the panel shows.
    simFields*: seq[string]   ## SimulationState fields the predicate reads.
    renderFields*: seq[string]  ## RenderState fields it reads.
    statsFields*: seq[string]   ## World signals from the pushed stats stream.
    eval*: proc (values: Table[string, float]): bool {.nimcall.}
      ## True means DORMANT. The table is keyed by exactly the declared
      ## field names; booleans arrive as 0.0 / 1.0.

const StatsWorldSignals* = ["fieldAliveCells"]
  ## World signals the stats push carries; the native suite holds every
  ## predicate's statsFields to this list.

func subcriticalClimate*(feed, kill: float): bool =
  ## F < 4(F+k)^2: no nontrivial fixed point, so a pattern must be nucleated
  ## by deposits — feed and kill alone cannot light the field.
  feed < 4.0 * (feed + kill) * (feed + kill)

proc evalBloomOff(values: Table[string, float]): bool =
  values["bloomEnabled"] == 0.0

proc evalForceOff(values: Table[string, float]): bool =
  values["forceStrength"] == 0.0

proc evalFluidOff(values: Table[string, float]): bool =
  values["fluidStrength"] == 0.0

proc evalDepositOff(values: Table[string, float]): bool =
  values["rdDeposit"] == 0.0

proc evalTropismOff(values: Table[string, float]): bool =
  values["rdFieldForce"] == 0.0

proc evalFieldUnlit(values: Table[string, float]): bool =
  values["fieldAliveCells"] == 0.0

proc evalFieldSubcritical(values: Table[string, float]): bool =
  ## Both terms matter: the named regimes sit subcritical, so the line speaks
  ## only while the field is dark; crossing into F >= 4(F+k)^2 wakes the pair
  ## before anything ignites.
  values["fieldAliveCells"] == 0.0 and
    subcriticalClimate(values["rdFeed"], values["rdKill"])

proc dormancyRegistry*(): Table[string, DormancyPredicate] =
  ## Predicate id -> declaration; descriptors carry the id, and the native
  ## suite asserts each carried id resolves and each named field exists.
  result = {
    "bloomOff": DormancyPredicate(id: "bloomOff",
      line: "Bloom is off",
      renderFields: @["bloomEnabled"], eval: evalBloomOff),
    "forceOff": DormancyPredicate(id: "forceOff",
      line: "the species force is off",
      simFields: @["forceStrength"], eval: evalForceOff),
    "fluidOff": DormancyPredicate(id: "fluidOff",
      line: "the world has no fluid",
      simFields: @["fluidStrength"], eval: evalFluidOff),
    "depositOff": DormancyPredicate(id: "depositOff",
      line: "nothing deposits into the field",
      simFields: @["rdDeposit"], eval: evalDepositOff),
    "tropismOff": DormancyPredicate(id: "tropismOff",
      line: "the field pushes nothing",
      simFields: @["rdFieldForce"], eval: evalTropismOff),
    "fieldUnlit": DormancyPredicate(id: "fieldUnlit",
      line: "the field is dark",
      statsFields: @["fieldAliveCells"], eval: evalFieldUnlit),
    "fieldSubcritical": DormancyPredicate(id: "fieldSubcritical",
      line: "nothing has ignited yet",
      simFields: @["rdFeed", "rdKill"],
      statsFields: @["fieldAliveCells"], eval: evalFieldSubcritical),
  }.toTable
