# ==============================================================================
#
# Layer 3: browser integration. The capture chain the listen control drives:
# creates the AudioContext and requests the microphone inside the click,
# wires source -> analyser -> nothing further, and polls the analyser once
# per frame into the pure feature core (ui/input/audio_core.nim). Registers
# its start/stop/state/sources hooks with web_api at module init, so app.nim
# needs only the import and the per-frame poll call.
#
# JS-only: no native test imports this module, the same limit web_api.nim
# records for its own wiring.
#
# ==============================================================================

when defined(js):
  import std/asyncjs
  from std/jsffi import JsObject, toJs, `[]=`
  from bindings/js_interop import newJsObject, newJsArray, push
  from bindings/typed_arrays import Float32Array, newFloat32Array, `[]`

  import bindings/web_audio
  import ui/input/audio_core
  from ui/input/control_matrix import skContinuous
  from ui/input/shipped_mapping import SHIPPED_AUDIO_SOURCES
  import web_api

  var listenState = lsDisconnected
  var audioContext: AudioContext
  var mediaStream: MediaStream
  var sourceNode: MediaStreamAudioSourceNode
  var analyserNode: AnalyserNode
  var analysisState = initAnalysisState()

  # Allocated once at connect time and reused every frame: the JS arrays the
  # analyser fills, and the Nim seqs analyse() reads, so a live capture costs
  # no per-frame allocation.
  var jsBins: Float32Array
  var jsSamples: Float32Array
  var audioFrame = AudioFrame(
    bins: newSeq[float32](FREQUENCY_BIN_COUNT),
    samples: newSeq[float32](ANALYSER_FFT_SIZE))

  proc audioSourcesJs(): JsObject =
    ## The meters' six entries, off the same declarations the mapping editor
    ## lists, so a label has one home.
    result = newJsArray()
    for decl in SHIPPED_AUDIO_SOURCES:
      let entry = newJsObject()
      entry["id"] = toJs(cstring(decl.id))
      entry["label"] = toJs(cstring(decl.label))
      entry["kind"] = toJs(cstring(
        if decl.kind == skContinuous: "continuous" else: "event"))
      result.push(entry)

  proc pushStateOnly() =
    web_api.pushAudio(listenState, AudioFeatures(onset: Onset(fired: false)))

  proc stopAllTracks(stream: MediaStream) =
    let tracks = getTracks(stream)
    for trackIndex in 0 ..< tracksLength(tracks):
      stop(trackAt(tracks, trackIndex))

  proc logConstraintsHonored(echoCancellation, noiseSuppression,
      autoGainControl: bool) =
    {.emit: "console.log('[audio] constraints honored: echoCancellation=' + `echoCancellation` + ' noiseSuppression=' + `noiseSuppression` + ' autoGainControl=' + `autoGainControl`);".}

  proc onMicrophoneGranted(stream: MediaStream) =
    if listenState != lsRequesting:
      # Listen was switched off while the prompt was open: the context is
      # already closed, so release the granted stream and keep that answer.
      stopAllTracks(stream)
      return
    mediaStream = stream
    sourceNode = createMediaStreamSource(audioContext, stream)
    analyserNode = createAnalyser(audioContext)
    analyserNode.fftSize = ANALYSER_FFT_SIZE
    analyserNode.smoothingTimeConstant = ANALYSER_SMOOTHING
    connect(sourceNode, analyserNode)  # wired onward to nothing further
    discard resume(audioContext)
    jsBins = newFloat32Array(frequencyBinCount(analyserNode))
    jsSamples = newFloat32Array(ANALYSER_FFT_SIZE)
    let tracks = getTracks(stream)
    if tracksLength(tracks) > 0:
      let settings = getSettings(trackAt(tracks, 0))
      logConstraintsHonored(settings.echoCancellation,
        settings.noiseSuppression, settings.autoGainControl)
    listenState = lsConnected
    pushStateOnly()

  proc onMicrophoneDenied() =
    if listenState != lsRequesting:
      return
    if not mediaStream.isNil:
      stopAllTracks(mediaStream)
      mediaStream = nil
    if not audioContext.isNil:
      discard close(audioContext)
      audioContext = nil
    listenState = lsDenied
    web_api.withdrawSourceFamily("audio")
    pushStateOnly()

  proc requestMicrophone(): Future[void] {.async.} =
    try:
      let stream = await getUserMediaAudio()
      onMicrophoneGranted(stream)
    except CatchableError:
      onMicrophoneDenied()

  proc startListening*() =
    if listenState in {lsRequesting, lsConnected, lsSilent}:
      return  # the click is the consent; a second click mid-listen asks nothing new
    audioContext = newAudioContext()
    listenState = lsRequesting
    pushStateOnly()
    discard requestMicrophone()

  proc stopListening*() =
    if not mediaStream.isNil:
      stopAllTracks(mediaStream)
      mediaStream = nil
    if not audioContext.isNil:
      discard close(audioContext)
      audioContext = nil
    sourceNode = nil
    analyserNode = nil
    analysisState = initAnalysisState()
    listenState = lsDisconnected
    web_api.withdrawSourceFamily("audio")
    pushStateOnly()

  proc currentListenState(): ListenState = listenState

  proc pollAudioFrame*(dtSeconds: float) =
    ## The frame's one poll: copy, call, push.
    if listenState != lsConnected and listenState != lsSilent:
      return
    getFloatFrequencyData(analyserNode, jsBins)
    getFloatTimeDomainData(analyserNode, jsSamples)
    for binIndex in 0 ..< audioFrame.bins.len:
      audioFrame.bins[binIndex] = float32(jsBins[binIndex])
    for sampleIndex in 0 ..< audioFrame.samples.len:
      audioFrame.samples[sampleIndex] = float32(jsSamples[sampleIndex])
    audioFrame.sampleRate = audioContext.sampleRate
    audioFrame.dtSeconds = dtSeconds
    let features = analyse(analysisState, audioFrame)
    listenState = if features.silent: lsSilent else: lsConnected
    web_api.pushAudio(listenState, features)
    # The hand-off to the mapping, ahead of the flush the loop runs next. The
    # five levels are the latest value each; a hit is one event at its energy,
    # on ordinal zero since a room has no pad to name.
    web_api.setSourceValue("audio:loudness", features.loudness)
    web_api.setSourceValue("audio:bass", features.bass)
    web_api.setSourceValue("audio:mid", features.mid)
    web_api.setSourceValue("audio:high", features.high)
    web_api.setSourceValue("audio:brightness", features.brightness)
    if features.onset.fired:
      web_api.emitSourceEvent("audio:onset", features.onset.energy, 0)

  # Self-registers at module init: web_api's own top-level has already run
  # by the time this line executes (audio_input imports web_api), so no call
  # from app.nim's init is needed. The family declares whole here, so the
  # shipped audio rows resolve before Listen is ever pressed.
  web_api.registerSourceFamily("audio", SHIPPED_AUDIO_SOURCES)
  web_api.registerAudioControl(startListening, stopListening,
    currentListenState, audioSourcesJs)
