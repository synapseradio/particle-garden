# ==============================================================================
# PARTICLE GARDEN - WEBGPU BINDINGS
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

  GPUAdapter* = ref object of JsObject

  GPUAdapterInfo* = ref object of JsObject

  GPUDevice* = ref object of JsObject

  GPUQueue* = ref object of JsObject

  GPUBuffer* = ref object of JsObject

  GPUShaderModule* = ref object of JsObject

  GPUComputePipeline* = ref object of JsObject

  GPUBindGroup* = ref object of JsObject

  GPUBindGroupLayout* = ref object of JsObject

  GPUPipelineLayout* = ref object of JsObject

  GPUCommandEncoder* = ref object of JsObject

  GPUComputePassEncoder* = ref object of JsObject

  GPUCommandBuffer* = ref object of JsObject

  GPUQuerySet* = ref object of JsObject

  GPUCompilationInfo* = ref object of JsObject

  GPUCompilationMessage* = ref object of JsObject

  GPUSupportedLimits* = ref object of JsObject

  GPUError* = ref object of JsObject
    message* {.importjs: "message".}: cstring

# ==============================================================================
# SECTION 2: GPU BUFFER USAGE FLAGS
# ==============================================================================

type
  GPUBufferUsageFlags* = distinct int

# GPUBufferUsage namespace object
var GPUBufferUsage* {.importjs: "GPUBufferUsage".}: JsObject

# GPUBufferUsage constants as variables
var gpuBufferUsageStorage* {.importjs: "GPUBufferUsage.STORAGE".}: int

var gpuBufferUsageUniform* {.importjs: "GPUBufferUsage.UNIFORM".}: int

var gpuBufferUsageCopySrc* {.importjs: "GPUBufferUsage.COPY_SRC".}: int

var gpuBufferUsageCopyDst* {.importjs: "GPUBufferUsage.COPY_DST".}: int

var gpuBufferUsageMapRead* {.importjs: "GPUBufferUsage.MAP_READ".}: int

var gpuBufferUsageMapWrite* {.importjs: "GPUBufferUsage.MAP_WRITE".}: int

var gpuBufferUsageVertex* {.importjs: "GPUBufferUsage.VERTEX".}: int

var gpuBufferUsageIndex* {.importjs: "GPUBufferUsage.INDEX".}: int

var gpuBufferUsageIndirect* {.importjs: "GPUBufferUsage.INDIRECT".}: int

var gpuBufferUsageQueryResolve* {.importjs: "GPUBufferUsage.QUERY_RESOLVE".}: int

# Bitwise operators for combining usage flags
proc `or`*(a, b: GPUBufferUsageFlags): GPUBufferUsageFlags {.importjs: "(# | #)".}

proc `and`*(a, b: GPUBufferUsageFlags): GPUBufferUsageFlags {.importjs: "(# & #)".}

# Bitwise operators for int (common usage pattern)
proc bitwiseOr*(a, b: int): int {.importjs: "(# | #)".}

# ==============================================================================
# SECTION 2B: GPU TEXTURE USAGE FLAGS
# ==============================================================================

var gpuTextureUsageCopySrc* {.importjs: "GPUTextureUsage.COPY_SRC".}: int

var gpuTextureUsageCopyDst* {.importjs: "GPUTextureUsage.COPY_DST".}: int

var gpuTextureUsageTextureBinding* {.importjs: "GPUTextureUsage.TEXTURE_BINDING".}: int

var gpuTextureUsageStorageBinding* {.importjs: "GPUTextureUsage.STORAGE_BINDING".}: int

var gpuTextureUsageRenderAttachment* {.importjs: "GPUTextureUsage.RENDER_ATTACHMENT".}: int

# ==============================================================================
# SECTION 3: GPU MAP MODE FLAGS
# ==============================================================================

type
  GPUMapModeFlags* = distinct int

var GPUMapMode* {.importjs: "GPUMapMode".}: JsObject

# GPUMapMode constants as variables
var gpuMapModeRead* {.importjs: "GPUMapMode.READ".}: int

