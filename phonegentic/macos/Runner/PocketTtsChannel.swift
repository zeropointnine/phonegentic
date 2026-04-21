import Cocoa
import FlutterMacOS

/// MethodChannel + EventChannel bridge for Pocket TTS on-device synthesis.
///
/// Channel names:
///   - MethodChannel:  com.agentic_ai/pocket_tts
///   - EventChannel:   com.agentic_ai/pocket_tts_audio
///
/// Methods:
///   - isModelAvailable    → checks if model files exist
///   - initialize          → loads ONNX sessions and tokenizer
///   - setVoice(voice:)    → sets active voice by name
///   - setGainOverride(gain:) → overrides post-synthesis gain
///   - synthesize(text:, voice:) → streams PCM16 24kHz chunks via EventChannel
///   - warmup(voice:)      → primes ONNX sessions, discards audio
///   - encodeVoice(pcm:, voiceId:) → encodes a PCM16 clip into a cloned voice
///   - exportVoiceEmbedding(voiceId:) → serializes a voice embedding
///   - importVoiceEmbedding(voiceId:, data:) → deserializes a voice embedding
///   - dispose             → releases ONNX resources
#if os(macOS)
class PocketTtsChannel: NSObject, FlutterStreamHandler {
    private let methodChannel: FlutterMethodChannel
    private let audioEventChannel: FlutterEventChannel
    private var audioEventSink: FlutterEventSink?

    private var engine: PocketTtsEngine?
    private var isInitialized = false
    private let synthesisQueue = DispatchQueue(label: "com.agentic_ai.pocket_tts", qos: .userInitiated)

    init(messenger: FlutterBinaryMessenger) {
        methodChannel = FlutterMethodChannel(
            name: "com.agentic_ai/pocket_tts",
            binaryMessenger: messenger
        )
        audioEventChannel = FlutterEventChannel(
            name: "com.agentic_ai/pocket_tts_audio",
            binaryMessenger: messenger
        )

        super.init()

        audioEventChannel.setStreamHandler(self)
        methodChannel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

    // MARK: - FlutterStreamHandler

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        audioEventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        audioEventSink = nil
        return nil
    }

    // MARK: - Method dispatch

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isModelAvailable":
            handleIsModelAvailable(result: result)
        case "initialize":
            handleInitialize(result: result)
        case "setVoice":
            let args = call.arguments as? [String: Any] ?? [:]
            handleSetVoice(voice: args["voice"] as? String ?? "", result: result)
        case "setGainOverride":
            let args = call.arguments as? [String: Any] ?? [:]
            handleSetGainOverride(gain: args["gain"] as? Double ?? 75.0, result: result)
        case "synthesize":
            let args = call.arguments as? [String: Any] ?? [:]
            handleSynthesize(
                text: args["text"] as? String ?? "",
                voice: args["voice"] as? String ?? "",
                result: result
            )
        case "warmup":
            let args = call.arguments as? [String: Any] ?? [:]
            handleWarmup(voice: args["voice"] as? String ?? "", result: result)
        case "encodeVoice":
            let args = call.arguments as? [String: Any] ?? [:]
            handleEncodeVoice(
                pcm: (args["audioData"] as? FlutterStandardTypedData)?.data ?? Data(),
                voiceId: args["voiceId"] as? String ?? "",
                result: result
            )
        case "exportVoiceEmbedding":
            let args = call.arguments as? [String: Any] ?? [:]
            handleExportVoiceEmbedding(voiceId: args["voiceId"] as? String ?? "", result: result)
        case "importVoiceEmbedding":
            let args = call.arguments as? [String: Any] ?? [:]
            handleImportVoiceEmbedding(
                voiceId: args["voiceId"] as? String ?? "",
                data: (args["embeddingData"] as? FlutterStandardTypedData)?.data ?? Data(),
                result: result
            )
        case "dispose":
            handleDispose(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Handlers

    private func modelsDir() -> String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources")
            .appendingPathComponent("models/pocket-tts-onnx")
            .path
    }

    private func handleIsModelAvailable(result: @escaping FlutterResult) {
        result(PocketTtsEngine.isModelAvailable(atDir: modelsDir()))
    }

