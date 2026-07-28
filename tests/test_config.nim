# ==============================================================================
# PARTICLE GARDEN - CONFIGURATION CONSTRAINT TESTS
# ==============================================================================
#
# Unit tests for configuration limits and invariants.
# Verifies that memory layout constants define valid bounds for CONFIG.
#
# NOTE: The actual ConfigObject lives in config.nim which uses jsffi (JS-only).
# These tests validate the CONSTRAINTS that CONFIG must satisfy, using the
# limits defined in memory_layout.nim which compiles for native.
#
# BEHAVIORAL FOCUS:
#   - Tests verify constraint CONTRACTS that the simulation depends on
#   - Tests validate INVARIANTS for buffer sizes and matrix dimensions
#   - Tests check BOUNDS that prevent buffer overflows
#
# Run with: just test
#
# ==============================================================================

import std/unittest
import ../src/memory_layout
import ../src/field_core

# Export a constant so test_all.nim can reference it
const CONFIG_TESTS_LOADED* = true

# ==============================================================================
# CONFIGURATION LIMIT CONSTANTS
# ==============================================================================
#
# These mirror the default values from config.nim's createConfig().
# We define them here for testing since config.nim is JS-only.
# If defaults change, update both config.nim and these test values.

const
  DEFAULT_PARTICLE_COUNT = 16000
  DEFAULT_SPECIES_COUNT = 4
  DEFAULT_INTERACTION_RADIUS = 50
  DEFAULT_FORCE_STRENGTH = 1.0
  DEFAULT_FRICTION = 0.05
  DEFAULT_TIME_SCALE = 0.5
  DEFAULT_PARTICLE_SIZE = 3
  DEFAULT_TRAIL_ALPHA = 0.96
  DEFAULT_GLOW_INTENSITY = 0.8
  DEFAULT_MAX_VELOCITY = 50.0
  # Glow knobs (S1): mirror config.nim createConfig() exactly.
  DEFAULT_GLOW_RADIUS_SCALE = 3.0
  DEFAULT_GLOW_FALLOFF = 6.0
  DEFAULT_GLOW_WARMTH = 0.4
  # The glow radius glow.wgsl hard-coded before the knobs existed. The default
  # knob values must reproduce it so S1 preserves the default appearance.
  LEGACY_GLOW_BASE_RADIUS = 12.0
  # SPH fluid mode (S7): mirror config.nim createConfig() / initSimulationState().
  DEFAULT_SPH_REST_DENSITY = 1.0
  DEFAULT_SPH_STIFFNESS = 8.0
  DEFAULT_SPH_VISCOSITY = 0.1
  DEFAULT_SPH_SUBSTEPS = 1
  # World dimensions (from config.nim)
  # Reaction-diffusion mode (S8a): mirror config.nim createConfig() /
  # initSimulationState(), which set these from field_core's own constants
  # directly (not literals) — referenced the same way here.
  DEFAULT_RD_FEED = field_core.RD_DEFAULT_FEED
  DEFAULT_RD_KILL = field_core.RD_DEFAULT_KILL
  WORLD_W = 3840.0
  WORLD_H = 2160.0

# ==============================================================================
# CONFIGURATION DEFAULTS CONTRACT
# ==============================================================================

suite "Configuration Defaults Contract":
  test "default particleCount within buffer limits":
    ## CONTRACT: particleCount must fit within allocated particle buffers
    ## WHY: GPU shaders and typed arrays are sized for MAX_PARTICLES
    ## Exceeding this limit causes buffer overflows and undefined behavior
    check DEFAULT_PARTICLE_COUNT > 0
    check DEFAULT_PARTICLE_COUNT <= MAX_PARTICLES

  test "default speciesCount within matrix limits":
    ## CONTRACT: speciesCount must fit within 6x6 attraction matrix
    ## WHY: The attraction matrix is fixed at 36 floats (6 species max)
    ## Going beyond this corrupts memory and produces nonsense physics
    check DEFAULT_SPECIES_COUNT >= 1
    check DEFAULT_SPECIES_COUNT <= MAX_SPECIES

  test "default interactionRadius is reasonable":
    ## CONTRACT: interactionRadius bounds the spatial grid cell size
    ## WHY: Too small (<16) creates excessive grid cells, harming performance
    ##      Too large (>500) defeats spatial optimization entirely
    check DEFAULT_INTERACTION_RADIUS >= 16
    check DEFAULT_INTERACTION_RADIUS <= 500