var gpuMapModeWrite* {.importjs: "GPUMapMode.WRITE".}: int

# ==============================================================================
# SECTION 4: NAVIGATOR.GPU ACCESS
# ==============================================================================

type
  Navigator* = ref object of JsObject
    gpu* {.importjs: "gpu".}: GPU

var navigator* {.importjs: "navigator".}: Navigator

proc hasWebGPU*(): bool {.importjs: "(typeof navigator !== 'undefined' && !!navigator.gpu)".}

# ==============================================================================
# SECTION 5: GPU ADAPTER ACQUISITION
# ==============================================================================

type
  RequestAdapterOptions* = ref object of JsObject
    powerPreference* {.importjs: "powerPreference".}: cstring
    forceFallbackAdapter* {.importjs: "forceFallbackAdapter".}: bool

proc requestAdapter*(gpu: GPU): Future[GPUAdapter] {.importjs: "#.requestAdapter()".}

proc requestAdapter*(gpu: GPU, options: JsObject): Future[GPUAdapter] {.importjs: "#.requestAdapter(#)".}

proc requestAdapterHighPerformance*(gpu: GPU): Future[GPUAdapter] {.importjs: "#.requestAdapter({powerPreference: 'high-performance'})".}

proc requestAdapterLowPower*(gpu: GPU): Future[GPUAdapter] {.importjs: "#.requestAdapter({powerPreference: 'low-power'})".}

# ==============================================================================
# SECTION 6: GPU ADAPTER PROPERTIES
# ==============================================================================

proc info*(adapter: GPUAdapter): GPUAdapterInfo {.importjs: "#.info".}

proc limits*(adapter: GPUAdapter): GPUSupportedLimits {.importjs: "#.limits".}

proc isFallbackAdapter*(adapter: GPUAdapter): bool {.importjs: "#.isFallbackAdapter".}

proc hasFeature*(adapter: GPUAdapter, name: cstring): bool {.importjs: "#.features.has(#)".}
  ## Check whether the adapter supports an optional feature (e.g. "timestamp-query")

# ==============================================================================
# SECTION 7: GPU DEVICE ACQUISITION
# ==============================================================================

type
  DeviceDescriptor* = ref object of JsObject
    requiredLimits* {.importjs: "requiredLimits".}: JsObject
    requiredFeatures* {.importjs: "requiredFeatures".}: JsObject
    label* {.importjs: "label".}: cstring

proc requestDevice*(adapter: GPUAdapter): Future[GPUDevice] {.importjs: "#.requestDevice()".}

proc requestDevice*(adapter: GPUAdapter, descriptor: JsObject): Future[GPUDevice] {.importjs: "#.requestDevice(#)".}

# ==============================================================================
# SECTION 8: GPU DEVICE PROPERTIES
# ==============================================================================

proc queue*(device: GPUDevice): GPUQueue {.importjs: "#.queue".}

proc limits*(device: GPUDevice): GPUSupportedLimits {.importjs: "#.limits".}

proc lost*(device: GPUDevice): Future[JsObject] {.importjs: "#.lost".}

proc label*(device: GPUDevice): cstring {.importjs: "#.label".}

proc `label=`*(device: GPUDevice, value: cstring) {.importjs: "#.label = #".}

proc destroy*(device: GPUDevice) {.importjs: "#.destroy()".}

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

proc createBufferLabeled*(device: GPUDevice, size: int, usage: int, label: cstring): GPUBuffer {.importjs: "#.createBuffer({size: #, usage: #, label: #})".}

proc createBufferMapped*(device: GPUDevice, size: int, usage: int): GPUBuffer {.importjs: "#.createBuffer({size: #, usage: #, mappedAtCreation: true})".}

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

proc createShaderModuleLabeled*(device: GPUDevice, code: cstring, label: cstring): GPUShaderModule {.importjs: "#.createShaderModule({code: #, label: #})".}

# ==============================================================================
# SECTION 11: GPU SHADER MODULE - COMPILATION INFO
# ==============================================================================

proc getCompilationInfo*(shaderModule: GPUShaderModule): Future[GPUCompilationInfo] {.importjs: "#.getCompilationInfo()".}

