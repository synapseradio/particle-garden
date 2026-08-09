from std/jsffi import JsObject
from std/asyncjs import Future
import ./typed_arrays

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

type
  GPUBufferUsageFlags* = distinct int

var GPUBufferUsage* {.importjs: "GPUBufferUsage".}: JsObject

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

proc `or`*(a, b: GPUBufferUsageFlags): GPUBufferUsageFlags {.importjs: "(# | #)".}

proc `and`*(a, b: GPUBufferUsageFlags): GPUBufferUsageFlags {.importjs: "(# & #)".}

proc bitwiseOr*(a, b: int): int {.importjs: "(# | #)".}

var gpuTextureUsageCopySrc* {.importjs: "GPUTextureUsage.COPY_SRC".}: int

var gpuTextureUsageCopyDst* {.importjs: "GPUTextureUsage.COPY_DST".}: int

var gpuTextureUsageTextureBinding* {.importjs: "GPUTextureUsage.TEXTURE_BINDING".}: int

var gpuTextureUsageStorageBinding* {.importjs: "GPUTextureUsage.STORAGE_BINDING".}: int

var gpuTextureUsageRenderAttachment* {.importjs: "GPUTextureUsage.RENDER_ATTACHMENT".}: int

type
  GPUMapModeFlags* = distinct int

var GPUMapMode* {.importjs: "GPUMapMode".}: JsObject

var gpuMapModeRead* {.importjs: "GPUMapMode.READ".}: int

var gpuMapModeWrite* {.importjs: "GPUMapMode.WRITE".}: int

type
  Navigator* = ref object of JsObject
    gpu* {.importjs: "gpu".}: GPU

var navigator* {.importjs: "navigator".}: Navigator

proc hasWebGPU*(): bool {.importjs: "(typeof navigator !== 'undefined' && !!navigator.gpu)".}

type
  RequestAdapterOptions* = ref object of JsObject
    powerPreference* {.importjs: "powerPreference".}: cstring
    forceFallbackAdapter* {.importjs: "forceFallbackAdapter".}: bool

proc requestAdapter*(gpu: GPU): Future[GPUAdapter] {.importjs: "#.requestAdapter()".}

proc requestAdapter*(gpu: GPU, options: JsObject): Future[GPUAdapter] {.importjs: "#.requestAdapter(#)".}

proc requestAdapterHighPerformance*(gpu: GPU): Future[GPUAdapter] {.importjs: "#.requestAdapter({powerPreference: 'high-performance'})".}

proc requestAdapterLowPower*(gpu: GPU): Future[GPUAdapter] {.importjs: "#.requestAdapter({powerPreference: 'low-power'})".}

proc info*(adapter: GPUAdapter): GPUAdapterInfo {.importjs: "#.info".}

proc limits*(adapter: GPUAdapter): GPUSupportedLimits {.importjs: "#.limits".}

proc isFallbackAdapter*(adapter: GPUAdapter): bool {.importjs: "#.isFallbackAdapter".}

proc hasFeature*(adapter: GPUAdapter, name: cstring): bool {.importjs: "#.features.has(#)".}
  ## Check whether the adapter supports an optional feature (e.g. "timestamp-query")

type
  DeviceDescriptor* = ref object of JsObject
    requiredLimits* {.importjs: "requiredLimits".}: JsObject
    requiredFeatures* {.importjs: "requiredFeatures".}: JsObject
    label* {.importjs: "label".}: cstring

proc requestDevice*(adapter: GPUAdapter): Future[GPUDevice] {.importjs: "#.requestDevice()".}

proc requestDevice*(adapter: GPUAdapter, descriptor: JsObject): Future[GPUDevice] {.importjs: "#.requestDevice(#)".}

proc queue*(device: GPUDevice): GPUQueue {.importjs: "#.queue".}

proc limits*(device: GPUDevice): GPUSupportedLimits {.importjs: "#.limits".}

proc lost*(device: GPUDevice): Future[JsObject] {.importjs: "#.lost".}

proc label*(device: GPUDevice): cstring {.importjs: "#.label".}

