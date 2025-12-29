# ==============================================================================
# EMERGENT GARDEN - WEBGPU BINDINGS
# ==============================================================================
#
# Idiomatic Nim bindings for the WebGPU API.
#
# This module provides type-safe bindings for:
# - GPU global object and adapter/device acquisition
# - Buffer creation and management (GPUBuffer)
# - Shader modules and compute pipelines
# - Bind groups and bind group layouts
# - Command encoding and compute pass dispatch
# - Buffer usage flags (GPUBufferUsage)
# - Map modes (GPUMapMode)
#
# ARCHITECTURE NOTES:
# WebGPU uses async patterns for device acquisition and buffer mapping.
# All async methods return Future[T] for use with Nim's async/await.
#
# USAGE:
#   import bindings/webgpu
#
#   let adapter = await navigator.gpu.requestAdapter()
#   let device = await adapter.requestDevice()
#   let buffer = device.createBuffer(CreateBufferDescriptor(
#     size: 1024,
#     usage: GPUBufferUsage.STORAGE or GPUBufferUsage.COPY_DST
#   ))
#
# ==============================================================================

from std/jsffi import JsObject
from std/asyncjs import Future
import ./typed_arrays

# ==============================================================================
# SECTION 1: CORE TYPES
# ==============================================================================

type
  GPU* = ref object of JsObject
    ## Navigator.gpu - the entry point for WebGPU

  GPUAdapter* = ref object of JsObject
    ## Physical GPU adapter with capabilities

  GPUAdapterInfo* = ref object of JsObject
    ## Information about a GPU adapter

  GPUDevice* = ref object of JsObject
    ## Logical GPU device for creating resources

  GPUQueue* = ref object of JsObject
    ## Command queue for submitting GPU work

  GPUBuffer* = ref object of JsObject
    ## GPU-side buffer for data storage

  GPUShaderModule* = ref object of JsObject
    ## Compiled shader code (WGSL)

  GPUComputePipeline* = ref object of JsObject
    ## Compute shader pipeline

  GPUBindGroup* = ref object of JsObject
    ## Group of bound resources for a shader

  GPUBindGroupLayout* = ref object of JsObject
    ## Layout description for a bind group

  GPUPipelineLayout* = ref object of JsObject
    ## Layout for pipeline bind groups

  GPUCommandEncoder* = ref object of JsObject
    ## Encoder for GPU commands

  GPUComputePassEncoder* = ref object of JsObject
    ## Encoder for compute pass commands

  GPUCommandBuffer* = ref object of JsObject
    ## Finished command buffer ready for submission

  GPUCompilationInfo* = ref object of JsObject
    ## Shader compilation results

  GPUCompilationMessage* = ref object of JsObject
    ## Individual shader compilation message

  GPUSupportedLimits* = ref object of JsObject
    ## Device capability limits

  GPUError* = ref object of JsObject
    ## GPU error object
    message* {.importjs: "message".}: cstring

# ==============================================================================
# SECTION 2: GPU BUFFER USAGE FLAGS
# ==============================================================================

type
  GPUBufferUsageFlags* = distinct int
    ## Bitmask for GPUBuffer usage options

# GPUBufferUsage namespace object
var GPUBufferUsage* {.importjs: "GPUBufferUsage".}: JsObject
  ## GPUBufferUsage namespace containing usage flags

# GPUBufferUsage constants as variables
var gpuBufferUsageStorage* {.importjs: "GPUBufferUsage.STORAGE".}: int
  ## Buffer can be used as storage buffer in shaders

var gpuBufferUsageUniform* {.importjs: "GPUBufferUsage.UNIFORM".}: int
  ## Buffer can be used as uniform buffer in shaders

var gpuBufferUsageCopySrc* {.importjs: "GPUBufferUsage.COPY_SRC".}: int
  ## Buffer can be used as source for copy operations

var gpuBufferUsageCopyDst* {.importjs: "GPUBufferUsage.COPY_DST".}: int
  ## Buffer can be used as destination for copy operations

var gpuBufferUsageMapRead* {.importjs: "GPUBufferUsage.MAP_READ".}: int
  ## Buffer can be mapped for reading

var gpuBufferUsageMapWrite* {.importjs: "GPUBufferUsage.MAP_WRITE".}: int
  ## Buffer can be mapped for writing

