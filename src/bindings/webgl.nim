# ==============================================================================
# EMERGENT GARDEN - WEBGL BINDINGS MODULE
# ==============================================================================
#
# Centralized bindings for WebGL 1.0 rendering context and operations.
#
# This module provides idiomatic Nim bindings for:
# - WebGLRenderingContext acquisition from canvas
# - Shader creation, compilation, and linking
# - Program creation and attribute/uniform management
# - Buffer operations (create, bind, upload)
# - Drawing commands and state management
# - WebGL constants as context properties
#
# USAGE:
#   import bindings/webgl
#
#   let gl = canvas.getContext("webgl", options)
#   let shader = gl.createShader(gl.VERTEX_SHADER)
#   gl.shaderSource(shader, source)
#   gl.compileShader(shader)
#
# ==============================================================================

from std/jsffi import JsObject
import ./typed_arrays

# ==============================================================================
# SECTION 1: WEBGL TYPE DEFINITIONS
# ==============================================================================

type
  WebGLRenderingContext* = ref object of JsObject
    ## WebGL 1.0 rendering context

  WebGLProgram* = ref object of JsObject
    ## Compiled and linked shader program

  WebGLShader* = ref object of JsObject
    ## Individual vertex or fragment shader

  WebGLBuffer* = ref object of JsObject
    ## GPU buffer object for vertex/index data

  WebGLUniformLocation* = ref object of JsObject
    ## Reference to a uniform variable location

  WebGLTexture* = ref object of JsObject
    ## Texture object

  WebGLFramebuffer* = ref object of JsObject
    ## Framebuffer object for off-screen rendering

  WebGLRenderbuffer* = ref object of JsObject
    ## Renderbuffer object

# ==============================================================================
# SECTION 2: CANVAS AND DOCUMENT ACCESS
# ==============================================================================

type
  HTMLCanvasElement* = ref object of JsObject
    ## HTML canvas element
    width* {.importjs: "width".}: int
    height* {.importjs: "height".}: int

proc getElementById*(id: cstring): HTMLCanvasElement {.importjs: "document.getElementById(#)".}
  ## Get an HTML element by ID, cast to HTMLCanvasElement

proc getContext*(canvas: HTMLCanvasElement, contextType: cstring, options: JsObject): WebGLRenderingContext {.importjs: "#.getContext(#, #)".}
  ## Get a rendering context from the canvas with options

proc getContext*(canvas: HTMLCanvasElement, contextType: cstring): WebGLRenderingContext {.importjs: "#.getContext(#)".}
  ## Get a rendering context from the canvas

# ==============================================================================
# SECTION 3: WINDOW DIMENSIONS
# ==============================================================================

var innerWidth* {.importjs: "window.innerWidth".}: int
  ## Browser window inner width

var innerHeight* {.importjs: "window.innerHeight".}: int
  ## Browser window inner height

# ==============================================================================
# SECTION 4: SHADER OPERATIONS
# ==============================================================================

proc createShader*(gl: WebGLRenderingContext, shaderType: int): WebGLShader {.importjs: "#.createShader(#)".}
  ## Create a shader object of the specified type (VERTEX_SHADER or FRAGMENT_SHADER)

proc shaderSource*(gl: WebGLRenderingContext, shader: WebGLShader, source: cstring) {.importjs: "#.shaderSource(#, #)".}
  ## Set the source code for a shader

proc compileShader*(gl: WebGLRenderingContext, shader: WebGLShader) {.importjs: "#.compileShader(#)".}
  ## Compile a shader object

proc getShaderParameter*(gl: WebGLRenderingContext, shader: WebGLShader, pname: int): bool {.importjs: "#.getShaderParameter(#, #)".}
  ## Query shader parameter (e.g., COMPILE_STATUS)

proc getShaderInfoLog*(gl: WebGLRenderingContext, shader: WebGLShader): cstring {.importjs: "#.getShaderInfoLog(#)".}
  ## Get shader compilation info log (errors/warnings)

proc deleteShader*(gl: WebGLRenderingContext, shader: WebGLShader) {.importjs: "#.deleteShader(#)".}
  ## Delete a shader object

# ==============================================================================
# SECTION 5: PROGRAM OPERATIONS
# ==============================================================================

proc createProgram*(gl: WebGLRenderingContext): WebGLProgram {.importjs: "#.createProgram()".}
  ## Create a program object

proc attachShader*(gl: WebGLRenderingContext, program: WebGLProgram, shader: WebGLShader) {.importjs: "#.attachShader(#, #)".}
  ## Attach a shader to a program

proc detachShader*(gl: WebGLRenderingContext, program: WebGLProgram, shader: WebGLShader) {.importjs: "#.detachShader(#, #)".}
  ## Detach a shader from a program

proc linkProgram*(gl: WebGLRenderingContext, program: WebGLProgram) {.importjs: "#.linkProgram(#)".}
  ## Link a program object

proc getProgramParameter*(gl: WebGLRenderingContext, program: WebGLProgram, pname: int): bool {.importjs: "#.getProgramParameter(#, #)".}
  ## Query program parameter (e.g., LINK_STATUS)

proc getProgramInfoLog*(gl: WebGLRenderingContext, program: WebGLProgram): cstring {.importjs: "#.getProgramInfoLog(#)".}
  ## Get program linking info log (errors/warnings)

proc useProgram*(gl: WebGLRenderingContext, program: WebGLProgram) {.importjs: "#.useProgram(#)".}
  ## Set the current program for rendering

proc deleteProgram*(gl: WebGLRenderingContext, program: WebGLProgram) {.importjs: "#.deleteProgram(#)".}
  ## Delete a program object

proc validateProgram*(gl: WebGLRenderingContext, program: WebGLProgram) {.importjs: "#.validateProgram(#)".}
  ## Validate a program object

# ==============================================================================
# SECTION 6: ATTRIBUTE OPERATIONS
# ==============================================================================

