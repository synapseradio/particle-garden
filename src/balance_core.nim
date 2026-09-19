# ==============================================================================
# PARTICLE GARDEN - COUPLING BALANCE (Pure)
# ==============================================================================
#
# The one unit every velocity writer's largest push is stated in, and one unit
# function per writer returning that push in multiples of the unit. Reference
# oracle: each arm mirrors the shader named beside it, which no native test can
# execute.
#
# Imports the oracles and never the module that owns the ranges, so that module
# can import this one and assert against it.
#
# ==============================================================================

import std/math
import physics_core
import sph_core
import field_core
import long_range_core
import body_core

const
  u0* = FRAME_DT_REFERENCE
    ## The velocity one touching neighbour's repulsion core hands a particle at
    ## pair gain 1 over one reference frame. No slider moves it.

type
  UnitFnId* = enum
    ## One member per velocity writer, and one for the deposit, which writes
    ## the field. unitImpulse's exhaustive case makes a new member without an
    ## arm a compile error.
    ufSpecies
    ufFluid
    ufScent
    ufLongRange
    ufBodies
    ufMouse
    ufBlast
    ufDeposit

  UnitConfig* = object
    ## The world a unit function is evaluated in. Each arm reads the fields
    ## its writer answers to; the caller supplies the ranges' values, since
    ## this module cannot import their owner.
    particleCount*: int
    interactionRadius*: float
    worldWidth*, worldHeight*: float
    onsetRatio*: float
      ## x_on: the onset crowd density over the world's mean crowd density.
    attraction*: float
      ## The largest self-attraction matrix entry.
    pairGain*: float
    repulsionEnd*, attractionPeak*: float
    fluidStrength*: float
    viscosity*: float
    maxVelocity*: float
    scentGain*: float
      ## Velocity per reference frame per unit per-cell gradient per world
      ## unit a cell spans.
    tropism*: float
      ## The largest-magnitude tropism.
    patternScale*: float
    longRangeStrength*: float
    longRangeGrid*: tuple[w, h: int]
    bodiesStrength*: float
    liveBodies*: int
    blastStrength*: float
    blastRange*: float
    depositGain*: float
    secretion*: float
      ## The largest-magnitude secretion.

func inUnits(force: float): float =
  ## A force the shaders scale by dt, as the impulse it hands over one
  ## reference frame, in multiples of u0.
  force * FRAME_DT_REFERENCE / u0

func meanCrowdDensity*(cfg: UnitConfig): float =
  ## The crowd density a uniform world holds: N * pi * R^2 / (3 A).
  cfg.particleCount.float * PI * cfg.interactionRadius *
    cfg.interactionRadius / (3.0 * cfg.worldWidth * cfg.worldHeight)

func edgeNeighbourSum*(cfg: UnitConfig): float =
  ## Neighbours in the inward half of the attraction annulus of a particle on
  ## the edge of a clump at the onset density. A crowd density rho counts
  ## 3 rho / (pi R^2) particles per unit area, so the half annulus holds
  ## 1.5 rho (1 - repulsionEnd^2).
  1.5 * cfg.onsetRatio * meanCrowdDensity(cfg) *
    (1.0 - cfg.repulsionEnd * cfg.repulsionEnd)

func referenceColonyRadius*(cfg: UnitConfig): float =
  ## Every particle in one disc at the onset density: sqrt(A / (pi x_on)),
  ## independent of the interaction radius.
  sqrt(cfg.worldWidth * cfg.worldHeight / (PI * cfg.onsetRatio))

func unitImpulse*(id: UnitFnId; cfg: UnitConfig): float =
  ## The writer's largest per-particle impulse at `cfg`, in multiples of u0.
  ## The deposit answers in field concentration per cell per field step.
  case id
  of ufSpecies:
    # forces.wgsl: attraction only, every edge neighbour at the bump's peak
    # and pulling straight inward. The law scales the unit bump by 4.0; that
    # is its shape, and the gain is pairGain alone.
    let atPeak = polynomialForce(cfg.attractionPeak.float32,
      cfg.attraction.float32, cfg.repulsionEnd.float32,
      cfg.attractionPeak.float32, 1.0'f32)
    inUnits(cfg.pairGain * atPeak.float * edgeNeighbourSum(cfg))
  of ufFluid:
    # forces-sph.wgsl, per pair: SPH_FORCE_SCALE times the pair pressure,
    # which reaches the clamp inside the ranges at the lowest rest density,
    # plus the blend at full weight across the widest velocity gap.
    let blend = (cfg.viscosity + SPH_XSPH_EPSILON) * 2.0 * cfg.maxVelocity
    cfg.fluidStrength * (inUnits(SPH_MAX_PRESSURE_ACCEL) + blend / u0)
  of ufScent:
    # field-force.wgsl. The per-cell gradient grows as the pattern shrinks,
    # as 1 / sqrt(patternScale).
    let gradient = RD_INHIBITOR_GRADIENT_PEAK / sqrt(cfg.patternScale)
    let forceScale = cfg.scentGain *
      worldUnitsPerCell(FIELD_W.float, cfg.worldWidth)
    abs(speciesTropismForce(gradient, forceScale, cfg.tropism)) / u0
  of ufLongRange:
    # lr-force.wgsl at today's scale: one interaction radius past the edge
    # of the reference colony.
    let cellArea = lrCellArea(cfg.longRangeGrid.w, cfg.longRangeGrid.h,
      cfg.worldWidth, cfg.worldHeight)
    lrDiscPull(cfg.longRangeStrength, cfg.attraction, cellArea,
      cfg.particleCount.float,
      referenceColonyRadius(cfg) + cfg.interactionRadius) / u0
  of ufBodies:
    # body-force.wgsl: a body's pull peaks at BODY_FORCE_CEILING, its shape,
    # and every live body can stack on one particle.
    cfg.liveBodies.float * BODY_FORCE_CEILING * cfg.bodiesStrength / u0
  of ufMouse:
    # forces.wgsl: 300 at the pointer.
    inUnits(300.0)
  of ufBlast:
    # forces.wgsl: the divisor floor of 10 puts the peak at distance 10.
    inUnits(cfg.blastStrength * 3000.0 * (1.0 - 10.0 / cfg.blastRange))
  of ufDeposit:
    # field-deposit.wgsl, per particle, at the reference field-step count
    # depositFrameScale holds the rate to.
    abs(speciesDeposit(cfg.depositGain, cfg.secretion))