var gpuBufferUsageVertex* {.importjs: "GPUBufferUsage.VERTEX".}: int
  ## Buffer can be used as vertex buffer

var gpuBufferUsageIndex* {.importjs: "GPUBufferUsage.INDEX".}: int
  ## Buffer can be used as index buffer

var gpuBufferUsageIndirect* {.importjs: "GPUBufferUsage.INDIRECT".}: int
  ## Buffer can be used for indirect draw/dispatch

var gpuBufferUsageQueryResolve* {.importjs: "GPUBufferUsage.QUERY_RESOLVE".}: int
  ## Buffer can be used for query resolve

# Bitwise operators for combining usage flags
proc `or`*(a, b: GPUBufferUsageFlags): GPUBufferUsageFlags {.importjs: "(# | #)".}
  ## Combine buffer usage flags

proc `and`*(a, b: GPUBufferUsageFlags): GPUBufferUsageFlags {.importjs: "(# & #)".}
  ## Intersect buffer usage flags

# Bitwise operators for int (common usage pattern)
proc bitwiseOr*(a, b: int): int {.importjs: "(# | #)".}
  ## Bitwise OR for integers (for combining buffer usage flags)

# ==============================================================================
# SECTION 3: GPU MAP MODE FLAGS
# ==============================================================================

type
  GPUMapModeFlags* = distinct int
    ## Flags for buffer mapping mode

var GPUMapMode* {.importjs: "GPUMapMode".}: JsObject
  ## GPUMapMode namespace containing map flags

# GPUMapMode constants as variables
var gpuMapModeRead* {.importjs: "GPUMapMode.READ".}: int
  ## Map buffer for reading

var gpuMapModeWrite* {.importjs: "GPUMapMode.WRITE".}: int
  ## Map buffer for writing

# ==============================================================================
# SECTION 4: NAVIGATOR.GPU ACCESS
# ==============================================================================

type
  Navigator* = ref object of JsObject
    gpu* {.importjs: "gpu".}: GPU

var navigator* {.importjs: "navigator".}: Navigator
  ## Browser navigator object with GPU access

proc hasWebGPU*(): bool {.importjs: "(typeof navigator !== 'undefined' && !!navigator.gpu)".}
  ## Check if WebGPU is available in the current environment

# ==============================================================================
# SECTION 5: GPU ADAPTER ACQUISITION
# ==============================================================================

type
  RequestAdapterOptions* = ref object of JsObject
    powerPreference* {.importjs: "powerPreference".}: cstring
    forceFallbackAdapter* {.importjs: "forceFallbackAdapter".}: bool

proc requestAdapter*(gpu: GPU): Future[GPUAdapter] {.importjs: "#.requestAdapter()".}
  ## Request a GPU adapter with default options

proc requestAdapter*(gpu: GPU, options: JsObject): Future[GPUAdapter] {.importjs: "#.requestAdapter(#)".}
  ## Request a GPU adapter with custom options

proc requestAdapterHighPerformance*(gpu: GPU): Future[GPUAdapter] {.importjs: "#.requestAdapter({powerPreference: 'high-performance'})".}
  ## Request a high-performance GPU adapter

proc requestAdapterLowPower*(gpu: GPU): Future[GPUAdapter] {.importjs: "#.requestAdapter({powerPreference: 'low-power'})".}
  ## Request a low-power GPU adapter

# ==============================================================================
# SECTION 6: GPU ADAPTER PROPERTIES
# ==============================================================================

proc info*(adapter: GPUAdapter): GPUAdapterInfo {.importjs: "#.info".}
  ## Get adapter information (may be undefined in some browsers)

proc limits*(adapter: GPUAdapter): GPUSupportedLimits {.importjs: "#.limits".}
  ## Get adapter limits

proc isFallbackAdapter*(adapter: GPUAdapter): bool {.importjs: "#.isFallbackAdapter".}
  ## Check if this is a fallback (software) adapter

# ==============================================================================
# SECTION 7: GPU DEVICE ACQUISITION
# ==============================================================================

type
  DeviceDescriptor* = ref object of JsObject
    requiredLimits* {.importjs: "requiredLimits".}: JsObject
    requiredFeatures* {.importjs: "requiredFeatures".}: JsObject
    label* {.importjs: "label".}: cstring