proc getAttribLocation*(gl: WebGLRenderingContext, program: WebGLProgram, name: cstring): int {.importjs: "#.getAttribLocation(#, #)".}
  ## Get the location of an attribute variable

proc enableVertexAttribArray*(gl: WebGLRenderingContext, index: int) {.importjs: "#.enableVertexAttribArray(#)".}
  ## Enable a vertex attribute array

proc disableVertexAttribArray*(gl: WebGLRenderingContext, index: int) {.importjs: "#.disableVertexAttribArray(#)".}
  ## Disable a vertex attribute array

proc vertexAttribPointer*(gl: WebGLRenderingContext, index: int, size: int, glType: int, normalized: bool, stride: int, offset: int) {.importjs: "#.vertexAttribPointer(#, #, #, #, #, #)".}
  ## Define an array of vertex attribute data
  ##
  ## Parameters:
  ##   index - Attribute location
  ##   size - Number of components per attribute (1-4)
  ##   glType - Data type (e.g., FLOAT)
  ##   normalized - Whether to normalize integer data
  ##   stride - Byte offset between consecutive attributes
  ##   offset - Byte offset to first attribute

proc vertexAttrib1f*(gl: WebGLRenderingContext, index: int, v0: float) {.importjs: "#.vertexAttrib1f(#, #)".}
  ## Set a constant value for a vertex attribute

proc vertexAttrib2f*(gl: WebGLRenderingContext, index: int, v0: float, v1: float) {.importjs: "#.vertexAttrib2f(#, #, #)".}
  ## Set a constant value for a vertex attribute

proc vertexAttrib3f*(gl: WebGLRenderingContext, index: int, v0: float, v1: float, v2: float) {.importjs: "#.vertexAttrib3f(#, #, #, #)".}
  ## Set a constant value for a vertex attribute

proc vertexAttrib4f*(gl: WebGLRenderingContext, index: int, v0: float, v1: float, v2: float, v3: float) {.importjs: "#.vertexAttrib4f(#, #, #, #, #)".}
  ## Set a constant value for a vertex attribute

# ==============================================================================
# SECTION 7: UNIFORM OPERATIONS
# ==============================================================================

proc getUniformLocation*(gl: WebGLRenderingContext, program: WebGLProgram, name: cstring): WebGLUniformLocation {.importjs: "#.getUniformLocation(#, #)".}
  ## Get the location of a uniform variable

proc uniform1f*(gl: WebGLRenderingContext, location: WebGLUniformLocation, value: float) {.importjs: "#.uniform1f(#, #)".}
  ## Set a float uniform

proc uniform2f*(gl: WebGLRenderingContext, location: WebGLUniformLocation, x: float, y: float) {.importjs: "#.uniform2f(#, #, #)".}
  ## Set a vec2 uniform

proc uniform3f*(gl: WebGLRenderingContext, location: WebGLUniformLocation, x: float, y: float, z: float) {.importjs: "#.uniform3f(#, #, #, #)".}
  ## Set a vec3 uniform

proc uniform4f*(gl: WebGLRenderingContext, location: WebGLUniformLocation, x: float, y: float, z: float, w: float) {.importjs: "#.uniform4f(#, #, #, #, #)".}
  ## Set a vec4 uniform

proc uniform1i*(gl: WebGLRenderingContext, location: WebGLUniformLocation, value: int) {.importjs: "#.uniform1i(#, #)".}
  ## Set an integer uniform

proc uniform2i*(gl: WebGLRenderingContext, location: WebGLUniformLocation, x: int, y: int) {.importjs: "#.uniform2i(#, #, #)".}
  ## Set an ivec2 uniform

proc uniform3i*(gl: WebGLRenderingContext, location: WebGLUniformLocation, x: int, y: int, z: int) {.importjs: "#.uniform3i(#, #, #, #)".}
  ## Set an ivec3 uniform

proc uniform4i*(gl: WebGLRenderingContext, location: WebGLUniformLocation, x: int, y: int, z: int, w: int) {.importjs: "#.uniform4i(#, #, #, #, #)".}
  ## Set an ivec4 uniform

proc uniform1fv*(gl: WebGLRenderingContext, location: WebGLUniformLocation, value: JsObject) {.importjs: "#.uniform1fv(#, #)".}
  ## Set float uniform from array

proc uniform2fv*(gl: WebGLRenderingContext, location: WebGLUniformLocation, value: JsObject) {.importjs: "#.uniform2fv(#, #)".}
  ## Set vec2 uniform from array

proc uniform3fv*(gl: WebGLRenderingContext, location: WebGLUniformLocation, value: JsObject) {.importjs: "#.uniform3fv(#, #)".}
  ## Set vec3 uniform from array

proc uniform4fv*(gl: WebGLRenderingContext, location: WebGLUniformLocation, value: JsObject) {.importjs: "#.uniform4fv(#, #)".}
  ## Set vec4 uniform from array

proc uniformMatrix2fv*(gl: WebGLRenderingContext, location: WebGLUniformLocation, transpose: bool, value: JsObject) {.importjs: "#.uniformMatrix2fv(#, #, #)".}
  ## Set a 2x2 matrix uniform

proc uniformMatrix3fv*(gl: WebGLRenderingContext, location: WebGLUniformLocation, transpose: bool, value: JsObject) {.importjs: "#.uniformMatrix3fv(#, #, #)".}
  ## Set a 3x3 matrix uniform

proc uniformMatrix4fv*(gl: WebGLRenderingContext, location: WebGLUniformLocation, transpose: bool, value: JsObject) {.importjs: "#.uniformMatrix4fv(#, #, #)".}
  ## Set a 4x4 matrix uniform

# ==============================================================================
# SECTION 8: BUFFER OPERATIONS
# ==============================================================================

proc createBuffer*(gl: WebGLRenderingContext): WebGLBuffer {.importjs: "#.createBuffer()".}
  ## Create a buffer object

