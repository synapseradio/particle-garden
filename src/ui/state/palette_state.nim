# ==============================================================================
# PALETTE STATE - Palette editor typed state (Pure)
# ==============================================================================
#
# The palette editor's live tunables: which scheme is active, plus the
# saturation/lightness knobs generatePalette accepts. ui.nim holds one of
# these at module scope and regenerates the six species colors into
# config.COLORS whenever it changes.
#
# Deliberately NOT part of SimConfig or the preset store: the editor's
# scheme/saturation/lightness are local UI state, not a saved-preset field
# (see preset.nim's serialization contract, which this module does not
# touch).
#
# Pure module: no FFI, no DOM. Compiles on both the native (nimble test) and
# JS backends.
#
# ==============================================================================

import ../../palette
import ../../memory_layout

export palette, memory_layout

# ==============================================================================
# SECTION 1: STATE
# ==============================================================================

type
  PaletteEditorState* = object
    ## The palette editor's current scheme and HSL knobs.
    scheme*: PaletteScheme
    saturation*: float
    lightness*: float

func initPaletteEditorState*(): PaletteEditorState =
  ## Defaults: psOpenColor (the app-wide default scheme; see config.nim's
  ## COLORS initialization) plus palette.nim's DEFAULT_SATURATION/
  ## DEFAULT_LIGHTNESS.
  PaletteEditorState(
    scheme: psOpenColor,
    saturation: DEFAULT_SATURATION,
    lightness: DEFAULT_LIGHTNESS
  )

# ==============================================================================
# SECTION 2: SCHEME ID SERIALIZATION
# ==============================================================================
#
# Stable string ids for DOM button wiring and any future serialization
# surface, mirroring sim_registry's simKindId/parseSimKind pattern: ids are
# addressed by string, never by enum ordinal, so reordering PaletteScheme
# cannot change what an id means.

func schemeId*(scheme: PaletteScheme): string =
  ## The stable id for a palette scheme.
  case scheme
  of psOpenColor: "open-color"
  of psGolden: "golden"
  of psSpectrum: "spectrum"
  of psWarm: "warm"
  of psCool: "cool"

func parsePaletteScheme*(id: string): PaletteScheme =
  ## Inverse of schemeId. Raises ValueError for an unknown id — callers
  ## dealing with untrusted input catch and fall back explicitly.
  for scheme in PaletteScheme:
    if schemeId(scheme) == id:
      return scheme
  raise newException(ValueError, "unknown palette scheme id: " & id)

# ==============================================================================
# SECTION 3: PALETTE DERIVATION
# ==============================================================================

func paletteFor*(state: PaletteEditorState): seq[RgbColor] =
  ## The six species colors this state currently describes.
  generatePalette(MAX_SPECIES, state.scheme, state.saturation, state.lightness)

func flatPaletteFor*(state: PaletteEditorState): seq[float] =
  ## paletteFor, interleaved for writing into config.COLORS.
  flattenPalette(paletteFor(state))
