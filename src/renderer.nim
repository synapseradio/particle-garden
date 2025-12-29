# ==============================================================================
# EMERGENT GARDEN - WEBGL RENDERER MODULE
# ==============================================================================
#
# WebGL rendering for Goober Garden particle simulation.
#
# This module handles all GPU-based rendering:
# - Particle point sprites with density-based sizing
# - Optional trail effect via fade overlay
# - VBO management with pre-allocation to avoid GPU memory leaks
#
# The render loop reads particle data from the active buffer set and
# uploads interleaved position/color/density data to the GPU each frame.
#
# Compile with: nim js -o:web/renderer.js src/renderer.nim
#
# ==============================================================================

from std/jsffi import JsObject
import bindings/js_interop
import bindings/webgl
import bindings/typed_arrays
import config

import buffers

# ==============================================================================
# SECTION 1: TYPE DEFINITIONS
# ==============================================================================

type
  RenderTiming* = ref object of JsObject
    packTimeMs* {.exportc.}: float
    uploadTimeMs* {.exportc.}: float

# ==============================================================================
# SECTION 2: SHADER SOURCES
# ==============================================================================

# Particle vertex shader - transforms positions to clip space with density-based point size
const VERT = """
    attribute vec2 a_pos;
    attribute vec3 a_col;
    attribute float a_den;
    uniform vec2 u_res;
    uniform float u_size;
    varying vec3 v_col;
    void main() {
        vec2 clip = (a_pos / u_res) * 2.0 - 1.0;
        gl_Position = vec4(clip * vec2(1, -1), 0, 1);
        float size_mod = max(1.0, 4.0 - a_den * 0.5);
        gl_PointSize = u_size * size_mod;
        v_col = a_col;
    }
"""

# Particle fragment shader - circular point sprites with soft edges
const FRAG = """
    precision mediump float;
    varying vec3 v_col;
    void main() {
        vec2 c = gl_PointCoord - 0.5;
        float d2 = dot(c, c);
        if (d2 > 0.25) discard;
        float a = 1.0 - smoothstep(0.1, 0.25, d2);
        gl_FragColor = vec4(v_col, a);
    }
"""

# Fade overlay vertex shader - fullscreen quad
const FADE_VERT = "attribute vec2 a_pos; void main() { gl_Position = vec4(a_pos, 0, 1); }"

# Fade overlay fragment shader - semi-transparent dark overlay for trail effect
const FADE_FRAG = "precision mediump float; uniform float u_alpha; void main() { gl_FragColor = vec4(0.04, 0.04, 0.06, u_alpha); }"

# ==============================================================================
# SECTION 3: GL STATE
# ==============================================================================

var canvas* {.exportc.}: HTMLCanvasElement
var gl* {.exportc.}: WebGLRenderingContext

var prog: WebGLProgram
var fadeProg: WebGLProgram
var vbo: WebGLBuffer
var quadVbo: WebGLBuffer
var uRes: WebGLUniformLocation
var uSize: WebGLUniformLocation
var aPos: int
var aCol: int
var aDen: int
var fadeAPos: int
var fadeAlpha: WebGLUniformLocation

# ==============================================================================
# SECTION 4: WEBGL CONTEXT OPTIONS HELPER
# ==============================================================================

proc createWebGLOptions(): JsObject {.importjs: "({alpha: false, antialias: false, preserveDrawingBuffer: true})".}
  ## Create WebGL context options object

# ==============================================================================
# SECTION 5: INITIALIZATION
# ==============================================================================

# Forward declaration
proc resize*() {.exportc.}