proc bindBuffer*(gl: WebGLRenderingContext, target: int, buffer: WebGLBuffer) {.importjs: "#.bindBuffer(#, #)".}
  ## Bind a buffer to a target (ARRAY_BUFFER or ELEMENT_ARRAY_BUFFER)

proc bufferData*(gl: WebGLRenderingContext, target: int, size: int, usage: int) {.importjs: "#.bufferData(#, #, #)".}
  ## Allocate buffer storage without initial data

proc bufferData*(gl: WebGLRenderingContext, target: int, data: JsObject, usage: int) {.importjs: "#.bufferData(#, #, #)".}
  ## Upload data to the currently bound buffer

proc bufferData*(gl: WebGLRenderingContext, target: int, data: Float32Array, usage: int) {.importjs: "#.bufferData(#, #, #)".}
  ## Upload Float32Array data to the currently bound buffer

proc bufferSubData*(gl: WebGLRenderingContext, target: int, offset: int, data: JsObject) {.importjs: "#.bufferSubData(#, #, #)".}
  ## Update a subset of a buffer's data

proc bufferSubData*(gl: WebGLRenderingContext, target: int, offset: int, data: Float32Array) {.importjs: "#.bufferSubData(#, #, #)".}
  ## Update a subset of a buffer's data with Float32Array

proc deleteBuffer*(gl: WebGLRenderingContext, buffer: WebGLBuffer) {.importjs: "#.deleteBuffer(#)".}
  ## Delete a buffer object

proc isBuffer*(gl: WebGLRenderingContext, buffer: WebGLBuffer): bool {.importjs: "#.isBuffer(#)".}
  ## Check if object is a valid buffer

# ==============================================================================
# SECTION 9: DRAWING OPERATIONS
# ==============================================================================

proc drawArrays*(gl: WebGLRenderingContext, mode: int, first: int, count: int) {.importjs: "#.drawArrays(#, #, #)".}
  ## Draw primitives from array data

proc drawElements*(gl: WebGLRenderingContext, mode: int, count: int, glType: int, offset: int) {.importjs: "#.drawElements(#, #, #, #)".}
  ## Draw primitives from element array data

# ==============================================================================
# SECTION 10: CLEAR AND VIEWPORT
# ==============================================================================

proc clearColor*(gl: WebGLRenderingContext, r: float, g: float, b: float, a: float) {.importjs: "#.clearColor(#, #, #, #)".}
  ## Set the clear color (RGBA, 0.0-1.0)

proc clearDepth*(gl: WebGLRenderingContext, depth: float) {.importjs: "#.clearDepth(#)".}
  ## Set the clear depth value

proc clearStencil*(gl: WebGLRenderingContext, s: int) {.importjs: "#.clearStencil(#)".}
  ## Set the clear stencil value

proc clear*(gl: WebGLRenderingContext, mask: int) {.importjs: "#.clear(#)".}
  ## Clear buffers to preset values

proc viewport*(gl: WebGLRenderingContext, x: int, y: int, width: int, height: int) {.importjs: "#.viewport(#, #, #, #)".}
  ## Set the viewport

proc scissor*(gl: WebGLRenderingContext, x: int, y: int, width: int, height: int) {.importjs: "#.scissor(#, #, #, #)".}
  ## Set the scissor box

# ==============================================================================
# SECTION 11: STATE MANAGEMENT
# ==============================================================================

proc enable*(gl: WebGLRenderingContext, cap: int) {.importjs: "#.enable(#)".}
  ## Enable a capability

proc disable*(gl: WebGLRenderingContext, cap: int) {.importjs: "#.disable(#)".}
  ## Disable a capability

proc isEnabled*(gl: WebGLRenderingContext, cap: int): bool {.importjs: "#.isEnabled(#)".}
  ## Test whether a capability is enabled

proc blendFunc*(gl: WebGLRenderingContext, sfactor: int, dfactor: int) {.importjs: "#.blendFunc(#, #)".}
  ## Set the pixel blending factors

proc blendFuncSeparate*(gl: WebGLRenderingContext, srcRGB: int, dstRGB: int, srcAlpha: int, dstAlpha: int) {.importjs: "#.blendFuncSeparate(#, #, #, #)".}
  ## Set RGB and alpha blending factors separately

proc blendEquation*(gl: WebGLRenderingContext, mode: int) {.importjs: "#.blendEquation(#)".}
  ## Set the blend equation

proc blendEquationSeparate*(gl: WebGLRenderingContext, modeRGB: int, modeAlpha: int) {.importjs: "#.blendEquationSeparate(#, #)".}
  ## Set RGB and alpha blend equations separately

proc blendColor*(gl: WebGLRenderingContext, r: float, g: float, b: float, a: float) {.importjs: "#.blendColor(#, #, #, #)".}
  ## Set the blend color

proc depthFunc*(gl: WebGLRenderingContext, fn: int) {.importjs: "#.depthFunc(#)".}
  ## Set the depth comparison function

proc depthMask*(gl: WebGLRenderingContext, flag: bool) {.importjs: "#.depthMask(#)".}
  ## Enable or disable writing to the depth buffer

proc depthRange*(gl: WebGLRenderingContext, zNear: float, zFar: float) {.importjs: "#.depthRange(#, #)".}
  ## Set the depth range

proc colorMask*(gl: WebGLRenderingContext, r: bool, g: bool, b: bool, a: bool) {.importjs: "#.colorMask(#, #, #, #)".}
  ## Enable or disable writing to color components

proc cullFace*(gl: WebGLRenderingContext, mode: int) {.importjs: "#.cullFace(#)".}
  ## Specify which faces to cull

proc frontFace*(gl: WebGLRenderingContext, mode: int) {.importjs: "#.frontFace(#)".}
  ## Define front- and back-facing polygons

