import Cocoa
import FlutterMacOS
import CoreAudio
import AudioToolbox
import AVFoundation

private class TapContext {
    weak var tapChannel: AudioTapChannel?
    var sourceSampleRate: Double
    var isInput: Bool

    init(tapChannel: AudioTapChannel, sourceSampleRate: Double, isInput: Bool) {
        self.tapChannel = tapChannel
        self.sourceSampleRate = sourceSampleRate
        self.isInput = isInput
    }
}

class AudioTapChannel: NSObject, FlutterStreamHandler {
    private let methodChannel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel
    private var eventSink: FlutterEventSink?

    // Direct mic capture (used when NO call is active, for Whisper)
    private var inputTapProcID: AudioDeviceIOProcID?
    private var inputDeviceID: AudioDeviceID = 0
    private var isCapturing = false

    var inputBuffer = Data()
    let bufferLock = NSLock()
    private var flushTimer: Timer?
    private var inputContext: TapContext?

    let targetSampleRate: Double = 24000
    private let chunkDurationMs: Int = 100

    private var isPlayingResponse = false
    private var playbackEndTimer: Timer?
    private var outputSuppressedUntil: TimeInterval = 0
    private var diagCounter: UInt64 = 0
    private var playDiagCounter: UInt64 = 0

    /// Tracks which audio source was dominant over a sliding window.
    /// "host" = mic, "remote" = remote party, "unknown" = neither or silence.
    private(set) var dominantSpeaker: String = "unknown"

    /// Sliding window of per-flush dominant results for smoothing.
    /// Each entry is "host", "remote", or "unknown".
    private var dominantHistory: [String] = []
    private static let dominantWindowSize = 30  // 30 × 100ms = 3 seconds

    /// When true, audio flows through WebRTC pipeline processors
    /// instead of direct CoreAudio capture + AVAudioEngine playback.
    private var inCallMode = false

    // MARK: - Audio Playback (AVAudioEngine — used outside of calls)
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    init(messenger: FlutterBinaryMessenger) {
        methodChannel = FlutterMethodChannel(
            name: "com.agentic_ai/audio_tap_control",
            binaryMessenger: messenger
        )
        eventChannel = FlutterEventChannel(
            name: "com.agentic_ai/audio_tap",
            binaryMessenger: messenger
        )
        super.init()
        eventChannel.setStreamHandler(self)
        methodChannel.setMethodCallHandler(handleMethodCall)
    }