proc `label=`*(device: GPUDevice, value: cstring) {.importjs: "#.label = #".}

proc destroy*(device: GPUDevice) {.importjs: "#.destroy()".}

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

proc createShaderModule*(device: GPUDevice, descriptor: JsObject): GPUShaderModule {.importjs: "#.createShaderModule(#)".}
  ## Create a shader module from WGSL code
  ##
  ## Descriptor fields:
  ##   code: cstring - WGSL shader source code
  ##   label: cstring - Optional debug label

proc createShaderModuleCode*(device: GPUDevice, code: cstring): GPUShaderModule {.importjs: "#.createShaderModule({code: #})".}

proc createShaderModuleLabeled*(device: GPUDevice, code: cstring, label: cstring): GPUShaderModule {.importjs: "#.createShaderModule({code: #, label: #})".}

proc getCompilationInfo*(shaderModule: GPUShaderModule): Future[GPUCompilationInfo] {.importjs: "#.getCompilationInfo()".}

proc messages*(info: GPUCompilationInfo): JsObject {.importjs: "#.messages".}

proc length*(info: GPUCompilationInfo): int {.importjs: "#.messages.length".}

proc messageType*(msg: GPUCompilationMessage): cstring {.importjs: "#.type".}

proc message*(msg: GPUCompilationMessage): cstring {.importjs: "#.message".}

proc lineNum*(msg: GPUCompilationMessage): int {.importjs: "#.lineNum".}

proc linePos*(msg: GPUCompilationMessage): int {.importjs: "#.linePos".}

proc offset*(msg: GPUCompilationMessage): int {.importjs: "#.offset".}

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

proc getBindGroupLayout*(pipeline: GPUComputePipeline, index: int): GPUBindGroupLayout {.importjs: "#.getBindGroupLayout(#)".}

proc createBindGroup*(device: GPUDevice, descriptor: JsObject): GPUBindGroup {.importjs: "#.createBindGroup(#)".}
  ## Create a bind group
  ##
  ## Descriptor fields:
  ##   layout: GPUBindGroupLayout
  ##   entries: array of { binding: int, resource: { buffer: GPUBuffer } }
  ##   label: cstring - Optional debug label

proc createBindGroupLayout*(device: GPUDevice, descriptor: JsObject): GPUBindGroupLayout {.importjs: "#.createBindGroupLayout(#)".}

proc createPipelineLayout*(device: GPUDevice, descriptor: JsObject): GPUPipelineLayout {.importjs: "#.createPipelineLayout(#)".}

proc createCommandEncoder*(device: GPUDevice): GPUCommandEncoder {.importjs: "#.createCommandEncoder()".}

proc createCommandEncoder*(device: GPUDevice, descriptor: JsObject): GPUCommandEncoder {.importjs: "#.createCommandEncoder(#)".}

proc createCommandEncoderLabeled*(device: GPUDevice, label: cstring): GPUCommandEncoder {.importjs: "#.createCommandEncoder({label: #})".}

proc pushErrorScope*(device: GPUDevice, filter: cstring) {.importjs: "#.pushErrorScope(#)".}
  ## filter: "validation", "out-of-memory", or "internal"

proc popErrorScope*(device: GPUDevice): Future[GPUError] {.importjs: "#.popErrorScope()".}

proc addEventListener*(device: GPUDevice, eventType: cstring, handler: proc(event: JsObject)) {.importjs: "#.addEventListener(#, #)".}

proc writeBuffer*(queue: GPUQueue, buffer: GPUBuffer, bufferOffset: int, data: JsObject) {.importjs: "#.writeBuffer(#, #, #)".}
  ## data: ArrayBuffer, TypedArray, or DataView

proc writeBuffer*(queue: GPUQueue, buffer: GPUBuffer, bufferOffset: int, data: JsObject, dataOffset: int, size: int) {.importjs: "#.writeBuffer(#, #, #, #, #)".}

proc writeBufferTyped*(queue: GPUQueue, buffer: GPUBuffer, bufferOffset: int, data: Float32Array) {.importjs: "#.writeBuffer(#, #, #)".}

