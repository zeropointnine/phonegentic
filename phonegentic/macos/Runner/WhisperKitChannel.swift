import Cocoa
import FlutterMacOS

#if canImport(WhisperKit)
import WhisperKit
#endif

/// MethodChannel + EventChannel bridge for WhisperKit on-device STT.
///
/// Channel names:
///   - MethodChannel:  com.agentic_ai/whisperkit_stt
///   - EventChannel:   com.agentic_ai/whisperkit_transcripts
///
/// Methods:
///   - initialize(modelSize:) → loads WhisperKit model from app bundle
///   - isModelAvailable(modelSize:) → checks if model files exist
///   - startTranscription → begins real-time transcription
///   - feedAudio(audio:) → feed PCM16 audio data for transcription
///   - stopTranscription → stops transcription
///   - dispose → releases model resources
class WhisperKitChannel: NSObject, FlutterStreamHandler {
    private let methodChannel: FlutterMethodChannel
    private let transcriptEventChannel: FlutterEventChannel
    private var transcriptEventSink: FlutterEventSink?

    #if canImport(WhisperKit)
    private var whisperKit: WhisperKit?
    #endif

    private var currentModelPath: String?
    private var isInitialized = false
    private var isTranscribing = false
    private let processingQueue = DispatchQueue(label: "com.agentic_ai.whisperkit_stt", qos: .userInitiated)

    // Audio buffer for accumulating PCM chunks before transcription
    private var audioBuffer = Data()
    private let bufferLock = NSLock()
    private var transcriptionTimer: Timer?
    private var isProcessing = false
    private var consecutiveAneFailures = 0
    private static let maxAneFailuresBeforeCpuFallback = 2
    private static let transcriptionIntervalMs = 1500
    private static let inputSampleRate: Double = 24000
    private static let whisperSampleRate: Double = 16000
    private static let minSamplesForTranscription = 16000 // 1s at 16kHz

    /// Tail of the previous transcription buffer, prepended to the next buffer
    /// so speech straddling a boundary isn't lost. 250ms at 24kHz PCM16 = 12000 bytes.
    /// Reduced from 500ms to minimize duplicate-word artifacts from carry-over.
    private var carryOverBuffer = Data()
    private static let carryOverBytes = Int(inputSampleRate) * 2 / 4 // 250ms of PCM16

    /// Previous transcript text for deduplication — WhisperKit may re-transcribe
    /// the carry-over segment and produce duplicate leading words.
    private var lastTranscriptText = ""

    /// Whether the last transcript was a hallucination/empty — if so, the
    /// carry-over buffer is stale silence and must be cleared so it doesn't
    /// eat the first word of real speech that follows.
    private var lastTranscriptWasEmpty = true

    /// Non-speech / hallucination patterns that indicate the audio was silence.
    private static let silencePatterns: [String] = [
        "blank_audio", "blank audio", "silence", "no audio",
        "music", "noise", "beep", "ring", "click",
    ]

    /// Returns true if the transcript text looks like a WhisperKit hallucination
    /// from silence/noise rather than real speech.
    private func isLikelyHallucination(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.isEmpty { return true }
        // Bracketed/parenthetical tags: [BLANK_AUDIO], (silence), etc.
        if lower.hasPrefix("[") || lower.hasPrefix("(") || lower.hasPrefix("{") {
            return true
        }
        // Check known silence phrases
        for pattern in WhisperKitChannel.silencePatterns {
            if lower.contains(pattern) { return true }
        }
        // Very short (1-2 chars) or punctuation-only
        let stripped = lower.filter { $0.isLetter }
        if stripped.count <= 2 { return true }
        return false
    }

    init(messenger: FlutterBinaryMessenger) {
        methodChannel = FlutterMethodChannel(
            name: "com.agentic_ai/whisperkit_stt",
            binaryMessenger: messenger
        )
        transcriptEventChannel = FlutterEventChannel(
            name: "com.agentic_ai/whisperkit_transcripts",
            binaryMessenger: messenger
        )

        super.init()

        transcriptEventChannel.setStreamHandler(self)
        methodChannel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

    // MARK: - FlutterStreamHandler

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        transcriptEventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        transcriptEventSink = nil
        return nil
    }