proc lineWidth*(gl: WebGLRenderingContext, width: float) {.importjs: "#.lineWidth(#)".}
  ## Set line width

proc polygonOffset*(gl: WebGLRenderingContext, factor: float, units: float) {.importjs: "#.polygonOffset(#, #)".}
  ## Set polygon offset

# ==============================================================================
# SECTION 12: TEXTURE OPERATIONS
# ==============================================================================

proc createTexture*(gl: WebGLRenderingContext): WebGLTexture {.importjs: "#.createTexture()".}
  ## Create a texture object

proc bindTexture*(gl: WebGLRenderingContext, target: int, texture: WebGLTexture) {.importjs: "#.bindTexture(#, #)".}
  ## Bind a texture to a target

proc activeTexture*(gl: WebGLRenderingContext, texture: int) {.importjs: "#.activeTexture(#)".}
  ## Select the active texture unit

proc texImage2D*(gl: WebGLRenderingContext, target: int, level: int, internalformat: int, width: int, height: int, border: int, format: int, glType: int, pixels: JsObject) {.importjs: "#.texImage2D(#, #, #, #, #, #, #, #, #)".}
  ## Specify a 2D texture image

proc texSubImage2D*(gl: WebGLRenderingContext, target: int, level: int, xoffset: int, yoffset: int, width: int, height: int, format: int, glType: int, pixels: JsObject) {.importjs: "#.texSubImage2D(#, #, #, #, #, #, #, #, #)".}
  ## Specify a 2D texture subimage

proc texParameteri*(gl: WebGLRenderingContext, target: int, pname: int, param: int) {.importjs: "#.texParameteri(#, #, #)".}
  ## Set texture parameters (integer)

proc texParameterf*(gl: WebGLRenderingContext, target: int, pname: int, param: float) {.importjs: "#.texParameterf(#, #, #)".}
  ## Set texture parameters (float)

proc deleteTexture*(gl: WebGLRenderingContext, texture: WebGLTexture) {.importjs: "#.deleteTexture(#)".}
  ## Delete a texture object

proc generateMipmap*(gl: WebGLRenderingContext, target: int) {.importjs: "#.generateMipmap(#)".}
  ## Generate mipmap chain for texture

proc pixelStorei*(gl: WebGLRenderingContext, pname: int, param: int) {.importjs: "#.pixelStorei(#, #)".}
  ## Set pixel storage modes

# ==============================================================================
# SECTION 13: FRAMEBUFFER OPERATIONS
# ==============================================================================

proc createFramebuffer*(gl: WebGLRenderingContext): WebGLFramebuffer {.importjs: "#.createFramebuffer()".}
  ## Create a framebuffer object

proc bindFramebuffer*(gl: WebGLRenderingContext, target: int, framebuffer: WebGLFramebuffer) {.importjs: "#.bindFramebuffer(#, #)".}
  ## Bind a framebuffer object

proc framebufferTexture2D*(gl: WebGLRenderingContext, target: int, attachment: int, textarget: int, texture: WebGLTexture, level: int) {.importjs: "#.framebufferTexture2D(#, #, #, #, #)".}
  ## Attach a texture to a framebuffer

proc framebufferRenderbuffer*(gl: WebGLRenderingContext, target: int, attachment: int, renderbuffertarget: int, renderbuffer: WebGLRenderbuffer) {.importjs: "#.framebufferRenderbuffer(#, #, #, #)".}
  ## Attach a renderbuffer to a framebuffer

proc checkFramebufferStatus*(gl: WebGLRenderingContext, target: int): int {.importjs: "#.checkFramebufferStatus(#)".}
  ## Check framebuffer completeness

proc deleteFramebuffer*(gl: WebGLRenderingContext, framebuffer: WebGLFramebuffer) {.importjs: "#.deleteFramebuffer(#)".}
  ## Delete a framebuffer object

# ==============================================================================
# SECTION 14: RENDERBUFFER OPERATIONS
# ==============================================================================

proc createRenderbuffer*(gl: WebGLRenderingContext): WebGLRenderbuffer {.importjs: "#.createRenderbuffer()".}
  ## Create a renderbuffer object

proc bindRenderbuffer*(gl: WebGLRenderingContext, target: int, renderbuffer: WebGLRenderbuffer) {.importjs: "#.bindRenderbuffer(#, #)".}
  ## Bind a renderbuffer object

proc renderbufferStorage*(gl: WebGLRenderingContext, target: int, internalformat: int, width: int, height: int) {.importjs: "#.renderbufferStorage(#, #, #, #)".}
  ## Create renderbuffer storage

proc deleteRenderbuffer*(gl: WebGLRenderingContext, renderbuffer: WebGLRenderbuffer) {.importjs: "#.deleteRenderbuffer(#)".}
  ## Delete a renderbuffer object

# ==============================================================================
# SECTION 15: READING PIXELS
# ==============================================================================

proc readPixels*(gl: WebGLRenderingContext, x: int, y: int, width: int, height: int, format: int, glType: int, pixels: JsObject) {.importjs: "#.readPixels(#, #, #, #, #, #, #)".}
  ## Read pixels from framebuffer

# ==============================================================================
# SECTION 16: ERROR AND STATE QUERIES
# ==============================================================================

proc getError*(gl: WebGLRenderingContext): int {.importjs: "#.getError()".}
  ## Return error information

proc getParameter*(gl: WebGLRenderingContext, pname: int): JsObject {.importjs: "#.getParameter(#)".}
  ## Return value for parameter

proc finish*(gl: WebGLRenderingContext) {.importjs: "#.finish()".}
  ## Block until all GL commands complete

proc flush*(gl: WebGLRenderingContext) {.importjs: "#.flush()".}
  ## Force execution of GL commands

# ==============================================================================
# SECTION 17: WEBGL CONSTANTS - SHADER TYPES
# ==============================================================================