proc requestDevice*(adapter: GPUAdapter): Future[GPUDevice] {.importjs: "#.requestDevice()".}
  ## Request a GPU device with default limits

proc requestDevice*(adapter: GPUAdapter, descriptor: JsObject): Future[GPUDevice] {.importjs: "#.requestDevice(#)".}
  ## Request a GPU device with custom descriptor

# ==============================================================================
# SECTION 8: GPU DEVICE PROPERTIES
# ==============================================================================

proc queue*(device: GPUDevice): GPUQueue {.importjs: "#.queue".}
  ## Get the device's command queue

proc limits*(device: GPUDevice): GPUSupportedLimits {.importjs: "#.limits".}
  ## Get the device's actual limits

proc lost*(device: GPUDevice): Future[JsObject] {.importjs: "#.lost".}
  ## Promise that resolves when the device is lost

proc label*(device: GPUDevice): cstring {.importjs: "#.label".}
  ## Get the device's debug label

proc `label=`*(device: GPUDevice, value: cstring) {.importjs: "#.label = #".}
  ## Set the device's debug label

proc destroy*(device: GPUDevice) {.importjs: "#.destroy()".}
  ## Destroy the device and release resources

# ==============================================================================
# SECTION 9: GPU DEVICE - BUFFER CREATION
# ==============================================================================

proc createBuffer*(device: GPUDevice, descriptor: JsObject): GPUBuffer {.importjs: "#.createBuffer(#)".}
  ## Create a GPU buffer with the given descriptor
  ##
  ## Descriptor fields:
  ##   size: int - Buffer size in bytes
  ##   usage: int - GPUBufferUsage flags combined with bitwise OR
  ##   mappedAtCreation: bool - Optional, if true buffer starts mapped
  ##   label: cstring - Optional debug label

proc createBufferSimple*(device: GPUDevice, size: int, usage: int): GPUBuffer {.importjs: "#.createBuffer({size: #, usage: #})".}
  ## Create a GPU buffer with size and usage (convenience)

proc createBufferLabeled*(device: GPUDevice, size: int, usage: int, label: cstring): GPUBuffer {.importjs: "#.createBuffer({size: #, usage: #, label: #})".}
  ## Create a labeled GPU buffer (convenience)

proc createBufferMapped*(device: GPUDevice, size: int, usage: int): GPUBuffer {.importjs: "#.createBuffer({size: #, usage: #, mappedAtCreation: true})".}
  ## Create a GPU buffer that starts in mapped state

# ==============================================================================
# SECTION 10: GPU DEVICE - SHADER MODULE CREATION
# ==============================================================================

proc createShaderModule*(device: GPUDevice, descriptor: JsObject): GPUShaderModule {.importjs: "#.createShaderModule(#)".}
  ## Create a shader module from WGSL code
  ##
  ## Descriptor fields:
  ##   code: cstring - WGSL shader source code
  ##   label: cstring - Optional debug label

proc createShaderModuleCode*(device: GPUDevice, code: cstring): GPUShaderModule {.importjs: "#.createShaderModule({code: #})".}
  ## Create a shader module from WGSL code (convenience)

proc createShaderModuleLabeled*(device: GPUDevice, code: cstring, label: cstring): GPUShaderModule {.importjs: "#.createShaderModule({code: #, label: #})".}
  ## Create a labeled shader module (convenience)

# ==============================================================================
# SECTION 11: GPU SHADER MODULE - COMPILATION INFO
# ==============================================================================

proc getCompilationInfo*(shaderModule: GPUShaderModule): Future[GPUCompilationInfo] {.importjs: "#.getCompilationInfo()".}
  ## Get shader compilation messages (errors, warnings)

proc messages*(info: GPUCompilationInfo): JsObject {.importjs: "#.messages".}
  ## Get array of compilation messages

proc length*(info: GPUCompilationInfo): int {.importjs: "#.messages.length".}
  ## Get number of compilation messages

# Compilation message accessors
proc messageType*(msg: GPUCompilationMessage): cstring {.importjs: "#.type".}
  ## Message type: "error", "warning", or "info"

proc message*(msg: GPUCompilationMessage): cstring {.importjs: "#.message".}
  ## Message text