    // MARK: - Method handling

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initialize":
            let args = call.arguments as? [String: Any] ?? [:]
            handleInitialize(modelSize: args["modelSize"] as? String ?? "base", result: result)
        case "isModelAvailable":
            let args = call.arguments as? [String: Any] ?? [:]
            handleIsModelAvailable(modelSize: args["modelSize"] as? String ?? "base", result: result)
        case "startTranscription":
            handleStartTranscription(result: result)
        case "feedAudio":
            let args = call.arguments as? [String: Any] ?? [:]
            if let audioData = args["audio"] as? FlutterStandardTypedData {
                handleFeedAudio(audio: audioData.data, result: result)
            } else {
                result(FlutterError(code: "BAD_ARGS", message: "Missing audio data", details: nil))
            }
        case "stopTranscription":
            handleStopTranscription(result: result)
        case "notifyPlaybackEnded":
            handleNotifyPlaybackEnded(result: result)
        case "flushAudioBuffer":
            handleFlushAudioBuffer(result: result)
        case "dispose":
            handleDispose(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func modelDirectoryName(for modelSize: String) -> String {
        if modelSize == "large-v3-turbo" { return "openai_whisper-large-v3_turbo" }
        return "openai_whisper-\(modelSize)"
    }

    private func handleIsModelAvailable(modelSize: String, result: @escaping FlutterResult) {
        let dirName = modelDirectoryName(for: modelSize)
        let bundle = Bundle.main
        let modelPath = bundle.bundlePath + "/Contents/Resources/models/whisperkit/\(dirName)"
        let exists = FileManager.default.fileExists(atPath: modelPath)
        result(exists)
    }

    private func handleInitialize(modelSize: String, result: @escaping FlutterResult) {
        #if canImport(WhisperKit)
        processingQueue.async { [weak self] in
            guard let self = self else { return }

            let dirName = self.modelDirectoryName(for: modelSize)
            let bundle = Bundle.main
            let modelPath = bundle.bundlePath + "/Contents/Resources/models/whisperkit/\(dirName)"

            NSLog("[WhisperKit] Loading model from: \(modelPath)")

            Task {
                do {
                    let kit = try await WhisperKit(
                        modelFolder: modelPath,
                        computeOptions: ModelComputeOptions(
                            audioEncoderCompute: .cpuAndNeuralEngine,
                            textDecoderCompute: .cpuAndNeuralEngine
                        )
                    )
                    self.whisperKit = kit
                    self.currentModelPath = modelPath
                    self.isInitialized = true

                    DispatchQueue.main.async {
                        NSLog("[WhisperKit] Initialized with model: \(modelSize)")
                        result(true)
                    }
                } catch {
                    DispatchQueue.main.async {
                        NSLog("[WhisperKit] Init failed: \(error)")
                        result(false)
                    }
                }
            }
        }
        #else
        NSLog("[WhisperKit] WhisperKit not available in this build")
        result(false)
        #endif
    }

    private func handleStartTranscription(result: @escaping FlutterResult) {
        guard isInitialized else {
            result(FlutterError(code: "NOT_INIT", message: "WhisperKit not initialized", details: nil))
            return
        }

        isTranscribing = true
        isProcessing = false
        consecutiveAneFailures = 0
        lastTranscriptText = ""
        bufferLock.lock()
        audioBuffer = Data()
        carryOverBuffer = Data()
        bufferLock.unlock()

        transcriptionTimer = Timer.scheduledTimer(
            withTimeInterval: Double(WhisperKitChannel.transcriptionIntervalMs) / 1000.0,
            repeats: true
        ) { [weak self] _ in
            self?.processBufferedAudio()
        }

        NSLog("[WhisperKit] Transcription started (interval=%dms, resample 24kHz→16kHz)",
              WhisperKitChannel.transcriptionIntervalMs)
        result(nil)
    }

    private func handleFeedAudio(audio: Data, result: @escaping FlutterResult) {
        guard isTranscribing else {
            result(nil)
            return
        }

        bufferLock.lock()
        audioBuffer.append(audio)
        bufferLock.unlock()

        result(nil)
    }

    /// Reset the transcription timer so the next processing happens at a
    /// predictable offset from now.  Called when TTS playback ends so the
    /// first post-TTS buffer is processed as soon as enough audio has
    /// accumulated rather than waiting for the old timer cycle to align.
    private func handleNotifyPlaybackEnded(result: @escaping FlutterResult) {
        guard isTranscribing else {
            result(nil)
            return
        }

        // Flush any audio that leaked through suppression gaps during TTS —
        // it's contaminated with echo and must not be transcribed.
        bufferLock.lock()
        let flushedBytes = audioBuffer.count + carryOverBuffer.count
        audioBuffer = Data()
        carryOverBuffer = Data()
        bufferLock.unlock()

        transcriptionTimer?.invalidate()
        let interval = Double(WhisperKitChannel.transcriptionIntervalMs) / 1000.0
        transcriptionTimer = Timer.scheduledTimer(
            withTimeInterval: interval, repeats: true
        ) { [weak self] _ in
            self?.processBufferedAudio()
        }
        NSLog("[WhisperKit] Timer reset after playback ended — flushed %d bytes of echo-contaminated audio (next tick in %.1fs)", flushedBytes, interval)
        result(nil)
    }

    /// Flush the audio buffer without resetting the transcription timer.
    /// Called on ghost onPlaybackComplete events to discard echo that leaked
    /// through gaps in native suppression.
    private func handleFlushAudioBuffer(result: @escaping FlutterResult) {
        bufferLock.lock()
        let flushedBytes = audioBuffer.count + carryOverBuffer.count
        audioBuffer = Data()
        carryOverBuffer = Data()
        bufferLock.unlock()
        if flushedBytes > 0 {
            NSLog("[WhisperKit] Ghost flush: discarded %d bytes of echo audio", flushedBytes)
        }
        result(nil)
    }

    private func processBufferedAudio() {
        #if canImport(WhisperKit)
        guard let kit = whisperKit, isTranscribing, !isProcessing else { return }

        bufferLock.lock()
        guard audioBuffer.count > 0 else {
            bufferLock.unlock()
            return
        }
        // Only prepend carry-over if the previous window had real speech.
        // If the last transcript was empty/hallucination, the carry-over is
        // stale silence that would cause WhisperKit to re-hallucinate the
        // same text and strip the first word of real speech via dedup.
        let audioData: Data
        if lastTranscriptWasEmpty {
            carryOverBuffer = Data()
            audioData = audioBuffer
        } else {
            audioData = carryOverBuffer + audioBuffer
        }
        audioBuffer = Data()
        bufferLock.unlock()

        let floatSamples = pcm16ToFloat16k(audioData)

        guard floatSamples.count >= WhisperKitChannel.minSamplesForTranscription else {
            bufferLock.lock()
            audioBuffer.insert(contentsOf: audioData, at: 0)
            bufferLock.unlock()
            return
        }

        // Save the tail as carry-over for the next cycle.
        let co = WhisperKitChannel.carryOverBytes
        if audioData.count > co {
            carryOverBuffer = audioData.suffix(co)
        } else {
            carryOverBuffer = audioData
        }

        isProcessing = true
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            Task {
                do {
                    let results = try await kit.transcribe(audioArray: floatSamples)
                    let text = results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

                    DispatchQueue.main.async {
                        self.consecutiveAneFailures = 0
                        self.isProcessing = false
                    }

                    let hallucination = self.isLikelyHallucination(text)
                    let prevWasEmpty = self.lastTranscriptWasEmpty

                    if !text.isEmpty && !hallucination {
                        // Only dedup against previous if the previous was real speech.
                        // If previous was a hallucination, skip dedup — the carry-over
                        // was stale silence and should not strip the first real word.
                        let dedupedText = prevWasEmpty
                            ? text
                            : self.deduplicateCarryOver(text)
                        if !dedupedText.isEmpty {
                            DispatchQueue.main.async {
                                self.lastTranscriptWasEmpty = false
                                self.lastTranscriptText = dedupedText
                                self.transcriptEventSink?([
                                    "text": dedupedText,
                                    "isFinal": true,
                                    "language": "en"
                                ])
                            }
                        } else {
                            DispatchQueue.main.async {
                                self.lastTranscriptWasEmpty = true
                            }
                        }
                    } else {
                        // Empty or hallucination — emit for Dart-side filtering
                        // but mark as empty so carry-over gets cleared next cycle.
                        DispatchQueue.main.async {
                            self.lastTranscriptWasEmpty = true
                            if !text.isEmpty {
                                self.transcriptEventSink?([
                                    "text": text,
                                    "isFinal": true,
                                    "language": "en"
                                ])
                            }
                        }
                    }
                } catch {
                    let isAneTimeout = "\(error)".contains("ANE") || "\(error)".contains("Timeout occurred while computing")
                    NSLog("[WhisperKit] Transcription error (aneTimeout=%d): %@",
                          isAneTimeout ? 1 : 0, "\(error)")

                    DispatchQueue.main.async {
                        self.bufferLock.lock()
                        self.audioBuffer.insert(contentsOf: audioData, at: 0)
                        let maxBytes = 3 * Int(WhisperKitChannel.inputSampleRate) * 2
                        if self.audioBuffer.count > maxBytes {
                            self.audioBuffer = self.audioBuffer.suffix(maxBytes)
                        }
                        self.bufferLock.unlock()

                        if isAneTimeout {
                            self.consecutiveAneFailures += 1
                            NSLog("[WhisperKit] Consecutive ANE failures: %d/%d",
                                  self.consecutiveAneFailures,
                                  WhisperKitChannel.maxAneFailuresBeforeCpuFallback)

                            if self.consecutiveAneFailures >= WhisperKitChannel.maxAneFailuresBeforeCpuFallback {
                                self.rebuildWithCpuFallback()
                                return
                            }
                        }

                        self.isProcessing = false
                    }
                }
            }
        }
        #endif
    }