proc VERTEX_SHADER*(gl: WebGLRenderingContext): int {.importjs: "#.VERTEX_SHADER".}
  ## Vertex shader type constant

proc FRAGMENT_SHADER*(gl: WebGLRenderingContext): int {.importjs: "#.FRAGMENT_SHADER".}
  ## Fragment shader type constant

# ==============================================================================
# SECTION 18: WEBGL CONSTANTS - STATUS QUERIES
# ==============================================================================

proc COMPILE_STATUS*(gl: WebGLRenderingContext): int {.importjs: "#.COMPILE_STATUS".}
  ## Shader compile status constant

proc LINK_STATUS*(gl: WebGLRenderingContext): int {.importjs: "#.LINK_STATUS".}
  ## Program link status constant

proc VALIDATE_STATUS*(gl: WebGLRenderingContext): int {.importjs: "#.VALIDATE_STATUS".}
  ## Program validate status constant

# ==============================================================================
# SECTION 19: WEBGL CONSTANTS - BUFFER TARGETS
# ==============================================================================

proc ARRAY_BUFFER*(gl: WebGLRenderingContext): int {.importjs: "#.ARRAY_BUFFER".}
  ## Vertex attribute buffer target

proc ELEMENT_ARRAY_BUFFER*(gl: WebGLRenderingContext): int {.importjs: "#.ELEMENT_ARRAY_BUFFER".}
  ## Index buffer target

# ==============================================================================
# SECTION 20: WEBGL CONSTANTS - BUFFER USAGE
# ==============================================================================

proc STATIC_DRAW*(gl: WebGLRenderingContext): int {.importjs: "#.STATIC_DRAW".}
  ## Buffer used many times, data set once

proc DYNAMIC_DRAW*(gl: WebGLRenderingContext): int {.importjs: "#.DYNAMIC_DRAW".}
  ## Buffer used many times, data changed often

proc STREAM_DRAW*(gl: WebGLRenderingContext): int {.importjs: "#.STREAM_DRAW".}
  ## Buffer used few times, data set once

# ==============================================================================
# SECTION 21: WEBGL CONSTANTS - DATA TYPES
# ==============================================================================

proc FLOAT*(gl: WebGLRenderingContext): int {.importjs: "#.FLOAT".}
  ## 32-bit float type

proc BYTE*(gl: WebGLRenderingContext): int {.importjs: "#.BYTE".}
  ## 8-bit signed integer type

proc UNSIGNED_BYTE*(gl: WebGLRenderingContext): int {.importjs: "#.UNSIGNED_BYTE".}
  ## 8-bit unsigned integer type

proc SHORT*(gl: WebGLRenderingContext): int {.importjs: "#.SHORT".}
  ## 16-bit signed integer type

proc UNSIGNED_SHORT*(gl: WebGLRenderingContext): int {.importjs: "#.UNSIGNED_SHORT".}
  ## 16-bit unsigned integer type

proc INT*(gl: WebGLRenderingContext): int {.importjs: "#.INT".}
  ## 32-bit signed integer type

proc UNSIGNED_INT*(gl: WebGLRenderingContext): int {.importjs: "#.UNSIGNED_INT".}
  ## 32-bit unsigned integer type

# ==============================================================================
# SECTION 22: WEBGL CONSTANTS - PRIMITIVE TYPES
# ==============================================================================

proc POINTS*(gl: WebGLRenderingContext): int {.importjs: "#.POINTS".}
  ## Draw points

proc LINES*(gl: WebGLRenderingContext): int {.importjs: "#.LINES".}
  ## Draw line segments

proc LINE_STRIP*(gl: WebGLRenderingContext): int {.importjs: "#.LINE_STRIP".}
  ## Draw connected line segments

proc LINE_LOOP*(gl: WebGLRenderingContext): int {.importjs: "#.LINE_LOOP".}
  ## Draw closed line loop

proc TRIANGLES*(gl: WebGLRenderingContext): int {.importjs: "#.TRIANGLES".}
  ## Draw triangles

proc TRIANGLE_STRIP*(gl: WebGLRenderingContext): int {.importjs: "#.TRIANGLE_STRIP".}
  ## Draw triangle strip

proc TRIANGLE_FAN*(gl: WebGLRenderingContext): int {.importjs: "#.TRIANGLE_FAN".}
  ## Draw triangle fan

# ==============================================================================
# SECTION 23: WEBGL CONSTANTS - CLEAR BITS
# ==============================================================================

proc COLOR_BUFFER_BIT*(gl: WebGLRenderingContext): int {.importjs: "#.COLOR_BUFFER_BIT".}
  ## Clear color buffer

proc DEPTH_BUFFER_BIT*(gl: WebGLRenderingContext): int {.importjs: "#.DEPTH_BUFFER_BIT".}
  ## Clear depth buffer

proc STENCIL_BUFFER_BIT*(gl: WebGLRenderingContext): int {.importjs: "#.STENCIL_BUFFER_BIT".}
  ## Clear stencil buffer

# ==============================================================================
# SECTION 24: WEBGL CONSTANTS - BLENDING
# ==============================================================================

proc BLEND*(gl: WebGLRenderingContext): int {.importjs: "#.BLEND".}
  ## Enable blending capability

proc ZERO*(gl: WebGLRenderingContext): int {.importjs: "#.ZERO".}
  ## Blend factor: 0

proc ONE*(gl: WebGLRenderingContext): int {.importjs: "#.ONE".}
  ## Blend factor: 1

proc SRC_COLOR*(gl: WebGLRenderingContext): int {.importjs: "#.SRC_COLOR".}
  ## Blend factor: source color

proc ONE_MINUS_SRC_COLOR*(gl: WebGLRenderingContext): int {.importjs: "#.ONE_MINUS_SRC_COLOR".}
  ## Blend factor: 1 - source color

proc DST_COLOR*(gl: WebGLRenderingContext): int {.importjs: "#.DST_COLOR".}
  ## Blend factor: destination color