    func cleanup() {
        stopCapture()
        stopPlayback()
        WebRTCAudioProcessor.shared.unregister()
    }

    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startAudioTap":
            let args = call.arguments as? [String: Any] ?? [:]
            let captureInput = args["captureInput"] as? Bool ?? true
            startCapture(captureInput: captureInput)
            result(nil)
        case "stopAudioTap":
            stopCapture()
            result(nil)
        case "enterCallMode":
            enterCallMode()
            result(nil)
        case "exitCallMode":
            exitCallMode()
            result(nil)
        case "playAudioResponse":
            if let data = call.arguments as? FlutterStandardTypedData {
                handlePlayAudio(data.data)
            } else if let data = call.arguments as? Data {
                handlePlayAudio(data)
            } else {
                NSLog("[AudioTap] playAudioResponse: unexpected argument type: %@",
                      String(describing: type(of: call.arguments)))
            }
            result(nil)
        case "stopAudioPlayback":
            stopPlayback()
            result(nil)
        case "getDominantSpeaker":
            result(dominantSpeaker)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - FlutterStreamHandler

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }

    // MARK: - Call Mode (WebRTC pipeline injection)

    private func enterCallMode() {
        guard !inCallMode else { return }
        inCallMode = true

        // Clear stale suppression and speaker history from pre-call state.
        isPlayingResponse = false
        outputSuppressedUntil = 0
        playbackEndTimer?.invalidate()
        dominantHistory.removeAll()
        dominantSpeaker = "unknown"

        // Keep mic IOProc running — it feeds the micInjectionRing as a
        // fallback when WebRTC's ADM doesn't deliver mic audio (common
        // when SDP renegotiation fails on the peer connection).

        // Register processors that inject/tap audio inside WebRTC
        WebRTCAudioProcessor.shared.register()
        NSLog("[AudioTap] Entered call mode — mic IOProc kept alive for injection fallback")
    }

    private func exitCallMode() {
        guard inCallMode else { return }
        inCallMode = false

        // Unregister WebRTC processors
        WebRTCAudioProcessor.shared.unregister()

        // Clear suppression and speaker history for clean direct-mode state
        isPlayingResponse = false
        outputSuppressedUntil = 0
        playbackEndTimer?.invalidate()
        dominantHistory.removeAll()
        dominantSpeaker = "unknown"

        NSLog("[AudioTap] Exited call mode — direct mic capture continues")
    }

    // MARK: - Audio Playback

    private func ensureEngineRunning() {
        if let engine = audioEngine, engine.isRunning, playerNode != nil {
            return
        }

        // Tear down stale engine if it exists but stopped
        if audioEngine != nil {
            stopPlayback()
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        engine.attach(player)

        let floatFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24000,
            channels: 1,
            interleaved: false
        )!
        engine.connect(player, to: engine.mainMixerNode, format: floatFormat)
        engine.mainMixerNode.outputVolume = 1.0

        do {
            try engine.start()
            player.play()
            audioEngine = engine
            playerNode = player
            NSLog("[AudioTap] Playback engine started, running=%@",
                  engine.isRunning ? "YES" : "NO")
        } catch {
            NSLog("[AudioTap] Failed to start audio engine: \(error)")
        }
    }

    /// Routes audio to the correct destination based on mode.
    private func handlePlayAudio(_ data: Data) {
        playbackEndTimer?.invalidate()

        playDiagCounter += 1
        if playDiagCounter <= 3 || playDiagCounter % 100 == 0 {
            NSLog("[AudioTap] handlePlayAudio #%llu: %d bytes, callMode=%@",
                  playDiagCounter, data.count, inCallMode ? "YES" : "NO")
        }

        if inCallMode {
            // In call mode TTS goes into ring buffers — no speaker echo,
            // so we don't block mic audio from reaching OpenAI.
            WebRTCAudioProcessor.shared.feedTTS(pcm16Data: data)
        } else {
            // In direct mode TTS plays through speakers. Block mic audio
            // while playing to prevent the agent hearing its own echo.
            isPlayingResponse = true
            playPCM16ViaEngine(data)
        }
    }

    private func playPCM16ViaEngine(_ data: Data) {
        ensureEngineRunning()
        guard let player = playerNode, let engine = audioEngine else {
            NSLog("[AudioTap] playPCM16ViaEngine: no player/engine")
            return
        }

        if !engine.isRunning {
            NSLog("[AudioTap] Engine stopped — restarting")
            do { try engine.start(); player.play() }
            catch { NSLog("[AudioTap] Restart failed: \(error)"); return }
        }

        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 24000,
                channels: 1,
                interleaved: false
            )!,
            frameCapacity: AVAudioFrameCount(sampleCount)
        ) else {
            NSLog("[AudioTap] Failed to create PCM buffer for %d samples", sampleCount)
            return
        }

        pcmBuffer.frameLength = AVAudioFrameCount(sampleCount)

        data.withUnsafeBytes { rawPtr in
            let int16Ptr = rawPtr.bindMemory(to: Int16.self)
            let floatChannel = pcmBuffer.floatChannelData![0]
            for i in 0..<sampleCount {
                floatChannel[i] = Float(int16Ptr[i]) / 32768.0
            }
        }

        player.scheduleBuffer(pcmBuffer) { [weak self] in
            DispatchQueue.main.async {
                self?.schedulePlaybackEnd()
            }
        }
    }

    private func schedulePlaybackEnd() {
        playbackEndTimer?.invalidate()
        playbackEndTimer = Timer.scheduledTimer(
            withTimeInterval: 0.35, repeats: false
        ) { [weak self] _ in
            guard let self = self else { return }
            self.bufferLock.lock()
            self.inputBuffer.removeAll(keepingCapacity: true)
            self.bufferLock.unlock()
            // In call mode TTS goes through ring buffers (no speaker echo),
            // so we only need a brief pause. In direct mode TTS plays through
            // speakers and the mic picks up the echo — allow a longer window
            // but keep it short since input_audio_buffer.clear already tells
            // OpenAI to discard accumulated echo audio.
            let suppressionSeconds: TimeInterval = self.inCallMode ? 0.3 : 1.0
            self.outputSuppressedUntil = Date().timeIntervalSince1970 + suppressionSeconds
            self.isPlayingResponse = false
            NSLog("[AudioTap] Playback ended — suppressed %.1fs (callMode=%@)",
                  suppressionSeconds, self.inCallMode ? "YES" : "NO")
        }
    }

    private func stopPlayback() {
        isPlayingResponse = false
        playbackEndTimer?.invalidate()
        playbackEndTimer = nil
        playerNode?.stop()
        audioEngine?.stop()
        if let player = playerNode, let engine = audioEngine {
            engine.detach(player)
        }
        playerNode = nil
        audioEngine = nil
    }

    // MARK: - Capture Control

    private func startCapture(captureInput: Bool) {
        if isCapturing { stopCapture() }

        isPlayingResponse = false
        outputSuppressedUntil = 0
        isCapturing = true

        if captureInput {
            startMicCapture()
        }

        flushTimer = Timer.scheduledTimer(withTimeInterval: Double(chunkDurationMs) / 1000.0, repeats: true) { [weak self] _ in
            self?.flushBuffers()
        }
    }

    private func startMicCapture() {
        inputDeviceID = findPhysicalInputDevice()
        if inputDeviceID != 0 {
            installMicIOProc(deviceID: inputDeviceID)
            NSLog("[AudioTap] Mic IOProc installed on device %d (%@)",
                  inputDeviceID, getDeviceUID(forDevice: inputDeviceID))
        } else {
            NSLog("[AudioTap] WARNING: No physical input device found")
        }
    }

    private func stopMicCapture() {
        if let procID = inputTapProcID, inputDeviceID != 0 {
            AudioDeviceStop(inputDeviceID, procID)
            AudioDeviceDestroyIOProcID(inputDeviceID, procID)
            inputTapProcID = nil
        }
        inputContext = nil
    }

    private func stopCapture() {
        isCapturing = false
        flushTimer?.invalidate()
        flushTimer = nil

        stopMicCapture()

        if inCallMode {
            exitCallMode()
        }

        bufferLock.lock()
        inputBuffer.removeAll()
        bufferLock.unlock()
    }

    // MARK: - CoreAudio Mic IO Proc (always active — feeds both inputBuffer and micInjectionRing)

    private func installMicIOProc(deviceID: AudioDeviceID) {
        var nominalRate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &rateAddr, 0, nil, &rateSize, &nominalRate)
        if nominalRate <= 0 { nominalRate = 48000 }

        let ctx = TapContext(tapChannel: self, sourceSampleRate: nominalRate, isInput: true)
        inputContext = ctx

        let contextPtr = Unmanaged.passRetained(ctx).toOpaque()
        var procID: AudioDeviceIOProcID?

        let status = AudioDeviceCreateIOProcID(deviceID, audioIOProc, contextPtr, &procID)
        if status == noErr, let procID = procID {
            inputTapProcID = procID
            AudioDeviceStart(deviceID, procID)
        } else {
            Unmanaged<TapContext>.fromOpaque(contextPtr).release()
        }
    }

    // MARK: - Buffer Flush

    private func flushBuffers() {
        var dataToSend: Data?

        if inCallMode {
            // Remote party audio from RenderPreProcessor (PCM16 24kHz)
            let remoteData = WebRTCAudioProcessor.shared.drainWhisperBuffer()

            // Mic audio from CoreAudio IOProc (PCM16 24kHz)
            bufferLock.lock()
            let micData = inputBuffer
            inputBuffer.removeAll(keepingCapacity: true)
            bufferLock.unlock()

            let remoteCount = (remoteData?.count ?? 0) / 2
            let micCount = micData.count / 2
            let maxCount = max(remoteCount, micCount)

            var remoteRMS: Double = 0
            var micRMS: Double = 0

            if maxCount > 0 {
                var mixed = [Int16](repeating: 0, count: maxCount)

                if let remoteData = remoteData {
                    remoteData.withUnsafeBytes { ptr in
                        let samples = ptr.bindMemory(to: Int16.self)
                        var sumSq: Double = 0
                        for i in 0..<remoteCount {
                            mixed[i] = samples[i]
                            let s = Double(samples[i])
                            sumSq += s * s
                        }
                        if remoteCount > 0 {
                            remoteRMS = (sumSq / Double(remoteCount)).squareRoot()
                        }
                    }
                }

                if !micData.isEmpty {
                    micData.withUnsafeBytes { ptr in
                        let samples = ptr.bindMemory(to: Int16.self)
                        var sumSq: Double = 0
                        for i in 0..<micCount {
                            let sum = Int32(mixed[i]) + Int32(samples[i])
                            mixed[i] = Int16(clamping: max(Int32(-32768), min(Int32(32767), sum)))
                            let s = Double(samples[i])
                            sumSq += s * s
                        }
                        if micCount > 0 {
                            micRMS = (sumSq / Double(micCount)).squareRoot()
                        }
                    }
                }

                dataToSend = mixed.withUnsafeBufferPointer { Data(buffer: $0) }
            }

            // Determine per-flush dominant speaker.
            // The remote feed (whisperRingBuffer) is clean — only has signal
            // when the remote party is actually talking. The mic always has
            // ambient noise, so we use the remote feed as the discriminator.
            let remoteActiveThreshold: Double = 150
            let micActiveThreshold: Double = 500
            let flushDominant: String
            if remoteRMS > remoteActiveThreshold {
                flushDominant = "remote"
            } else if micRMS > micActiveThreshold {
                flushDominant = "host"
            } else {
                flushDominant = "unknown"
            }

            dominantHistory.append(flushDominant)
            if dominantHistory.count > AudioTapChannel.dominantWindowSize {
                dominantHistory.removeFirst()
            }

            // Resolve window: count non-unknown votes in the last N flushes
            let hostVotes = dominantHistory.filter { $0 == "host" }.count
            let remoteVotes = dominantHistory.filter { $0 == "remote" }.count
            if remoteVotes > 0 || hostVotes > 0 {
                dominantSpeaker = remoteVotes >= hostVotes ? "remote" : "host"
            } else {
                dominantSpeaker = "unknown"
            }

            diagCounter += 1
            if diagCounter <= 10 || diagCounter % 50 == 1 {
                NSLog("[AudioTap] flush: mode=call remoteSamples=%d micSamples=%d micRMS=%.0f remoteRMS=%.0f dominant=%@ mixedBytes=%d sink=%@ playing=%@ suppressed=%@",
                      remoteCount, micCount, micRMS, remoteRMS, dominantSpeaker,
                      dataToSend?.count ?? 0,
                      eventSink != nil ? "yes" : "NO",
                      isPlayingResponse ? "yes" : "no",
                      Date().timeIntervalSince1970 < outputSuppressedUntil ? "yes" : "no")
            }
        } else {
            bufferLock.lock()
            let inData = inputBuffer
            inputBuffer.removeAll(keepingCapacity: true)
            bufferLock.unlock()

            if !inData.isEmpty {
                dataToSend = inData
            }

            diagCounter += 1
            if diagCounter % 50 == 1 {
                NSLog("[AudioTap] flush: mode=direct bytes=%d sink=%@ playing=%@",
                      dataToSend?.count ?? 0,
                      eventSink != nil ? "yes" : "NO",
                      isPlayingResponse ? "yes" : "no")
            }
        }

        guard let sink = eventSink else { return }
        if isPlayingResponse { return }
        if Date().timeIntervalSince1970 < outputSuppressedUntil { return }

        if let data = dataToSend, !data.isEmpty {
            sink(FlutterStandardTypedData(bytes: data))
        }
    }

    // MARK: - Helpers

    private func getDeviceUID(forDevice deviceID: AudioDeviceID) -> String {
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.stride)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        return uid as String
    }

    private func findPhysicalInputDevice() -> AudioDeviceID {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil, &dataSize
        ) == noErr else { return getDefaultDeviceID(forInput: true) }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return getDefaultDeviceID(forInput: true) }

        let sysDefault = getDefaultDeviceID(forInput: true)

        for devID in deviceIDs {
            let uid = getDeviceUID(forDevice: devID)
            if uid.hasPrefix("com.agentic_ai.") { continue }

            if hasInputChannels(devID) && devID == sysDefault {
                return devID
            }
        }

        for devID in deviceIDs {
            let uid = getDeviceUID(forDevice: devID)
            if uid.hasPrefix("com.agentic_ai.") { continue }
            if hasInputChannels(devID) { return devID }
        }

        return getDefaultDeviceID(forInput: true)
    }

    private func hasInputChannels(_ devID: AudioDeviceID) -> Bool {
        var streamSize: UInt32 = 0
        var inputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(devID, &inputAddr, 0, nil, &streamSize) == noErr,
              streamSize > 0 else { return false }

        let bufListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufListPtr.deallocate() }
        guard AudioObjectGetPropertyData(devID, &inputAddr, 0, nil, &streamSize, bufListPtr) == noErr else { return false }
        let channels = (0..<Int(bufListPtr.pointee.mNumberBuffers)).reduce(0) { total, i in
            total + Int(UnsafeMutableAudioBufferListPointer(bufListPtr)[i].mNumberChannels)
        }
        return channels > 0
    }

    private func getDefaultDeviceID(forInput: Bool) -> AudioDeviceID {
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: forInput
                ? kAudioHardwarePropertyDefaultInputDevice
                : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceID
        )
        return deviceID
    }
}

