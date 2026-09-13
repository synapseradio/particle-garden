# ==============================================================================
# PARAM FIELDS - Reading and writing a state record by descriptor id (Pure)
# ==============================================================================
#
# The field walk that lets a descriptor id and a state field of the same name
# need no third place declaring that they belong together, plus the read of the
# stored value behind a descriptor. Pure: no FFI, no DOM, both backends.
#
# ==============================================================================

import ../state/simulation_state
import ../state/render_state
import ./param_descriptor

func readParamField*[T](record: T; id: string; value: var float): bool =
  ## Read the field of `record` whose NAME is `id` into `value`, and report
  ## whether such a field exists. Integer fields widen, which is what the
  ## panel's one numeric channel carries.
  for name, field in record.fieldPairs:
    when field is int:
      if name == id:
        value = field.float
        return true
    elif field is float:
      if name == id:
        value = field
        return true
  false

func assignParamField*[T](record: var T; id: string; value: float): bool =
  ## Write `value` into the field of `record` whose NAME is `id`, and report
  ## whether such a field exists.
  ##
  ## Integer fields take int(value), and the truncation is already done —
  ## clampParamValue rounds a pkInt parameter through int() before this sees
  ## it, so what arrives for an int field is whole.
  for name, field in record.fieldPairs:
    when field is int:
      if name == id:
        field = int(value)
        return true
    elif field is float:
      if name == id:
        field = value
        return true
  false

func storedParamValue*(sim: SimulationState; render: RenderState;
    descriptor: ParamDescriptor): tuple[found: bool, value: float] =
  ## What the user stored for `descriptor`, from the record its store routes to.
  ## The stores holding no such record answer `found: false`.
  var value = 0.0
  let found =
    case descriptor.store
    of psSimulation: readParamField(sim, descriptor.id, value)
    of psRender: readParamField(render, descriptor.id, value)
    of psPalette, psCamera, psSpeciesChemistry: false
  (found: found, value: if found: value else: 0.0)