proc writeBufferTyped*(queue: GPUQueue, buffer: GPUBuffer, bufferOffset: int, data: Uint32Array) {.importjs: "#.writeBuffer(#, #, #)".}

proc writeBufferTyped*(queue: GPUQueue, buffer: GPUBuffer, bufferOffset: int, data: Uint8Array) {.importjs: "#.writeBuffer(#, #, #)".}

proc writeBufferFromView*(queue: GPUQueue, buffer: GPUBuffer, bufferOffset: int, srcBuffer: JsObject, srcByteOffset: int, byteLength: int) {.importjs: "#.writeBuffer(#, #, #, #, #)".}

proc submit*(queue: GPUQueue, commandBuffers: JsObject) {.importjs: "#.submit(#)".}

proc submitOne*(queue: GPUQueue, commandBuffer: GPUCommandBuffer) {.importjs: "#.submit([#])".}

proc onSubmittedWorkDone*(queue: GPUQueue): Future[void] {.importjs: "#.onSubmittedWorkDone()".}

proc size*(buffer: GPUBuffer): int {.importjs: "#.size".}

proc usage*(buffer: GPUBuffer): int {.importjs: "#.usage".}

proc mapState*(buffer: GPUBuffer): cstring {.importjs: "#.mapState".}
  ## Values: "unmapped", "pending", or "mapped"

proc label*(buffer: GPUBuffer): cstring {.importjs: "#.label".}

proc `label=`*(buffer: GPUBuffer, value: cstring) {.importjs: "#.label = #".}

proc mapAsync*(buffer: GPUBuffer, mode: int): Future[void] {.importjs: "#.mapAsync(#)".}
  ## mode: GPUMapMode.READ or GPUMapMode.WRITE

proc mapAsync*(buffer: GPUBuffer, mode: int, offset: int, size: int): Future[void] {.importjs: "#.mapAsync(#, #, #)".}

proc mapAsyncRead*(buffer: GPUBuffer): Future[void] {.importjs: "#.mapAsync(GPUMapMode.READ)".}

proc mapAsyncWrite*(buffer: GPUBuffer): Future[void] {.importjs: "#.mapAsync(GPUMapMode.WRITE)".}

proc getMappedRange*(buffer: GPUBuffer): JsObject {.importjs: "#.getMappedRange()".}

proc getMappedRange*(buffer: GPUBuffer, offset: int): JsObject {.importjs: "#.getMappedRange(#)".}

proc getMappedRange*(buffer: GPUBuffer, offset: int, size: int): JsObject {.importjs: "#.getMappedRange(#, #)".}

proc unmap*(buffer: GPUBuffer) {.importjs: "#.unmap()".}

proc destroy*(buffer: GPUBuffer) {.importjs: "#.destroy()".}

proc beginComputePass*(encoder: GPUCommandEncoder): GPUComputePassEncoder {.importjs: "#.beginComputePass()".}

proc beginComputePass*(encoder: GPUCommandEncoder, descriptor: JsObject): GPUComputePassEncoder {.importjs: "#.beginComputePass(#)".}

proc beginComputePassLabeled*(encoder: GPUCommandEncoder, label: cstring): GPUComputePassEncoder {.importjs: "#.beginComputePass({label: #})".}

proc clearBuffer*(encoder: GPUCommandEncoder, buffer: GPUBuffer) {.importjs: "#.clearBuffer(#)".}

proc clearBuffer*(encoder: GPUCommandEncoder, buffer: GPUBuffer, offset: int, size: int) {.importjs: "#.clearBuffer(#, #, #)".}

proc copyBufferToBuffer*(encoder: GPUCommandEncoder, source: GPUBuffer, sourceOffset: int, destination: GPUBuffer, destinationOffset: int, size: int) {.importjs: "#.copyBufferToBuffer(#, #, #, #, #)".}

proc finish*(encoder: GPUCommandEncoder): GPUCommandBuffer {.importjs: "#.finish()".}

proc finish*(encoder: GPUCommandEncoder, descriptor: JsObject): GPUCommandBuffer {.importjs: "#.finish(#)".}