// MARK: - Free C function (mic IOProc callback)

private func audioIOProc(
    device: AudioDeviceID,
    now: UnsafePointer<AudioTimeStamp>,
    inputData: UnsafePointer<AudioBufferList>,
    inputTime: UnsafePointer<AudioTimeStamp>,
    outputData: UnsafeMutablePointer<AudioBufferList>,
    outputTime: UnsafePointer<AudioTimeStamp>,
    clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData = clientData else { return noErr }
    let ctx = Unmanaged<TapContext>.fromOpaque(clientData).takeUnretainedValue()
    guard let tapChannel = ctx.tapChannel else { return noErr }

    let bufferList = inputData.pointee
    guard bufferList.mNumberBuffers > 0 else { return noErr }

    let buffer = bufferList.mBuffers
    guard let dataPointer = buffer.mData else { return noErr }

    let frameCount = Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * Int(buffer.mNumberChannels))
    let channelCount = Int(buffer.mNumberChannels)
    let srcRate = ctx.sourceSampleRate

    let floatPtr = dataPointer.assumingMemoryBound(to: Float32.self)
    var monoSamples = [Float32](repeating: 0, count: frameCount)

    if channelCount == 1 {
        for i in 0..<frameCount {
            monoSamples[i] = floatPtr[i]
        }
    } else {
        for i in 0..<frameCount {
            var sum: Float32 = 0
            for ch in 0..<channelCount {
                sum += floatPtr[i * channelCount + ch]
            }
            monoSamples[i] = sum / Float32(channelCount)
        }
    }

    // Always feed the mic injection ring so CapturePostProcessor has
    // fresh data the instant it starts reading. The ring silently drops
    // writes when full (no call active), and register() resets it.
    let proc = WebRTCAudioProcessor.shared
    var scaled = [Float](repeating: 0, count: frameCount)
    for i in 0..<frameCount {
        scaled[i] = monoSamples[i] * 32767.0
    }
    _ = scaled.withUnsafeBufferPointer { ptr in
        proc.micInjectionRing.write(ptr.baseAddress!, count: frameCount)
    }
    proc.micSourceRate = Int(srcRate)

    let targetRate = tapChannel.targetSampleRate
    let ratio = targetRate / srcRate
    let outCount = Int(Double(frameCount) * ratio)
    guard outCount > 0 else { return noErr }

    var pcm16 = [Int16](repeating: 0, count: outCount)
    for i in 0..<outCount {
        let srcIdx = Double(i) / ratio
        let idx0 = Int(srcIdx)
        let frac = Float32(srcIdx - Double(idx0))
        let s0 = idx0 < frameCount ? monoSamples[idx0] : 0
        let s1 = (idx0 + 1) < frameCount ? monoSamples[idx0 + 1] : s0
        let sample = s0 + (s1 - s0) * frac
        let clamped = max(Float32(-1.0), min(Float32(1.0), sample))
        pcm16[i] = Int16(clamped * 32767)
    }

    let data = pcm16.withUnsafeBufferPointer { ptr in
        Data(buffer: ptr)
    }

    tapChannel.bufferLock.lock()
    tapChannel.inputBuffer.append(data)
    tapChannel.bufferLock.unlock()

    return noErr
}