proc messages*(info: GPUCompilationInfo): JsObject {.importjs: "#.messages".}

proc length*(info: GPUCompilationInfo): int {.importjs: "#.messages.length".}

# Compilation message accessors
proc messageType*(msg: GPUCompilationMessage): cstring {.importjs: "#.type".}

proc message*(msg: GPUCompilationMessage): cstring {.importjs: "#.message".}

proc lineNum*(msg: GPUCompilationMessage): int {.importjs: "#.lineNum".}

proc linePos*(msg: GPUCompilationMessage): int {.importjs: "#.linePos".}

proc offset*(msg: GPUCompilationMessage): int {.importjs: "#.offset".}

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

proc createComputePipelineAuto*(device: GPUDevice, shaderModule: GPUShaderModule, entryPoint: cstring): GPUComputePipeline {.importjs: "#.createComputePipeline({layout: 'auto', compute: {module: #, entryPoint: #}})".}

proc createComputePipelineAutoLabeled*(device: GPUDevice, shaderModule: GPUShaderModule, entryPoint: cstring, label: cstring): GPUComputePipeline {.importjs: "#.createComputePipeline({layout: 'auto', compute: {module: #, entryPoint: #}, label: #})".}

# ==============================================================================
# SECTION 13: GPU COMPUTE PIPELINE - BIND GROUP LAYOUT
# ==============================================================================

proc getBindGroupLayout*(pipeline: GPUComputePipeline, index: int): GPUBindGroupLayout {.importjs: "#.getBindGroupLayout(#)".}

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

proc createPipelineLayout*(device: GPUDevice, descriptor: JsObject): GPUPipelineLayout {.importjs: "#.createPipelineLayout(#)".}

# ==============================================================================
# SECTION 15: GPU DEVICE - COMMAND ENCODER CREATION
# ==============================================================================

proc createCommandEncoder*(device: GPUDevice): GPUCommandEncoder {.importjs: "#.createCommandEncoder()".}

proc createCommandEncoder*(device: GPUDevice, descriptor: JsObject): GPUCommandEncoder {.importjs: "#.createCommandEncoder(#)".}

proc createCommandEncoderLabeled*(device: GPUDevice, label: cstring): GPUCommandEncoder {.importjs: "#.createCommandEncoder({label: #})".}

# ==============================================================================
# SECTION 16: GPU DEVICE - ERROR HANDLING
# ==============================================================================

proc pushErrorScope*(device: GPUDevice, filter: cstring) {.importjs: "#.pushErrorScope(#)".}
  ## filter: "validation", "out-of-memory", or "internal"

proc popErrorScope*(device: GPUDevice): Future[GPUError] {.importjs: "#.popErrorScope()".}

proc addEventListener*(device: GPUDevice, eventType: cstring, handler: proc(event: JsObject)) {.importjs: "#.addEventListener(#, #)".}

# ==============================================================================
# SECTION 17: GPU QUEUE - BUFFER WRITES
# ==============================================================================

proc writeBuffer*(queue: GPUQueue, buffer: GPUBuffer, bufferOffset: int, data: JsObject) {.importjs: "#.writeBuffer(#, #, #)".}
  ## data: ArrayBuffer, TypedArray, or DataView

proc writeBuffer*(queue: GPUQueue, buffer: GPUBuffer, bufferOffset: int, data: JsObject, dataOffset: int, size: int) {.importjs: "#.writeBuffer(#, #, #, #, #)".}

proc writeBufferTyped*(queue: GPUQueue, buffer: GPUBuffer, bufferOffset: int, data: Float32Array) {.importjs: "#.writeBuffer(#, #, #)".}

proc writeBufferTyped*(queue: GPUQueue, buffer: GPUBuffer, bufferOffset: int, data: Uint32Array) {.importjs: "#.writeBuffer(#, #, #)".}

proc writeBufferTyped*(queue: GPUQueue, buffer: GPUBuffer, bufferOffset: int, data: Uint8Array) {.importjs: "#.writeBuffer(#, #, #)".}