proc ONE_MINUS_DST_COLOR*(gl: WebGLRenderingContext): int {.importjs: "#.ONE_MINUS_DST_COLOR".}
  ## Blend factor: 1 - destination color

proc SRC_ALPHA*(gl: WebGLRenderingContext): int {.importjs: "#.SRC_ALPHA".}
  ## Blend factor: source alpha

proc ONE_MINUS_SRC_ALPHA*(gl: WebGLRenderingContext): int {.importjs: "#.ONE_MINUS_SRC_ALPHA".}
  ## Blend factor: 1 - source alpha

proc DST_ALPHA*(gl: WebGLRenderingContext): int {.importjs: "#.DST_ALPHA".}
  ## Blend factor: destination alpha

proc ONE_MINUS_DST_ALPHA*(gl: WebGLRenderingContext): int {.importjs: "#.ONE_MINUS_DST_ALPHA".}
  ## Blend factor: 1 - destination alpha

proc CONSTANT_COLOR*(gl: WebGLRenderingContext): int {.importjs: "#.CONSTANT_COLOR".}
  ## Blend factor: constant color

proc ONE_MINUS_CONSTANT_COLOR*(gl: WebGLRenderingContext): int {.importjs: "#.ONE_MINUS_CONSTANT_COLOR".}
  ## Blend factor: 1 - constant color

proc CONSTANT_ALPHA*(gl: WebGLRenderingContext): int {.importjs: "#.CONSTANT_ALPHA".}
  ## Blend factor: constant alpha

proc ONE_MINUS_CONSTANT_ALPHA*(gl: WebGLRenderingContext): int {.importjs: "#.ONE_MINUS_CONSTANT_ALPHA".}
  ## Blend factor: 1 - constant alpha

proc SRC_ALPHA_SATURATE*(gl: WebGLRenderingContext): int {.importjs: "#.SRC_ALPHA_SATURATE".}
  ## Blend factor: min(src alpha, 1 - dst alpha)

# ==============================================================================
# SECTION 25: WEBGL CONSTANTS - BLEND EQUATIONS
# ==============================================================================

proc FUNC_ADD*(gl: WebGLRenderingContext): int {.importjs: "#.FUNC_ADD".}
  ## Blend equation: add

proc FUNC_SUBTRACT*(gl: WebGLRenderingContext): int {.importjs: "#.FUNC_SUBTRACT".}
  ## Blend equation: subtract

proc FUNC_REVERSE_SUBTRACT*(gl: WebGLRenderingContext): int {.importjs: "#.FUNC_REVERSE_SUBTRACT".}
  ## Blend equation: reverse subtract

# ==============================================================================
# SECTION 26: WEBGL CONSTANTS - CAPABILITIES
# ==============================================================================

proc CULL_FACE*(gl: WebGLRenderingContext): int {.importjs: "#.CULL_FACE".}
  ## Enable face culling

proc DEPTH_TEST*(gl: WebGLRenderingContext): int {.importjs: "#.DEPTH_TEST".}
  ## Enable depth testing

proc STENCIL_TEST*(gl: WebGLRenderingContext): int {.importjs: "#.STENCIL_TEST".}
  ## Enable stencil testing

proc DITHER*(gl: WebGLRenderingContext): int {.importjs: "#.DITHER".}
  ## Enable dithering

proc SCISSOR_TEST*(gl: WebGLRenderingContext): int {.importjs: "#.SCISSOR_TEST".}
  ## Enable scissor testing

proc POLYGON_OFFSET_FILL*(gl: WebGLRenderingContext): int {.importjs: "#.POLYGON_OFFSET_FILL".}
  ## Enable polygon offset

proc SAMPLE_ALPHA_TO_COVERAGE*(gl: WebGLRenderingContext): int {.importjs: "#.SAMPLE_ALPHA_TO_COVERAGE".}
  ## Enable alpha to coverage

proc SAMPLE_COVERAGE*(gl: WebGLRenderingContext): int {.importjs: "#.SAMPLE_COVERAGE".}
  ## Enable sample coverage

# ==============================================================================
# SECTION 27: WEBGL CONSTANTS - DEPTH FUNCTIONS
# ==============================================================================

proc NEVER*(gl: WebGLRenderingContext): int {.importjs: "#.NEVER".}
  ## Depth function: never pass

proc LESS*(gl: WebGLRenderingContext): int {.importjs: "#.LESS".}
  ## Depth function: pass if less

proc EQUAL*(gl: WebGLRenderingContext): int {.importjs: "#.EQUAL".}
  ## Depth function: pass if equal

proc LEQUAL*(gl: WebGLRenderingContext): int {.importjs: "#.LEQUAL".}
  ## Depth function: pass if less or equal

proc GREATER*(gl: WebGLRenderingContext): int {.importjs: "#.GREATER".}
  ## Depth function: pass if greater

proc NOTEQUAL*(gl: WebGLRenderingContext): int {.importjs: "#.NOTEQUAL".}
  ## Depth function: pass if not equal

proc GEQUAL*(gl: WebGLRenderingContext): int {.importjs: "#.GEQUAL".}
  ## Depth function: pass if greater or equal

proc ALWAYS*(gl: WebGLRenderingContext): int {.importjs: "#.ALWAYS".}
  ## Depth function: always pass

# ==============================================================================
# SECTION 28: WEBGL CONSTANTS - CULLING
# ==============================================================================

proc FRONT*(gl: WebGLRenderingContext): int {.importjs: "#.FRONT".}
  ## Cull front faces

proc BACK*(gl: WebGLRenderingContext): int {.importjs: "#.BACK".}
  ## Cull back faces

proc FRONT_AND_BACK*(gl: WebGLRenderingContext): int {.importjs: "#.FRONT_AND_BACK".}
  ## Cull front and back faces

proc CW*(gl: WebGLRenderingContext): int {.importjs: "#.CW".}
  ## Clockwise winding