proc initGL*(): bool {.exportc.} =
  ## Initialize WebGL context, compile shaders, and set up buffers.
  ## Returns true if initialization succeeded, false otherwise.

  canvas = getElementById("canvas")

  # Get WebGL context with options for trails support
  let opts = createWebGLOptions()
  gl = canvas.getContext("webgl", opts)

  if gl.isNil:
    jsAlert("WebGL required")
    return false

  # Compile shader helper
  proc compile(shaderType: int, src: cstring): WebGLShader =
    let s = gl.createShader(shaderType)
    gl.shaderSource(s, src)
    gl.compileShader(s)
    if gl.getShaderParameter(s, gl.glCompileStatus()):
      return s
    else:
      return nil

  # Link program helper
  proc link(vs: WebGLShader, fs: WebGLShader): WebGLProgram =
    let p = gl.createProgram()
    gl.attachShader(p, vs)
    gl.attachShader(p, fs)
    gl.linkProgram(p)
    if gl.getProgramParameter(p, gl.glLinkStatus()):
      return p
    else:
      return nil

  prog = link(
    compile(gl.glVertexShader(), VERT),
    compile(gl.glFragmentShader(), FRAG)
  )
  fadeProg = link(
    compile(gl.glVertexShader(), FADE_VERT),
    compile(gl.glFragmentShader(), FADE_FRAG)
  )

  aPos = gl.getAttribLocation(prog, "a_pos")
  aCol = gl.getAttribLocation(prog, "a_col")
  aDen = gl.getAttribLocation(prog, "a_den")
  uRes = gl.getUniformLocation(prog, "u_res")
  uSize = gl.getUniformLocation(prog, "u_size")
  fadeAPos = gl.getAttribLocation(fadeProg, "a_pos")
  fadeAlpha = gl.getUniformLocation(fadeProg, "u_alpha")

  vbo = gl.createBuffer()
  # Pre-allocate VBO to max size once - avoids per-frame GPU allocation leak
  gl.bindBuffer(gl.glArrayBuffer(), vbo)
  # MAX_PARTICLES * 6 floats per particle * 4 bytes per float
  gl.bufferData(gl.glArrayBuffer(), MAX_PARTICLES * 6 * 4, gl.glDynamicDraw())

  quadVbo = gl.createBuffer()
  gl.bindBuffer(gl.glArrayBuffer(), quadVbo)
  let quadData = newFloat32Array(@[float32(-1), -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1])
  gl.bufferData(gl.glArrayBuffer(), quadData, gl.glStaticDraw())

  gl.enable(gl.glBlend())
  gl.blendFunc(gl.glSrcAlpha(), gl.glOneMinusSrcAlpha())

  resize()
  return true

# ==============================================================================
# SECTION 6: RESIZE HANDLING
# ==============================================================================

proc resize*() {.exportc.} =
  ## Update canvas and viewport to match window dimensions.
  canvas.width = innerWidth
  canvas.height = innerHeight
  gl.viewport(0, 0, canvas.width, canvas.height)

# ==============================================================================
# SECTION 7: RENDER
# ==============================================================================

proc render*(particleCount: int): RenderTiming {.exportc.} =
  ## Render all particles to the canvas.
  ## Returns timing breakdown with packTimeMs and uploadTimeMs.

  # Handle trails or clear
  if CONFIG.trails:
    gl.useProgram(fadeProg)
    gl.uniform1f(fadeAlpha, 1.0 - CONFIG.trailAlpha)
    gl.bindBuffer(gl.glArrayBuffer(), quadVbo)
    gl.enableVertexAttribArray(fadeAPos)
    gl.vertexAttribPointer(fadeAPos, 2, gl.glFloat(), false, 0, 0)
    gl.drawArrays(gl.glTriangles(), 0, 6)
  else:
    gl.clearColor(0.04, 0.04, 0.06, 1.0)
    gl.clear(gl.glColorBufferBit())

  let n = particleCount

  # Phase 1: Pack vertex data (CPU-side)
  let tPack0 = performanceNow()

  # Select active buffer based on current parity
  let pxActive = if activeParity == 1: pxB else: pxA
  let pyActive = if activeParity == 1: pyB else: pyA
  let sActive = if activeParity == 1: speciesB else: speciesA
  let denActive = if activeParity == 1: denB else: denA

  # Pack interleaved vertex data: position (2), color (3), density (1) = 6 floats per particle
  for i in 0 ..< n:
    let i6 = i * 6
    let c = sActive[i] * 3
    renderData[i6] = pxActive[i]
    renderData[i6 + 1] = pyActive[i]
    renderData[i6 + 2] = COLORS[c]
    renderData[i6 + 3] = COLORS[c + 1]
    renderData[i6 + 4] = COLORS[c + 2]
    renderData[i6 + 5] = denActive[i]

  let packTimeMs = performanceNow() - tPack0

  # Phase 2: Upload to GPU and draw
  let tUpload0 = performanceNow()

  gl.useProgram(prog)
  gl.uniform2f(uRes, float(canvas.width), float(canvas.height))
  gl.uniform1f(uSize, float(CONFIG.particleSize + 1))

  gl.bindBuffer(gl.glArrayBuffer(), vbo)
  # Update existing buffer - bufferSubData reuses GPU memory, bufferData allocates new
  let uploadSlice = renderData.subarray(0, n * 6)
  gl.bufferSubData(gl.glArrayBuffer(), 0, uploadSlice)

  gl.enableVertexAttribArray(aPos)
  gl.vertexAttribPointer(aPos, 2, gl.glFloat(), false, 24, 0)
  gl.enableVertexAttribArray(aCol)
  gl.vertexAttribPointer(aCol, 3, gl.glFloat(), false, 24, 8)
  gl.enableVertexAttribArray(aDen)
  gl.vertexAttribPointer(aDen, 1, gl.glFloat(), false, 24, 20)

  gl.drawArrays(gl.glPoints(), 0, n)

  let uploadTimeMs = performanceNow() - tUpload0

  # Return timing result
  result = RenderTiming()
  result.packTimeMs = packTimeMs
  result.uploadTimeMs = uploadTimeMs