proc lineNum*(msg: GPUCompilationMessage): int {.importjs: "#.lineNum".}
  ## Line number in shader source

proc linePos*(msg: GPUCompilationMessage): int {.importjs: "#.linePos".}
  ## Column position in line

proc offset*(msg: GPUCompilationMessage): int {.importjs: "#.offset".}
  ## Character offset in shader source

# ==============================================================================
# SECTION 12: GPU DEVICE - COMPUTE PIPELINE CREATION
# ==============================================================================

proc createComputePipeline*(device: GPUDevice, descriptor: JsObject): GPUComputePipeline {.importjs: "#.createComputePipeline(#)".}
  ## Create a compute pipeline
  ##
  ## Descriptor fields:
  ##   layout: GPUPipelineLayout or "auto"
  ##   compute: { module: GPUShaderModule, entryPoint: cstring }
  ##   label: cstring - Optional debug label

proc createComputePipelineAsync*(device: GPUDevice, descriptor: JsObject): Future[GPUComputePipeline] {.importjs: "#.createComputePipelineAsync(#)".}
  ## Create a compute pipeline asynchronously

proc createComputePipelineAuto*(device: GPUDevice, shaderModule: GPUShaderModule, entryPoint: cstring): GPUComputePipeline {.importjs: "#.createComputePipeline({layout: 'auto', compute: {module: #, entryPoint: #}})".}
  ## Create a compute pipeline with auto layout (convenience)

proc createComputePipelineAutoLabeled*(device: GPUDevice, shaderModule: GPUShaderModule, entryPoint: cstring, label: cstring): GPUComputePipeline {.importjs: "#.createComputePipeline({layout: 'auto', compute: {module: #, entryPoint: #}, label: #})".}
  ## Create a labeled compute pipeline with auto layout (convenience)

# ==============================================================================
# SECTION 13: GPU COMPUTE PIPELINE - BIND GROUP LAYOUT
# ==============================================================================

proc getBindGroupLayout*(pipeline: GPUComputePipeline, index: int): GPUBindGroupLayout {.importjs: "#.getBindGroupLayout(#)".}
  ## Get the bind group layout at the given index

# ==============================================================================
# SECTION 14: GPU DEVICE - BIND GROUP CREATION
# ==============================================================================

proc createBindGroup*(device: GPUDevice, descriptor: JsObject): GPUBindGroup {.importjs: "#.createBindGroup(#)".}
  ## Create a bind group
  ##
  ## Descriptor fields:
  ##   layout: GPUBindGroupLayout
  ##   entries: array of { binding: int, resource: { buffer: GPUBuffer } }
  ##   label: cstring - Optional debug label

proc createBindGroupLayout*(device: GPUDevice, descriptor: JsObject): GPUBindGroupLayout {.importjs: "#.createBindGroupLayout(#)".}
  ## Create a bind group layout

proc createPipelineLayout*(device: GPUDevice, descriptor: JsObject): GPUPipelineLayout {.importjs: "#.createPipelineLayout(#)".}
  ## Create a pipeline layout from bind group layouts

# ==============================================================================
# SECTION 15: GPU DEVICE - COMMAND ENCODER CREATION
# ==============================================================================

proc createCommandEncoder*(device: GPUDevice): GPUCommandEncoder {.importjs: "#.createCommandEncoder()".}
  ## Create a command encoder with default options

proc createCommandEncoder*(device: GPUDevice, descriptor: JsObject): GPUCommandEncoder {.importjs: "#.createCommandEncoder(#)".}
  ## Create a command encoder with descriptor

proc createCommandEncoderLabeled*(device: GPUDevice, label: cstring): GPUCommandEncoder {.importjs: "#.createCommandEncoder({label: #})".}
  ## Create a labeled command encoder (convenience)

# ==============================================================================
# SECTION 16: GPU DEVICE - ERROR HANDLING
# ==============================================================================

proc pushErrorScope*(device: GPUDevice, filter: cstring) {.importjs: "#.pushErrorScope(#)".}
  ## Push an error scope with filter: "validation", "out-of-memory", or "internal"

proc popErrorScope*(device: GPUDevice): Future[GPUError] {.importjs: "#.popErrorScope()".}
  ## Pop error scope and get any captured error