proc writeBufferFromView*(queue: GPUQueue, buffer: GPUBuffer, bufferOffset: int, srcBuffer: JsObject, srcByteOffset: int, byteLength: int) {.importjs: "#.writeBuffer(#, #, #, #, #)".}

# ==============================================================================
# SECTION 18: GPU QUEUE - COMMAND SUBMISSION
# ==============================================================================

proc submit*(queue: GPUQueue, commandBuffers: JsObject) {.importjs: "#.submit(#)".}

proc submitOne*(queue: GPUQueue, commandBuffer: GPUCommandBuffer) {.importjs: "#.submit([#])".}

proc onSubmittedWorkDone*(queue: GPUQueue): Future[void] {.importjs: "#.onSubmittedWorkDone()".}

# ==============================================================================
# SECTION 19: GPU BUFFER - PROPERTIES
# ==============================================================================

proc size*(buffer: GPUBuffer): int {.importjs: "#.size".}

proc usage*(buffer: GPUBuffer): int {.importjs: "#.usage".}

proc mapState*(buffer: GPUBuffer): cstring {.importjs: "#.mapState".}
  ## Values: "unmapped", "pending", or "mapped"

proc label*(buffer: GPUBuffer): cstring {.importjs: "#.label".}

proc `label=`*(buffer: GPUBuffer, value: cstring) {.importjs: "#.label = #".}

# ==============================================================================
# SECTION 20: GPU BUFFER - MAPPING
# ==============================================================================

proc mapAsync*(buffer: GPUBuffer, mode: int): Future[void] {.importjs: "#.mapAsync(#)".}
  ## mode: GPUMapMode.READ or GPUMapMode.WRITE

proc mapAsync*(buffer: GPUBuffer, mode: int, offset: int, size: int): Future[void] {.importjs: "#.mapAsync(#, #, #)".}

proc mapAsyncRead*(buffer: GPUBuffer): Future[void] {.importjs: "#.mapAsync(GPUMapMode.READ)".}

proc mapAsyncWrite*(buffer: GPUBuffer): Future[void] {.importjs: "#.mapAsync(GPUMapMode.WRITE)".}

proc getMappedRange*(buffer: GPUBuffer): JsObject {.importjs: "#.getMappedRange()".}

proc getMappedRange*(buffer: GPUBuffer, offset: int): JsObject {.importjs: "#.getMappedRange(#)".}

proc getMappedRange*(buffer: GPUBuffer, offset: int, size: int): JsObject {.importjs: "#.getMappedRange(#, #)".}

proc unmap*(buffer: GPUBuffer) {.importjs: "#.unmap()".}

# ==============================================================================
# SECTION 21: GPU BUFFER - DESTRUCTION
# ==============================================================================

proc destroy*(buffer: GPUBuffer) {.importjs: "#.destroy()".}

# ==============================================================================
# SECTION 22: GPU COMMAND ENCODER - COMPUTE PASS
# ==============================================================================

proc beginComputePass*(encoder: GPUCommandEncoder): GPUComputePassEncoder {.importjs: "#.beginComputePass()".}

proc beginComputePass*(encoder: GPUCommandEncoder, descriptor: JsObject): GPUComputePassEncoder {.importjs: "#.beginComputePass(#)".}

proc beginComputePassLabeled*(encoder: GPUCommandEncoder, label: cstring): GPUComputePassEncoder {.importjs: "#.beginComputePass({label: #})".}

# ==============================================================================
# SECTION 23: GPU COMMAND ENCODER - BUFFER OPERATIONS
# ==============================================================================

proc clearBuffer*(encoder: GPUCommandEncoder, buffer: GPUBuffer) {.importjs: "#.clearBuffer(#)".}

proc clearBuffer*(encoder: GPUCommandEncoder, buffer: GPUBuffer, offset: int, size: int) {.importjs: "#.clearBuffer(#, #, #)".}

proc copyBufferToBuffer*(encoder: GPUCommandEncoder, source: GPUBuffer, sourceOffset: int, destination: GPUBuffer, destinationOffset: int, size: int) {.importjs: "#.copyBufferToBuffer(#, #, #, #, #)".}