proc CCW*(gl: WebGLRenderingContext): int {.importjs: "#.CCW".}
  ## Counter-clockwise winding

# ==============================================================================
# SECTION 29: WEBGL CONSTANTS - TEXTURE
# ==============================================================================

proc TEXTURE_2D*(gl: WebGLRenderingContext): int {.importjs: "#.TEXTURE_2D".}
  ## 2D texture target

proc TEXTURE_CUBE_MAP*(gl: WebGLRenderingContext): int {.importjs: "#.TEXTURE_CUBE_MAP".}
  ## Cube map texture target

proc TEXTURE0*(gl: WebGLRenderingContext): int {.importjs: "#.TEXTURE0".}
  ## Texture unit 0

proc TEXTURE1*(gl: WebGLRenderingContext): int {.importjs: "#.TEXTURE1".}
  ## Texture unit 1

proc TEXTURE2*(gl: WebGLRenderingContext): int {.importjs: "#.TEXTURE2".}
  ## Texture unit 2

proc TEXTURE3*(gl: WebGLRenderingContext): int {.importjs: "#.TEXTURE3".}
  ## Texture unit 3

proc TEXTURE_MAG_FILTER*(gl: WebGLRenderingContext): int {.importjs: "#.TEXTURE_MAG_FILTER".}
  ## Texture magnification filter parameter

proc TEXTURE_MIN_FILTER*(gl: WebGLRenderingContext): int {.importjs: "#.TEXTURE_MIN_FILTER".}
  ## Texture minification filter parameter

proc TEXTURE_WRAP_S*(gl: WebGLRenderingContext): int {.importjs: "#.TEXTURE_WRAP_S".}
  ## Texture wrap S parameter

proc TEXTURE_WRAP_T*(gl: WebGLRenderingContext): int {.importjs: "#.TEXTURE_WRAP_T".}
  ## Texture wrap T parameter

proc NEAREST*(gl: WebGLRenderingContext): int {.importjs: "#.NEAREST".}
  ## Nearest filtering

proc LINEAR*(gl: WebGLRenderingContext): int {.importjs: "#.LINEAR".}
  ## Linear filtering

proc NEAREST_MIPMAP_NEAREST*(gl: WebGLRenderingContext): int {.importjs: "#.NEAREST_MIPMAP_NEAREST".}
  ## Nearest mipmap, nearest filtering

proc LINEAR_MIPMAP_NEAREST*(gl: WebGLRenderingContext): int {.importjs: "#.LINEAR_MIPMAP_NEAREST".}
  ## Linear mipmap, nearest filtering

proc NEAREST_MIPMAP_LINEAR*(gl: WebGLRenderingContext): int {.importjs: "#.NEAREST_MIPMAP_LINEAR".}
  ## Nearest mipmap, linear filtering

proc LINEAR_MIPMAP_LINEAR*(gl: WebGLRenderingContext): int {.importjs: "#.LINEAR_MIPMAP_LINEAR".}
  ## Linear mipmap, linear filtering (trilinear)

proc REPEAT*(gl: WebGLRenderingContext): int {.importjs: "#.REPEAT".}
  ## Repeat texture wrapping

proc CLAMP_TO_EDGE*(gl: WebGLRenderingContext): int {.importjs: "#.CLAMP_TO_EDGE".}
  ## Clamp to edge texture wrapping

proc MIRRORED_REPEAT*(gl: WebGLRenderingContext): int {.importjs: "#.MIRRORED_REPEAT".}
  ## Mirrored repeat texture wrapping

# ==============================================================================
# SECTION 30: WEBGL CONSTANTS - PIXEL FORMATS
# ==============================================================================

proc RGBA*(gl: WebGLRenderingContext): int {.importjs: "#.RGBA".}
  ## RGBA pixel format

proc RGB*(gl: WebGLRenderingContext): int {.importjs: "#.RGB".}
  ## RGB pixel format

proc ALPHA*(gl: WebGLRenderingContext): int {.importjs: "#.ALPHA".}
  ## Alpha-only pixel format

proc LUMINANCE*(gl: WebGLRenderingContext): int {.importjs: "#.LUMINANCE".}
  ## Luminance pixel format

proc LUMINANCE_ALPHA*(gl: WebGLRenderingContext): int {.importjs: "#.LUMINANCE_ALPHA".}
  ## Luminance with alpha pixel format

# ==============================================================================
# SECTION 31: WEBGL CONSTANTS - FRAMEBUFFER
# ==============================================================================

proc FRAMEBUFFER*(gl: WebGLRenderingContext): int {.importjs: "#.FRAMEBUFFER".}
  ## Framebuffer target

proc RENDERBUFFER*(gl: WebGLRenderingContext): int {.importjs: "#.RENDERBUFFER".}
  ## Renderbuffer target

proc COLOR_ATTACHMENT0*(gl: WebGLRenderingContext): int {.importjs: "#.COLOR_ATTACHMENT0".}
  ## Color attachment 0

proc DEPTH_ATTACHMENT*(gl: WebGLRenderingContext): int {.importjs: "#.DEPTH_ATTACHMENT".}
  ## Depth attachment

proc STENCIL_ATTACHMENT*(gl: WebGLRenderingContext): int {.importjs: "#.STENCIL_ATTACHMENT".}
  ## Stencil attachment

proc DEPTH_STENCIL_ATTACHMENT*(gl: WebGLRenderingContext): int {.importjs: "#.DEPTH_STENCIL_ATTACHMENT".}
  ## Depth-stencil attachment

proc FRAMEBUFFER_COMPLETE*(gl: WebGLRenderingContext): int {.importjs: "#.FRAMEBUFFER_COMPLETE".}
  ## Framebuffer is complete

proc DEPTH_COMPONENT16*(gl: WebGLRenderingContext): int {.importjs: "#.DEPTH_COMPONENT16".}
  ## 16-bit depth format