    private func handleInitialize(result: @escaping FlutterResult) {
        synthesisQueue.async { [weak self] in
            guard let self = self else { return }

            let eng = PocketTtsEngine()
            let dir = self.modelsDir()
            NSLog("[PocketTTS] Loading models from: \(dir)")
            let ok = eng.initialize(withModelsDir: dir)
            if ok {
                self.engine = eng
                self.isInitialized = true
                NSLog("[PocketTTS] Initialized successfully")
            } else {
                NSLog("[PocketTTS] Initialization failed")
            }
            DispatchQueue.main.async { result(ok) }
        }
    }

    private func handleSetVoice(voice: String, result: @escaping FlutterResult) {
        guard isInitialized, let eng = engine else {
            result(FlutterError(code: "NOT_INIT", message: "Pocket TTS not initialized", details: nil))
            return
        }
        eng.setVoice(voice)
        result(true)
    }

    private func handleSetGainOverride(gain: Double, result: @escaping FlutterResult) {
        engine?.setGainOverride(Float(gain))
        result(nil)
    }

    private func handleSynthesize(text: String, voice: String, result: @escaping FlutterResult) {
        guard isInitialized, let eng = engine else {
            result(FlutterError(code: "NOT_INIT", message: "Pocket TTS not initialized", details: nil))
            return
        }

        synthesisQueue.async { [weak self] in
            guard let self = self else { return }

            NSLog("[PocketTTS] Synthesizing \(text.count) chars with voice '\(voice)'")
            let start = CFAbsoluteTimeGetCurrent()

            let chunkSize = 4800
            eng.synthesizeStreaming(text, voice: voice) { [weak self] pcmChunk in
                guard let self = self else { return }
                var offset = 0
                while offset < pcmChunk.count {
                    let end = min(offset + chunkSize, pcmChunk.count)
                    let slice = pcmChunk.subdata(in: offset..<end)
                    DispatchQueue.main.async {
                        self.audioEventSink?(FlutterStandardTypedData(bytes: slice))
                    }
                    offset = end
                }
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - start
            NSLog("[PocketTTS] Synthesis complete: \(String(format: "%.3f", elapsed))s")
            DispatchQueue.main.async { result(nil) }
        }
    }

    private func handleWarmup(voice: String, result: @escaping FlutterResult) {
        guard isInitialized, let eng = engine else {
            result(nil)
            return
        }
        synthesisQueue.async {
            NSLog("[PocketTTS] Warmup (discarding PCM)...")
            let start = CFAbsoluteTimeGetCurrent()
            _ = eng.synthesize(".", voice: voice)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            NSLog("[PocketTTS] Warmup complete: \(String(format: "%.3f", elapsed))s")
            DispatchQueue.main.async { result(nil) }
        }
    }

    private func handleEncodeVoice(pcm: Data, voiceId: String, result: @escaping FlutterResult) {
        guard isInitialized, let eng = engine else {
            result(FlutterError(code: "NOT_INIT", message: "Pocket TTS not initialized", details: nil))
            return
        }
        synthesisQueue.async {
            let ok = eng.encodeVoice(pcm, voiceId: voiceId)
            DispatchQueue.main.async { result(ok) }
        }
    }

    private func handleExportVoiceEmbedding(voiceId: String, result: @escaping FlutterResult) {
        guard isInitialized, let eng = engine else {
            result(FlutterError(code: "NOT_INIT", message: "Pocket TTS not initialized", details: nil))
            return
        }
        if let data = eng.exportVoiceEmbedding(voiceId) {
            result(FlutterStandardTypedData(bytes: data))
        } else {
            result(nil)
        }
    }

    private func handleImportVoiceEmbedding(voiceId: String, data: Data, result: @escaping FlutterResult) {
        guard isInitialized, let eng = engine else {
            result(FlutterError(code: "NOT_INIT", message: "Pocket TTS not initialized", details: nil))
            return
        }
        let ok = eng.importVoiceEmbedding(voiceId, data: data)
        result(ok)
    }

    private func handleDispose(result: @escaping FlutterResult) {
        engine?.dispose()
        engine = nil
        isInitialized = false
        NSLog("[PocketTTS] Disposed")
        result(nil)
    }
}
#endif
