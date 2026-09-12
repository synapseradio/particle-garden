# https://developer.mozilla.org/en-US/docs/Web/API/Web_Audio_API and https://developer.mozilla.org/en-US/docs/Web/API/MediaDevices/getUserMedia

from std/jsffi import JsObject
from std/asyncjs import Future
import ./typed_arrays

type
  MediaStreamTrack* = ref object of JsObject

  MediaTrackSettings* = ref object of JsObject
    echoCancellation* {.importjs: "echoCancellation".}: bool
    noiseSuppression* {.importjs: "noiseSuppression".}: bool
    autoGainControl* {.importjs: "autoGainControl".}: bool

  MediaStream* = ref object of JsObject

  AudioNode* = ref object of JsObject

  MediaStreamAudioSourceNode* = ref object of AudioNode

  AnalyserNode* = ref object of AudioNode

  AudioContext* = ref object of JsObject
    sampleRate* {.importjs: "sampleRate".}: float

proc getUserMediaAudio*(): Future[MediaStream] {.importjs:
  "navigator.mediaDevices.getUserMedia({audio: {echoCancellation: false, noiseSuppression: false, autoGainControl: false}})".}
  ## Each of the three constraints is a preference the browser may decline;
  ## the granted track's getSettings() reports which it actually honored.

proc getTracks*(stream: MediaStream): JsObject {.importjs: "#.getTracks()".}

proc tracksLength*(tracks: JsObject): int {.importjs: "#.length".}

proc trackAt*(tracks: JsObject, index: int): MediaStreamTrack {.importjs: "#[#]".}

proc stop*(track: MediaStreamTrack) {.importjs: "#.stop()".}

proc getSettings*(track: MediaStreamTrack): MediaTrackSettings {.importjs: "#.getSettings()".}

proc newAudioContext*(): AudioContext {.importjs: "new AudioContext()".}

proc resume*(ctx: AudioContext): Future[void] {.importjs: "#.resume()".}

proc close*(ctx: AudioContext): Future[void] {.importjs: "#.close()".}

proc createMediaStreamSource*(ctx: AudioContext, stream: MediaStream): MediaStreamAudioSourceNode {.importjs: "#.createMediaStreamSource(#)".}

proc createAnalyser*(ctx: AudioContext): AnalyserNode {.importjs: "#.createAnalyser()".}

proc `fftSize=`*(node: AnalyserNode, value: int) {.importjs: "#.fftSize = #".}

proc `smoothingTimeConstant=`*(node: AnalyserNode, value: float) {.importjs: "#.smoothingTimeConstant = #".}

proc frequencyBinCount*(node: AnalyserNode): int {.importjs: "#.frequencyBinCount".}

proc getFloatFrequencyData*(node: AnalyserNode, data: Float32Array) {.importjs: "#.getFloatFrequencyData(#)".}

proc getFloatTimeDomainData*(node: AnalyserNode, data: Float32Array) {.importjs: "#.getFloatTimeDomainData(#)".}

proc connect*(source: MediaStreamAudioSourceNode, destination: AnalyserNode) {.importjs: "#.connect(#)".}
  ## The analyser is the only consumer of the stream; nothing connects onward
  ## from it, so the captured signal never reaches an output device.