proc addEventListener*(device: GPUDevice, eventType: cstring, handler: proc(event: JsObject)) {.importjs: "#.addEventListener(#, #)".}
  ## Add event listener (e.g., "uncapturederror")

# ==============================================================================
# SECTION 17: GPU QUEUE - BUFFER WRITES
# ==============================================================================

proc writeBuffer*(queue: GPUQueue, buffer: GPUBuffer, bufferOffset: int, data: JsObject) {.importjs: "#.writeBuffer(#, #, #)".}
  ## Write data to a buffer at offset
  ##
  ## Data can be ArrayBuffer, TypedArray, or DataView

proc writeBuffer*(queue: GPUQueue, buffer: GPUBuffer, bufferOffset: int, data: JsObject, dataOffset: int, size: int) {.importjs: "#.writeBuffer(#, #, #, #, #)".}
  ## Write data to a buffer with data offset and size

proc writeBufferTyped*(queue: GPUQueue, buffer: GPUBuffer, bufferOffset: int, data: Float32Array) {.importjs: "#.writeBuffer(#, #, #)".}
  ## Write Float32Array to buffer

proc writeBufferTyped*(queue: GPUQueue, buffer: GPUBuffer, bufferOffset: int, data: Uint32Array) {.importjs: "#.writeBuffer(#, #, #)".}
  ## Write Uint32Array to buffer

proc writeBufferTyped*(queue: GPUQueue, buffer: GPUBuffer, bufferOffset: int, data: Uint8Array) {.importjs: "#.writeBuffer(#, #, #)".}
  ## Write Uint8Array to buffer

proc writeBufferFromView*(queue: GPUQueue, buffer: GPUBuffer, bufferOffset: int, srcBuffer: JsObject, srcByteOffset: int, byteLength: int) {.importjs: "#.writeBuffer(#, #, #, #, #)".}
  ## Write from source buffer view to GPU buffer

# ==============================================================================
# SECTION 18: GPU QUEUE - COMMAND SUBMISSION
# ==============================================================================

proc submit*(queue: GPUQueue, commandBuffers: JsObject) {.importjs: "#.submit(#)".}
  ## Submit command buffers for execution

proc submitOne*(queue: GPUQueue, commandBuffer: GPUCommandBuffer) {.importjs: "#.submit([#])".}
  ## Submit a single command buffer (convenience)

proc onSubmittedWorkDone*(queue: GPUQueue): Future[void] {.importjs: "#.onSubmittedWorkDone()".}
  ## Return a promise that resolves when submitted work completes

# ==============================================================================
# SECTION 19: GPU BUFFER - PROPERTIES
# ==============================================================================

proc size*(buffer: GPUBuffer): int {.importjs: "#.size".}
  ## Get buffer size in bytes

proc usage*(buffer: GPUBuffer): int {.importjs: "#.usage".}
  ## Get buffer usage flags

proc mapState*(buffer: GPUBuffer): cstring {.importjs: "#.mapState".}
  ## Get mapping state: "unmapped", "pending", or "mapped"

proc label*(buffer: GPUBuffer): cstring {.importjs: "#.label".}
  ## Get buffer debug label

proc `label=`*(buffer: GPUBuffer, value: cstring) {.importjs: "#.label = #".}
  ## Set buffer debug label

# ==============================================================================
# SECTION 20: GPU BUFFER - MAPPING
# ==============================================================================

proc mapAsync*(buffer: GPUBuffer, mode: int): Future[void] {.importjs: "#.mapAsync(#)".}
  ## Map buffer for read or write access
  ##
  ## Mode: GPUMapMode.READ or GPUMapMode.WRITE

proc mapAsync*(buffer: GPUBuffer, mode: int, offset: int, size: int): Future[void] {.importjs: "#.mapAsync(#, #, #)".}
  ## Map buffer with offset and size

proc mapAsyncRead*(buffer: GPUBuffer): Future[void] {.importjs: "#.mapAsync(GPUMapMode.READ)".}
  ## Map buffer for reading (convenience)

proc mapAsyncWrite*(buffer: GPUBuffer): Future[void] {.importjs: "#.mapAsync(GPUMapMode.WRITE)".}
  ## Map buffer for writing (convenience)