proc STENCIL_INDEX8*(gl: WebGLRenderingContext): int {.importjs: "#.STENCIL_INDEX8".}
  ## 8-bit stencil format

proc DEPTH_STENCIL*(gl: WebGLRenderingContext): int {.importjs: "#.DEPTH_STENCIL".}
  ## Depth-stencil format

# ==============================================================================
# SECTION 32: WEBGL CONSTANTS - ERRORS
# ==============================================================================

proc NO_ERROR*(gl: WebGLRenderingContext): int {.importjs: "#.NO_ERROR".}
  ## No error

proc INVALID_ENUM*(gl: WebGLRenderingContext): int {.importjs: "#.INVALID_ENUM".}
  ## Invalid enum error

proc INVALID_VALUE*(gl: WebGLRenderingContext): int {.importjs: "#.INVALID_VALUE".}
  ## Invalid value error

proc INVALID_OPERATION*(gl: WebGLRenderingContext): int {.importjs: "#.INVALID_OPERATION".}
  ## Invalid operation error

proc OUT_OF_MEMORY*(gl: WebGLRenderingContext): int {.importjs: "#.OUT_OF_MEMORY".}
  ## Out of memory error

proc CONTEXT_LOST_WEBGL*(gl: WebGLRenderingContext): int {.importjs: "#.CONTEXT_LOST_WEBGL".}
  ## Context lost error

# ==============================================================================
# SECTION 33: WEBGL CONSTANTS - PIXEL STORAGE
# ==============================================================================

proc UNPACK_FLIP_Y_WEBGL*(gl: WebGLRenderingContext): int {.importjs: "#.UNPACK_FLIP_Y_WEBGL".}
  ## Flip Y axis when unpacking

proc UNPACK_PREMULTIPLY_ALPHA_WEBGL*(gl: WebGLRenderingContext): int {.importjs: "#.UNPACK_PREMULTIPLY_ALPHA_WEBGL".}
  ## Premultiply alpha when unpacking

proc UNPACK_ALIGNMENT*(gl: WebGLRenderingContext): int {.importjs: "#.UNPACK_ALIGNMENT".}
  ## Unpack alignment

proc PACK_ALIGNMENT*(gl: WebGLRenderingContext): int {.importjs: "#.PACK_ALIGNMENT".}
  ## Pack alignment

# ==============================================================================
# SECTION 34: HELPER - FLOAT32ARRAY FROM SEQ
# ==============================================================================

proc newFloat32ArrayFromSeq*(data: seq[float32]): JsObject {.importjs: "new Float32Array(#)".}
  ## Create a Float32Array from a Nim seq[float32]

# ==============================================================================
# SECTION 35: ALERT HELPER
# ==============================================================================

proc jsAlert*(msg: cstring) {.importjs: "alert(#)".}
  ## Display a browser alert dialog

# ==============================================================================
# SECTION 36: TYPE ALIASES FOR LEGACY COMPATIBILITY
# ==============================================================================

# Aliases matching existing naming conventions in renderer.nim
proc glVertexShader*(gl: WebGLRenderingContext): int {.importjs: "#.VERTEX_SHADER".}
  ## Legacy alias for VERTEX_SHADER

proc glFragmentShader*(gl: WebGLRenderingContext): int {.importjs: "#.FRAGMENT_SHADER".}
  ## Legacy alias for FRAGMENT_SHADER

proc glCompileStatus*(gl: WebGLRenderingContext): int {.importjs: "#.COMPILE_STATUS".}
  ## Legacy alias for COMPILE_STATUS

proc glLinkStatus*(gl: WebGLRenderingContext): int {.importjs: "#.LINK_STATUS".}
  ## Legacy alias for LINK_STATUS

proc glArrayBuffer*(gl: WebGLRenderingContext): int {.importjs: "#.ARRAY_BUFFER".}
  ## Legacy alias for ARRAY_BUFFER

proc glDynamicDraw*(gl: WebGLRenderingContext): int {.importjs: "#.DYNAMIC_DRAW".}
  ## Legacy alias for DYNAMIC_DRAW

proc glStaticDraw*(gl: WebGLRenderingContext): int {.importjs: "#.STATIC_DRAW".}
  ## Legacy alias for STATIC_DRAW

proc glFloat*(gl: WebGLRenderingContext): int {.importjs: "#.FLOAT".}
  ## Legacy alias for FLOAT

proc glPoints*(gl: WebGLRenderingContext): int {.importjs: "#.POINTS".}
  ## Legacy alias for POINTS

proc glTriangles*(gl: WebGLRenderingContext): int {.importjs: "#.TRIANGLES".}
  ## Legacy alias for TRIANGLES

proc glColorBufferBit*(gl: WebGLRenderingContext): int {.importjs: "#.COLOR_BUFFER_BIT".}
  ## Legacy alias for COLOR_BUFFER_BIT

proc glBlend*(gl: WebGLRenderingContext): int {.importjs: "#.BLEND".}
  ## Legacy alias for BLEND

proc glSrcAlpha*(gl: WebGLRenderingContext): int {.importjs: "#.SRC_ALPHA".}
  ## Legacy alias for SRC_ALPHA

proc glOneMinusSrcAlpha*(gl: WebGLRenderingContext): int {.importjs: "#.ONE_MINUS_SRC_ALPHA".}
  ## Legacy alias for ONE_MINUS_SRC_ALPHA

# Legacy buffer data procedures matching renderer.nim naming
proc bufferDataSize*(gl: WebGLRenderingContext, target: int, size: int, usage: int) {.importjs: "#.bufferData(#, #, #)".}
  ## Legacy alias for bufferData with size

proc bufferDataArray*(gl: WebGLRenderingContext, target: int, data: JsObject, usage: int) {.importjs: "#.bufferData(#, #, #)".}
  ## Legacy alias for bufferData with data