# ==============================================================================
# SECTION 24: GPU COMMAND ENCODER - FINISH
# ==============================================================================

proc finish*(encoder: GPUCommandEncoder): GPUCommandBuffer {.importjs: "#.finish()".}

proc finish*(encoder: GPUCommandEncoder, descriptor: JsObject): GPUCommandBuffer {.importjs: "#.finish(#)".}

# ==============================================================================
# QUERY SETS (timestamp profiling)
# ==============================================================================

proc createQuerySet*(device: GPUDevice, descriptor: JsObject): GPUQuerySet {.importjs: "#.createQuerySet(#)".}
  ## Create a query set; descriptor takes {type: "timestamp", count: n}

proc resolveQuerySet*(encoder: GPUCommandEncoder, querySet: GPUQuerySet,
                      firstQuery: int, queryCount: int,
                      destination: GPUBuffer, destinationOffset: int) {.importjs: "#.resolveQuerySet(#, #, #, #, #)".}
  ## Resolve query results into a buffer with QUERY_RESOLVE usage (8 bytes per query)

# ==============================================================================
# SECTION 25: GPU COMPUTE PASS ENCODER - PIPELINE AND BIND GROUPS
# ==============================================================================

proc setPipeline*(pass: GPUComputePassEncoder, pipeline: GPUComputePipeline) {.importjs: "#.setPipeline(#)".}

proc setBindGroup*(pass: GPUComputePassEncoder, index: int, bindGroup: GPUBindGroup) {.importjs: "#.setBindGroup(#, #)".}

proc setBindGroup*(pass: GPUComputePassEncoder, index: int, bindGroup: GPUBindGroup, dynamicOffsets: JsObject) {.importjs: "#.setBindGroup(#, #, #)".}

# ==============================================================================
# SECTION 26: GPU COMPUTE PASS ENCODER - DISPATCH
# ==============================================================================

proc dispatchWorkgroups*(pass: GPUComputePassEncoder, workgroupCountX: int) {.importjs: "#.dispatchWorkgroups(#)".}

proc dispatchWorkgroups*(pass: GPUComputePassEncoder, workgroupCountX: int, workgroupCountY: int) {.importjs: "#.dispatchWorkgroups(#, #)".}

proc dispatchWorkgroups*(pass: GPUComputePassEncoder, workgroupCountX: int, workgroupCountY: int, workgroupCountZ: int) {.importjs: "#.dispatchWorkgroups(#, #, #)".}

proc dispatchWorkgroupsIndirect*(pass: GPUComputePassEncoder, indirectBuffer: GPUBuffer, indirectOffset: int) {.importjs: "#.dispatchWorkgroupsIndirect(#, #)".}

# ==============================================================================
# SECTION 27: GPU COMPUTE PASS ENCODER - END
# ==============================================================================

proc `end`*(pass: GPUComputePassEncoder) {.importjs: "#.end()".}

proc endPass*(pass: GPUComputePassEncoder) {.importjs: "#.end()".}

# ==============================================================================
# SECTION 28: GPU SUPPORTED LIMITS PROPERTIES
# ==============================================================================

proc maxBufferSize*(limits: GPUSupportedLimits): int {.importjs: "#.maxBufferSize".}

proc maxStorageBufferBindingSize*(limits: GPUSupportedLimits): int {.importjs: "#.maxStorageBufferBindingSize".}

proc maxComputeWorkgroupSizeX*(limits: GPUSupportedLimits): int {.importjs: "#.maxComputeWorkgroupSizeX".}

proc maxComputeWorkgroupSizeY*(limits: GPUSupportedLimits): int {.importjs: "#.maxComputeWorkgroupSizeY".}

proc maxComputeWorkgroupSizeZ*(limits: GPUSupportedLimits): int {.importjs: "#.maxComputeWorkgroupSizeZ".}

proc maxComputeWorkgroupsPerDimension*(limits: GPUSupportedLimits): int {.importjs: "#.maxComputeWorkgroupsPerDimension".}