proc getMappedRange*(buffer: GPUBuffer): JsObject {.importjs: "#.getMappedRange()".}
  ## Get ArrayBuffer view of entire mapped range

proc getMappedRange*(buffer: GPUBuffer, offset: int): JsObject {.importjs: "#.getMappedRange(#)".}
  ## Get ArrayBuffer view from offset to end

proc getMappedRange*(buffer: GPUBuffer, offset: int, size: int): JsObject {.importjs: "#.getMappedRange(#, #)".}
  ## Get ArrayBuffer view of specified range

proc unmap*(buffer: GPUBuffer) {.importjs: "#.unmap()".}
  ## Unmap the buffer

# ==============================================================================
# SECTION 21: GPU BUFFER - DESTRUCTION
# ==============================================================================

proc destroy*(buffer: GPUBuffer) {.importjs: "#.destroy()".}
  ## Destroy the buffer and release GPU memory

# ==============================================================================
# SECTION 22: GPU COMMAND ENCODER - COMPUTE PASS
# ==============================================================================

proc beginComputePass*(encoder: GPUCommandEncoder): GPUComputePassEncoder {.importjs: "#.beginComputePass()".}
  ## Begin a compute pass with default options

proc beginComputePass*(encoder: GPUCommandEncoder, descriptor: JsObject): GPUComputePassEncoder {.importjs: "#.beginComputePass(#)".}
  ## Begin a compute pass with descriptor

proc beginComputePassLabeled*(encoder: GPUCommandEncoder, label: cstring): GPUComputePassEncoder {.importjs: "#.beginComputePass({label: #})".}
  ## Begin a labeled compute pass (convenience)

# ==============================================================================
# SECTION 23: GPU COMMAND ENCODER - BUFFER OPERATIONS
# ==============================================================================

proc clearBuffer*(encoder: GPUCommandEncoder, buffer: GPUBuffer) {.importjs: "#.clearBuffer(#)".}
  ## Clear entire buffer to zeros

proc clearBuffer*(encoder: GPUCommandEncoder, buffer: GPUBuffer, offset: int, size: int) {.importjs: "#.clearBuffer(#, #, #)".}
  ## Clear buffer range to zeros

proc copyBufferToBuffer*(encoder: GPUCommandEncoder, source: GPUBuffer, sourceOffset: int, destination: GPUBuffer, destinationOffset: int, size: int) {.importjs: "#.copyBufferToBuffer(#, #, #, #, #)".}
  ## Copy data between buffers

# ==============================================================================
# SECTION 24: GPU COMMAND ENCODER - FINISH
# ==============================================================================

proc finish*(encoder: GPUCommandEncoder): GPUCommandBuffer {.importjs: "#.finish()".}
  ## Finish encoding and return command buffer

proc finish*(encoder: GPUCommandEncoder, descriptor: JsObject): GPUCommandBuffer {.importjs: "#.finish(#)".}
  ## Finish with descriptor

# ==============================================================================
# SECTION 25: GPU COMPUTE PASS ENCODER - PIPELINE AND BIND GROUPS
# ==============================================================================

proc setPipeline*(pass: GPUComputePassEncoder, pipeline: GPUComputePipeline) {.importjs: "#.setPipeline(#)".}
  ## Set the compute pipeline for this pass

proc setBindGroup*(pass: GPUComputePassEncoder, index: int, bindGroup: GPUBindGroup) {.importjs: "#.setBindGroup(#, #)".}
  ## Set bind group at the given index

proc setBindGroup*(pass: GPUComputePassEncoder, index: int, bindGroup: GPUBindGroup, dynamicOffsets: JsObject) {.importjs: "#.setBindGroup(#, #, #)".}
  ## Set bind group with dynamic offsets

# ==============================================================================
# SECTION 26: GPU COMPUTE PASS ENCODER - DISPATCH
# ==============================================================================

proc dispatchWorkgroups*(pass: GPUComputePassEncoder, workgroupCountX: int) {.importjs: "#.dispatchWorkgroups(#)".}
  ## Dispatch compute workgroups (1D)

proc dispatchWorkgroups*(pass: GPUComputePassEncoder, workgroupCountX: int, workgroupCountY: int) {.importjs: "#.dispatchWorkgroups(#, #)".}
  ## Dispatch compute workgroups (2D)