# ==============================================================================
# CONFIGURATION INVARIANTS
# ==============================================================================

suite "Configuration Invariants":
  test "friction coefficient in valid range":
    ## CONTRACT: friction must be in [0.0, 1.0]
    ## WHY: Friction = 0 means no damping, friction = 1 means instant stop
    ##      Values outside this range cause energy injection or negative velocity
    check DEFAULT_FRICTION >= 0.0
    check DEFAULT_FRICTION <= 1.0

  test "trailAlpha value in valid range":
    ## CONTRACT: trailAlpha must be in [0.0, 1.0]
    ## WHY: This is a blend factor - 0 = instant fade, 1 = permanent trails
    ##      Values outside this range produce visual artifacts
    check DEFAULT_TRAIL_ALPHA >= 0.0
    check DEFAULT_TRAIL_ALPHA <= 1.0

  test "timeScale produces stable simulation":
    ## CONTRACT: timeScale must be in (0.0, 2.0]
    ## WHY: Zero or negative timeScale stops or reverses time incorrectly
    ##      Values > 2.0 destabilize the Euler integration, causing explosions
    check DEFAULT_TIME_SCALE > 0.0
    check DEFAULT_TIME_SCALE <= 2.0

  test "forceStrength is positive":
    ## CONTRACT: forceStrength must be > 0
    ## WHY: Zero force strength makes particles static (boring simulation)
    ##      Negative values invert attraction/repulsion semantics unexpectedly
    check DEFAULT_FORCE_STRENGTH > 0.0

  test "maxVelocity is positive":
    ## CONTRACT: maxVelocity must be > 0
    ## WHY: This caps particle speed to prevent tunneling through boundaries
    ##      Zero or negative values break velocity clamping logic
    check DEFAULT_MAX_VELOCITY > 0.0

  test "glowIntensity is non-negative":
    ## CONTRACT: glowIntensity must be >= 0
    ## WHY: Glow is additive - negative values would subtract light
    ##      Zero disables glow (valid), positive adds bloom effect
    check DEFAULT_GLOW_INTENSITY >= 0.0

  test "particleSize is positive":
    ## CONTRACT: particleSize must be > 0
    ## WHY: Particles must be visible - zero size renders nothing
    check DEFAULT_PARTICLE_SIZE > 0

  test "SPH defaults are physically sensible":
    ## CONTRACT: rest density and stiffness drive the Tait EOS and must be
    ## positive; viscosity is an XSPH blend fraction in [0,1]; substeps is a
    ## positive per-frame loop count.
    check DEFAULT_SPH_REST_DENSITY > 0.0
    check DEFAULT_SPH_STIFFNESS > 0.0
    check DEFAULT_SPH_VISCOSITY >= 0.0
    check DEFAULT_SPH_VISCOSITY <= 1.0
    check DEFAULT_SPH_SUBSTEPS >= 1

  test "reaction-diffusion defaults sit in the Gray-Scott self-replicating-spots regime":
    ## CONTRACT: feed and kill are both positive rates; kill must exceed feed
    ## for the depleting term (feed+kill)*inhibitor to dominate at low
    ## activator (see field_core's direction-property tests) — Gray-Scott's
    ## patterns require this ordering.
    check DEFAULT_RD_FEED > 0.0
    check DEFAULT_RD_KILL > 0.0
    check DEFAULT_RD_KILL > DEFAULT_RD_FEED

  test "glow knob defaults reproduce the legacy hard-coded glow radius":
    ## CONTRACT: baseRadius in glow.wgsl is params.baseSize * params.glowRadiusScale,
    ## where baseSize = particleSize + 1 (webgpu_render.nim). At the defaults this
    ## product must equal the 12.0 the shader hard-coded before S1, so shipping
    ## the knobs does not change the default look.
    check (DEFAULT_PARTICLE_SIZE + 1).float * DEFAULT_GLOW_RADIUS_SCALE ==
      LEGACY_GLOW_BASE_RADIUS

  test "glow knob defaults are physically sensible":
    ## WHY: glowFalloff is an exponent scale (must be > 0 or the gaussian
    ## flattens/inverts); glowWarmth is a [0,1] mix fraction.
    check DEFAULT_GLOW_RADIUS_SCALE > 0.0
    check DEFAULT_GLOW_FALLOFF > 0.0
    check DEFAULT_GLOW_WARMTH >= 0.0
    check DEFAULT_GLOW_WARMTH <= 1.0