proc maxComputeInvocationsPerWorkgroup*(limits: GPUSupportedLimits): int {.importjs: "#.maxComputeInvocationsPerWorkgroup".}

proc maxBindGroups*(limits: GPUSupportedLimits): int {.importjs: "#.maxBindGroups".}

proc maxStorageBuffersPerShaderStage*(limits: GPUSupportedLimits): int {.importjs: "#.maxStorageBuffersPerShaderStage".}

proc maxUniformBuffersPerShaderStage*(limits: GPUSupportedLimits): int {.importjs: "#.maxUniformBuffersPerShaderStage".}

# ==============================================================================
# SECTION 29: UTILITY HELPERS
# ==============================================================================

proc isWebGPUAvailable*(): bool =
  hasWebGPU()

proc createBindGroupEntry*(binding: int, buffer: GPUBuffer): JsObject {.importjs: "({binding: #, resource: {buffer: #}})".}

proc createBindGroupEntryOffset*(binding: int, buffer: GPUBuffer, offset: int, size: int): JsObject {.importjs: "({binding: #, resource: {buffer: #, offset: #, size: #}})".}

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

  GPUTexture* = ref object of JsObject

  GPUTextureView* = ref object of JsObject

  GPUSampler* = ref object of JsObject

  GPURenderPipeline* = ref object of JsObject

  GPURenderPassEncoder* = ref object of JsObject

proc getContextWebGPU*(canvas: JsObject): GPUCanvasContext {.importjs: "#.getContext('webgpu')".}

proc configure*(context: GPUCanvasContext, config: JsObject) {.importjs: "#.configure(#)".}

proc getCurrentTexture*(context: GPUCanvasContext): GPUTexture {.importjs: "#.getCurrentTexture()".}

proc createView*(texture: GPUTexture): GPUTextureView {.importjs: "#.createView()".}

proc destroy*(texture: GPUTexture) {.importjs: "#.destroy()".}

proc createTexture*(device: GPUDevice, descriptor: JsObject): GPUTexture {.importjs: "#.createTexture(#)".}

proc createSampler*(device: GPUDevice, descriptor: JsObject): GPUSampler {.importjs: "#.createSampler(#)".}

proc getPreferredCanvasFormat*(): cstring {.importjs: "navigator.gpu.getPreferredCanvasFormat()".}

# ==============================================================================
# SECTION 25: RENDER PIPELINE
# ==============================================================================

proc createRenderPipeline*(device: GPUDevice, descriptor: JsObject): GPURenderPipeline {.importjs: "#.createRenderPipeline(#)".}

proc getBindGroupLayout*(pipeline: GPURenderPipeline, index: int): GPUBindGroupLayout {.importjs: "#.getBindGroupLayout(#)".}

# ==============================================================================
# SECTION 26: RENDER PASS
# ==============================================================================

proc beginRenderPass*(encoder: GPUCommandEncoder, descriptor: JsObject): GPURenderPassEncoder {.importjs: "#.beginRenderPass(#)".}

proc setPipeline*(pass: GPURenderPassEncoder, pipeline: GPURenderPipeline) {.importjs: "#.setPipeline(#)".}

proc setBindGroup*(pass: GPURenderPassEncoder, index: int, bindGroup: GPUBindGroup) {.importjs: "#.setBindGroup(#, #)".}

proc draw*(pass: GPURenderPassEncoder, vertexCount: int, instanceCount: int, firstVertex: int, firstInstance: int) {.importjs: "#.draw(#, #, #, #)".}

proc endPass*(pass: GPURenderPassEncoder) {.importjs: "#.end()".}

# ==============================================================================
# SECTION 27: SHADER STAGE FLAGS
# ==============================================================================

var gpuShaderStageVertex* {.importjs: "GPUShaderStage.VERTEX", nodecl.}: int

var gpuShaderStageFragment* {.importjs: "GPUShaderStage.FRAGMENT", nodecl.}: int

var gpuShaderStageCompute* {.importjs: "GPUShaderStage.COMPUTE", nodecl.}: int