proc dispatchWorkgroups*(pass: GPUComputePassEncoder, workgroupCountX: int, workgroupCountY: int, workgroupCountZ: int) {.importjs: "#.dispatchWorkgroups(#, #, #)".}
  ## Dispatch compute workgroups (3D)

proc dispatchWorkgroupsIndirect*(pass: GPUComputePassEncoder, indirectBuffer: GPUBuffer, indirectOffset: int) {.importjs: "#.dispatchWorkgroupsIndirect(#, #)".}
  ## Dispatch workgroups using indirect buffer

# ==============================================================================
# SECTION 27: GPU COMPUTE PASS ENCODER - END
# ==============================================================================

proc `end`*(pass: GPUComputePassEncoder) {.importjs: "#.end()".}
  ## End the compute pass

proc endPass*(pass: GPUComputePassEncoder) {.importjs: "#.end()".}
  ## End the compute pass (alias for end)

# ==============================================================================
# SECTION 28: GPU SUPPORTED LIMITS PROPERTIES
# ==============================================================================

proc maxBufferSize*(limits: GPUSupportedLimits): int {.importjs: "#.maxBufferSize".}
  ## Maximum buffer size

proc maxStorageBufferBindingSize*(limits: GPUSupportedLimits): int {.importjs: "#.maxStorageBufferBindingSize".}
  ## Maximum storage buffer binding size

proc maxComputeWorkgroupSizeX*(limits: GPUSupportedLimits): int {.importjs: "#.maxComputeWorkgroupSizeX".}
  ## Maximum compute workgroup size in X dimension

proc maxComputeWorkgroupSizeY*(limits: GPUSupportedLimits): int {.importjs: "#.maxComputeWorkgroupSizeY".}
  ## Maximum compute workgroup size in Y dimension

proc maxComputeWorkgroupSizeZ*(limits: GPUSupportedLimits): int {.importjs: "#.maxComputeWorkgroupSizeZ".}
  ## Maximum compute workgroup size in Z dimension

proc maxComputeWorkgroupsPerDimension*(limits: GPUSupportedLimits): int {.importjs: "#.maxComputeWorkgroupsPerDimension".}
  ## Maximum workgroups per dimension

proc maxComputeInvocationsPerWorkgroup*(limits: GPUSupportedLimits): int {.importjs: "#.maxComputeInvocationsPerWorkgroup".}
  ## Maximum invocations per workgroup

proc maxBindGroups*(limits: GPUSupportedLimits): int {.importjs: "#.maxBindGroups".}
  ## Maximum bind groups

proc maxStorageBuffersPerShaderStage*(limits: GPUSupportedLimits): int {.importjs: "#.maxStorageBuffersPerShaderStage".}
  ## Maximum storage buffers per shader stage

proc maxUniformBuffersPerShaderStage*(limits: GPUSupportedLimits): int {.importjs: "#.maxUniformBuffersPerShaderStage".}
  ## Maximum uniform buffers per shader stage

# ==============================================================================
# SECTION 29: UTILITY HELPERS
# ==============================================================================

proc isWebGPUAvailable*(): bool =
  ## Check if WebGPU is available
  hasWebGPU()

proc createBindGroupEntry*(binding: int, buffer: GPUBuffer): JsObject {.importjs: "({binding: #, resource: {buffer: #}})".}
  ## Create a bind group entry for a buffer (convenience)

proc createBindGroupEntryOffset*(binding: int, buffer: GPUBuffer, offset: int, size: int): JsObject {.importjs: "({binding: #, resource: {buffer: #, offset: #, size: #}})".}
  ## Create a bind group entry with offset and size

# ==============================================================================
# SECTION 30: TYPE ALIASES FOR BACKWARDS COMPATIBILITY
# ==============================================================================