# ==============================================================================
# CONFIGURATION RELATIONSHIPS
# ==============================================================================

suite "Configuration Relationships":
  test "speciesCount does not exceed MAX_SPECIES":
    ## DEFENSIVE: Even if CONFIG changes at runtime, this invariant must hold
    ## WHY: The attraction matrix is statically allocated for MAX_SPECIES
    check DEFAULT_SPECIES_COUNT <= MAX_SPECIES

  test "particleCount does not exceed MAX_PARTICLES":
    ## DEFENSIVE: Even if CONFIG changes at runtime, this invariant must hold
    ## WHY: All particle buffers are sized for MAX_PARTICLES maximum
    check DEFAULT_PARTICLE_COUNT <= MAX_PARTICLES

  test "interactionRadius enables meaningful spatial optimization":
    ## CONTRACT: interactionRadius should be much smaller than world dimensions
    ## WHY: If radius approaches world size, spatial grid provides no benefit
    check DEFAULT_INTERACTION_RADIUS.float < WORLD_W / 4
    check DEFAULT_INTERACTION_RADIUS.float < WORLD_H / 4

  test "default timeScale is conservative":
    ## BEHAVIORAL: Default should favor stability over speed
    ## WHY: Users can increase timeScale, but unstable defaults frustrate new users
    check DEFAULT_TIME_SCALE <= 1.0

  test "friction provides observable damping":
    ## BEHAVIORAL: Default friction should be noticeable but not excessive
    ## WHY: Zero friction makes particles chaotic; high friction makes them sluggish
    check DEFAULT_FRICTION > 0.0
    check DEFAULT_FRICTION < 0.5

# ==============================================================================
# LIMIT CONSTANT VALIDATION
# ==============================================================================

suite "Limit Constants Contract":
  test "MAX_SPECIES supports attraction matrix":
    ## CONTRACT: MAX_SPECIES defines the attraction matrix dimension
    ## WHY: The matrix is MAX_SPECIES x MAX_SPECIES = 36 floats
    ## The exact value (6) is pinned by a static assert in memory_layout.nim;
    ## this documents the derived matrix-element count the GPU buffer must hold.
    check MAX_SPECIES * MAX_SPECIES == 36

  test "MAX_PARTICLES provides headroom above default":
    ## BEHAVIORAL: MAX_PARTICLES should be well above default
    ## WHY: Users should be able to increase particle count significantly
    check MAX_PARTICLES >= DEFAULT_PARTICLE_COUNT * 2

  test "MAX_GRID supports fine-grained spatial hashing":
    ## CONTRACT: MAX_GRID defines maximum grid resolution
    ## WHY: Grid cells should be smaller than interaction radius
    ##      256x256 grid allows ~15px cells at 4K resolution
    check MAX_GRID >= 128

# ==============================================================================
# STATIC ASSERTIONS (COMPILE-TIME CHECKS)
# ==============================================================================

# These assertions run at compile time and prevent building invalid configurations
static:
  # INVARIANT: MAX_SPECIES must support at least 2 species for interesting dynamics
  doAssert MAX_SPECIES >= 2, "Need at least 2 species for particle life"

  # INVARIANT: MAX_PARTICLES must be positive
  doAssert MAX_PARTICLES > 0, "MAX_PARTICLES must be positive"

  # INVARIANT: Defaults must fit within limits
  doAssert DEFAULT_PARTICLE_COUNT <= MAX_PARTICLES, "Default particle count exceeds limit"
  doAssert DEFAULT_SPECIES_COUNT <= MAX_SPECIES, "Default species count exceeds limit"