proc createQuerySet*(device: GPUDevice, descriptor: JsObject): GPUQuerySet {.importjs: "#.createQuerySet(#)".}
  ## Create a query set; descriptor takes {type: "timestamp", count: n}

proc resolveQuerySet*(encoder: GPUCommandEncoder, querySet: GPUQuerySet,
                      firstQuery: int, queryCount: int,
                      destination: GPUBuffer, destinationOffset: int) {.importjs: "#.resolveQuerySet(#, #, #, #, #)".}
  ## Resolve query results into a buffer with QUERY_RESOLVE usage (8 bytes per query)

proc setPipeline*(pass: GPUComputePassEncoder, pipeline: GPUComputePipeline) {.importjs: "#.setPipeline(#)".}

proc setBindGroup*(pass: GPUComputePassEncoder, index: int, bindGroup: GPUBindGroup) {.importjs: "#.setBindGroup(#, #)".}

proc setBindGroup*(pass: GPUComputePassEncoder, index: int, bindGroup: GPUBindGroup, dynamicOffsets: JsObject) {.importjs: "#.setBindGroup(#, #, #)".}

proc dispatchWorkgroups*(pass: GPUComputePassEncoder, workgroupCountX: int) {.importjs: "#.dispatchWorkgroups(#)".}

proc dispatchWorkgroups*(pass: GPUComputePassEncoder, workgroupCountX: int, workgroupCountY: int) {.importjs: "#.dispatchWorkgroups(#, #)".}

proc dispatchWorkgroups*(pass: GPUComputePassEncoder, workgroupCountX: int, workgroupCountY: int, workgroupCountZ: int) {.importjs: "#.dispatchWorkgroups(#, #, #)".}

proc dispatchWorkgroupsIndirect*(pass: GPUComputePassEncoder, indirectBuffer: GPUBuffer, indirectOffset: int) {.importjs: "#.dispatchWorkgroupsIndirect(#, #)".}

proc `end`*(pass: GPUComputePassEncoder) {.importjs: "#.end()".}

proc endPass*(pass: GPUComputePassEncoder) {.importjs: "#.end()".}

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

proc isWebGPUAvailable*(): bool =
  hasWebGPU()

proc createBindGroupEntry*(binding: int, buffer: GPUBuffer): JsObject {.importjs: "({binding: #, resource: {buffer: #}})".}

proc createBindGroupEntryOffset*(binding: int, buffer: GPUBuffer, offset: int, size: int): JsObject {.importjs: "({binding: #, resource: {buffer: #, offset: #, size: #}})".}

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

proc createRenderPipeline*(device: GPUDevice, descriptor: JsObject): GPURenderPipeline {.importjs: "#.createRenderPipeline(#)".}

proc getBindGroupLayout*(pipeline: GPURenderPipeline, index: int): GPUBindGroupLayout {.importjs: "#.getBindGroupLayout(#)".}

proc beginRenderPass*(encoder: GPUCommandEncoder, descriptor: JsObject): GPURenderPassEncoder {.importjs: "#.beginRenderPass(#)".}

proc setPipeline*(pass: GPURenderPassEncoder, pipeline: GPURenderPipeline) {.importjs: "#.setPipeline(#)".}

proc setBindGroup*(pass: GPURenderPassEncoder, index: int, bindGroup: GPUBindGroup) {.importjs: "#.setBindGroup(#, #)".}

proc draw*(pass: GPURenderPassEncoder, vertexCount: int, instanceCount: int, firstVertex: int, firstInstance: int) {.importjs: "#.draw(#, #, #, #)".}

proc endPass*(pass: GPURenderPassEncoder) {.importjs: "#.end()".}

var gpuShaderStageVertex* {.importjs: "GPUShaderStage.VERTEX", nodecl.}: int

var gpuShaderStageFragment* {.importjs: "GPUShaderStage.FRAGMENT", nodecl.}: int

var gpuShaderStageCompute* {.importjs: "GPUShaderStage.COMPUTE", nodecl.}: int