type
  # These match the types used in webgpu_init.nim and webgpu_compute.nim
  GPUBuffersObject* = ref object of JsObject
    ## Collection of GPU buffers (matches webgpu_init.nim)

  InitResult* = ref object of JsObject
    ## Initialization result type
    success* {.importjs: "success".}: bool
    error* {.importjs: "error".}: cstring
    info* {.importjs: "info".}: JsObject

  PhysicsFrameParams* = ref object of JsObject
    ## Physics frame parameters
    dt* {.importjs: "dt".}: float
    particleCount* {.importjs: "particleCount".}: int
    width* {.importjs: "width".}: float
    height* {.importjs: "height".}: float
    gridW* {.importjs: "gridW".}: int
    gridH* {.importjs: "gridH".}: int
    rMax* {.importjs: "rMax".}: float
    fMul* {.importjs: "fMul".}: float
    friction* {.importjs: "friction".}: float
    mouseX* {.importjs: "mouseX".}: float
    mouseY* {.importjs: "mouseY".}: float
    mouseDown* {.importjs: "mouseDown".}: int
    parity* {.importjs: "parity".}: int
    matrix* {.importjs: "matrix".}: JsObject

# Alias GPUBuffer to JsObject for flexibility in existing code
# This allows existing code using JsObject for buffers to continue working
converter toJsObject*(buffer: GPUBuffer): JsObject = cast[JsObject](buffer)
converter toGPUBuffer*(obj: JsObject): GPUBuffer = cast[GPUBuffer](obj)

# ==============================================================================
# SECTION 24: WEBGPU CANVAS CONTEXT
# ==============================================================================

type
  GPUCanvasContext* = ref object of JsObject
    ## WebGPU canvas context for rendering

  GPUTexture* = ref object of JsObject
    ## GPU texture resource

  GPUTextureView* = ref object of JsObject
    ## View into a GPU texture

  GPURenderPipeline* = ref object of JsObject
    ## Render pipeline for graphics operations

  GPURenderPassEncoder* = ref object of JsObject
    ## Encoder for render pass commands

proc getContextWebGPU*(canvas: JsObject): GPUCanvasContext {.importjs: "#.getContext('webgpu')".}
  ## Get WebGPU context from canvas

proc configure*(context: GPUCanvasContext, config: JsObject) {.importjs: "#.configure(#)".}
  ## Configure the canvas context

proc getCurrentTexture*(context: GPUCanvasContext): GPUTexture {.importjs: "#.getCurrentTexture()".}
  ## Get the current texture to render to

proc createView*(texture: GPUTexture): GPUTextureView {.importjs: "#.createView()".}
  ## Create a view of the texture

proc getPreferredCanvasFormat*(): cstring {.importjs: "navigator.gpu.getPreferredCanvasFormat()".}
  ## Get the preferred canvas format for the current GPU

# ==============================================================================
# SECTION 25: RENDER PIPELINE
# ==============================================================================

proc createRenderPipeline*(device: GPUDevice, descriptor: JsObject): GPURenderPipeline {.importjs: "#.createRenderPipeline(#)".}
  ## Create a render pipeline

proc getBindGroupLayout*(pipeline: GPURenderPipeline, index: int): GPUBindGroupLayout {.importjs: "#.getBindGroupLayout(#)".}
  ## Get the bind group layout at the given index

# ==============================================================================
# SECTION 26: RENDER PASS
# ==============================================================================

proc beginRenderPass*(encoder: GPUCommandEncoder, descriptor: JsObject): GPURenderPassEncoder {.importjs: "#.beginRenderPass(#)".}
  ## Begin a render pass

proc setPipeline*(pass: GPURenderPassEncoder, pipeline: GPURenderPipeline) {.importjs: "#.setPipeline(#)".}
  ## Set the render pipeline

proc setBindGroup*(pass: GPURenderPassEncoder, index: int, bindGroup: GPUBindGroup) {.importjs: "#.setBindGroup(#, #)".}
  ## Set a bind group for the render pass

proc draw*(pass: GPURenderPassEncoder, vertexCount: int, instanceCount: int, firstVertex: int, firstInstance: int) {.importjs: "#.draw(#, #, #, #)".}
  ## Draw primitives

proc endPass*(pass: GPURenderPassEncoder) {.importjs: "#.end()".}
  ## End the render pass

# ==============================================================================
# SECTION 27: SHADER STAGE FLAGS
# ==============================================================================

var gpuShaderStageVertex* {.importjs: "GPUShaderStage.VERTEX", nodecl.}: int
  ## Vertex shader stage flag

var gpuShaderStageFragment* {.importjs: "GPUShaderStage.FRAGMENT", nodecl.}: int
  ## Fragment shader stage flag