    private func rebuildWithCpuFallback() {
        #if canImport(WhisperKit)
        guard let modelPath = currentModelPath else { return }

        NSLog("[WhisperKit] ANE unstable — rebuilding with CPU-only compute")
        transcriptEventSink?([
            "text": "",
            "isFinal": true,
            "language": "en",
            "warning": "ANE timeout — falling back to CPU transcription"
        ])

        isProcessing = true
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            Task {
                do {
                    let kit = try await WhisperKit(
                        modelFolder: modelPath,
                        computeOptions: ModelComputeOptions(
                            audioEncoderCompute: .cpuOnly,
                            textDecoderCompute: .cpuOnly
                        )
                    )
                    DispatchQueue.main.async {
                        self.whisperKit = kit
                        self.consecutiveAneFailures = 0
                        self.isProcessing = false
                        NSLog("[WhisperKit] Rebuilt with CPU-only compute — transcription resumed")
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isProcessing = false
                        NSLog("[WhisperKit] CPU fallback rebuild failed: %@", "\(error)")
                    }
                }
            }
        }
        #endif
    }

    /// Convert PCM16 at 24kHz to Float32 at 16kHz via linear interpolation.
    private func pcm16ToFloat16k(_ data: Data) -> [Float] {
        let srcCount = data.count / 2
        guard srcCount > 0 else { return [] }

        let ratio = WhisperKitChannel.inputSampleRate / WhisperKitChannel.whisperSampleRate
        let dstCount = Int(Double(srcCount) / ratio)
        guard dstCount > 0 else { return [] }

        var floats = [Float](repeating: 0, count: dstCount)
        data.withUnsafeBytes { buffer in
            let src = buffer.bindMemory(to: Int16.self)
            for i in 0..<dstCount {
                let srcPos = Double(i) * ratio
                let idx = Int(srcPos)
                let frac = Float(srcPos - Double(idx))
                let s0 = Float(src[min(idx, srcCount - 1)]) / Float(Int16.max)
                let s1 = Float(src[min(idx + 1, srcCount - 1)]) / Float(Int16.max)
                floats[i] = s0 + frac * (s1 - s0)
            }
        }
        return floats
    }

    /// Strip leading text that was already emitted in the previous transcript,
    /// caused by carry-over audio being re-transcribed.
    private func deduplicateCarryOver(_ text: String) -> String {
        guard !lastTranscriptText.isEmpty else { return text }

        let prevWords = lastTranscriptText.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        let currWords = text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        guard !prevWords.isEmpty, !currWords.isEmpty else { return text }

        // Find the longest suffix of prevWords that matches a prefix of currWords.
        let maxOverlap = min(prevWords.count, currWords.count)
        var overlapLen = 0
        for len in (1...maxOverlap).reversed() {
            let prevSuffix = Array(prevWords.suffix(len))
            let currPrefix = Array(currWords.prefix(len))
            if prevSuffix == currPrefix {
                overlapLen = len
                break
            }
        }

        if overlapLen == 0 { return text }

        // If the entire current text is a repeat of the previous tail, drop it.
        if overlapLen == currWords.count {
            NSLog("[WhisperKit] Carry-over dedup: entire transcript is repeat, dropping")
            return ""
        }

        // Strip the overlapping prefix from the original (preserving casing).
        let origWords = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        let remaining = Array(origWords.dropFirst(overlapLen)).joined(separator: " ")
        NSLog("[WhisperKit] Carry-over dedup: stripped %d overlapping words", overlapLen)
        return remaining
    }

    private func handleStopTranscription(result: @escaping FlutterResult) {
        isTranscribing = false
        transcriptionTimer?.invalidate()
        transcriptionTimer = nil

        bufferLock.lock()
        audioBuffer = Data()
        carryOverBuffer = Data()
        bufferLock.unlock()

        NSLog("[WhisperKit] Transcription stopped")
        result(nil)
    }

    private func handleDispose(result: @escaping FlutterResult) {
        isTranscribing = false
        transcriptionTimer?.invalidate()
        transcriptionTimer = nil

        #if canImport(WhisperKit)
        whisperKit = nil
        #endif

        isInitialized = false
        NSLog("[WhisperKit] Disposed")
        result(nil)
    }

    func cleanup() {
        isTranscribing = false
        transcriptionTimer?.invalidate()
        transcriptionTimer = nil
        #if canImport(WhisperKit)
        whisperKit = nil
        #endif
        isInitialized = false
    }
}
