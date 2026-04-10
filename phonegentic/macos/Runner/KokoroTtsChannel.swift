import Cocoa
import FlutterMacOS

#if canImport(KokoroSwift)
import KokoroSwift
import MLX
#endif

/// MethodChannel + EventChannel bridge for Kokoro on-device TTS.
///
/// Channel names:
///   - MethodChannel:  com.agentic_ai/kokoro_tts
///   - EventChannel:   com.agentic_ai/kokoro_tts_audio
///
/// Methods:
///   - initialize      → loads model weights from app bundle
///   - isModelAvailable → checks if model files exist
///   - setVoice(voice:) → sets the voice style embedding
///   - synthesize(text:, voice:) → generates PCM16 24kHz audio
///   - dispose          → releases model resources
class KokoroTtsChannel: NSObject, FlutterStreamHandler {
    private let methodChannel: FlutterMethodChannel
    private let audioEventChannel: FlutterEventChannel
    private var audioEventSink: FlutterEventSink?

    #if canImport(KokoroSwift)
    private var ttsEngine: KokoroTTS?
    private var currentVoice: MLXArray?
    private var voiceStyles: [String: MLXArray] = [:]
    #endif

    private var isInitialized = false
    private let synthesisQueue = DispatchQueue(label: "com.agentic_ai.kokoro_tts", qos: .userInitiated)

    init(messenger: FlutterBinaryMessenger) {
        methodChannel = FlutterMethodChannel(
            name: "com.agentic_ai/kokoro_tts",
            binaryMessenger: messenger
        )
        audioEventChannel = FlutterEventChannel(
            name: "com.agentic_ai/kokoro_tts_audio",
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

    // MARK: - Method handling

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initialize":
            handleInitialize(result: result)
        case "isModelAvailable":
            handleIsModelAvailable(result: result)
        case "setVoice":
            let args = call.arguments as? [String: Any] ?? [:]
            handleSetVoice(voice: args["voice"] as? String ?? "af_heart", result: result)
        case "synthesize":
            let args = call.arguments as? [String: Any] ?? [:]
            handleSynthesize(
                text: args["text"] as? String ?? "",
                voice: args["voice"] as? String ?? "af_heart",
                result: result
            )
        case "dispose":
            handleDispose(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func handleIsModelAvailable(result: @escaping FlutterResult) {
        #if canImport(KokoroSwift)
        let bundle = Bundle.main
        let hasWeights = bundle.url(forResource: "kokoro-v1_0", withExtension: "safetensors") != nil
            || FileManager.default.fileExists(atPath: bundle.bundlePath + "/Contents/Resources/models/kokoro/kokoro-v1_0.safetensors")
        result(hasWeights)
        #else
        result(false)
        #endif
    }

    private func handleInitialize(result: @escaping FlutterResult) {
        #if canImport(KokoroSwift)
        synthesisQueue.async { [weak self] in
            guard let self = self else { return }

            let bundle = Bundle.main
            var modelDir: URL
            if let url = bundle.url(forResource: "models/kokoro", withExtension: nil) {
                modelDir = url
            } else {
                modelDir = URL(fileURLWithPath: bundle.bundlePath)
                    .appendingPathComponent("Contents/Resources/models/kokoro")
            }

            let weightsFile = modelDir.appendingPathComponent("kokoro-v1_0.safetensors")
            guard FileManager.default.fileExists(atPath: weightsFile.path) else {
                NSLog("[KokoroTTS] Weight file not found at \(weightsFile.path)")
                DispatchQueue.main.async { result(false) }
                return
            }

            NSLog("[KokoroTTS] Loading model from: \(weightsFile.path)")

            self.ttsEngine = KokoroTTS(modelPath: weightsFile, g2p: .misaki)
            self.isInitialized = true

            self.loadVoiceStyles(from: modelDir)

            DispatchQueue.main.async {
                NSLog("[KokoroTTS] Initialized successfully")
                result(true)
            }
        }
        #else
        NSLog("[KokoroTTS] KokoroSwift not available in this build")
        result(false)
        #endif
    }

    #if canImport(KokoroSwift)
    private func loadVoiceStyles(from directory: URL) {
        let voicesDir = directory.appendingPathComponent("voices")
        let fm = FileManager.default
        guard fm.fileExists(atPath: voicesDir.path) else {
            NSLog("[KokoroTTS] No voices/ directory found at \(voicesDir.path)")
            return
        }
        guard let files = try? fm.contentsOfDirectory(atPath: voicesDir.path) else { return }
        for file in files where file.hasSuffix(".safetensors") {
            let name = String(file.dropLast(".safetensors".count))
            let url = voicesDir.appendingPathComponent(file)
            do {
                let arrays = try MLX.loadArrays(url: url)
                if let embedding = arrays.values.first {
                    voiceStyles[name] = embedding
                }
            } catch {
                NSLog("[KokoroTTS] Failed to load voice \(name): \(error)")
            }
        }
        NSLog("[KokoroTTS] Loaded \(voiceStyles.count) voice styles from voices/")
    }
    #endif

    private func handleSetVoice(voice: String, result: @escaping FlutterResult) {
        #if canImport(KokoroSwift)
        if let embedding = voiceStyles[voice] {
            currentVoice = embedding
            NSLog("[KokoroTTS] Voice set to: \(voice)")
            result(true)
        } else {
            NSLog("[KokoroTTS] Voice '\(voice)' not found in loaded styles")
            result(false)
        }
        #else
        result(false)
        #endif
    }

    private func handleSynthesize(text: String, voice: String, result: @escaping FlutterResult) {
        #if canImport(KokoroSwift)
        guard isInitialized, let engine = ttsEngine else {
            result(FlutterError(code: "NOT_INIT", message: "Kokoro TTS not initialized", details: nil))
            return
        }

        // Select voice embedding
        let voiceEmbedding = voiceStyles[voice] ?? currentVoice
        guard let embedding = voiceEmbedding else {
            result(FlutterError(code: "NO_VOICE", message: "No voice embedding loaded for '\(voice)'", details: nil))
            return
        }

        synthesisQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                NSLog("[KokoroTTS] Synthesizing \(text.count) chars with voice '\(voice)'...")
                let startTime = CFAbsoluteTimeGetCurrent()

                let (floatSamples, _) = try engine.generateAudio(
                    voice: embedding,
                    language: .enUS,
                    text: text
                )

                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                NSLog("[KokoroTTS] Synthesis complete: \(elapsed)s, \(floatSamples.count) samples")

                let pcmData = self.floatArrayToPCM16(floatSamples)

                // Send audio chunks via EventChannel (split into ~4800-byte chunks
                // to match the pattern used by ElevenLabs / AudioTap)
                let chunkSize = 4800
                var offset = 0
                while offset < pcmData.count {
                    let end = min(offset + chunkSize, pcmData.count)
                    let chunk = pcmData.subdata(in: offset..<end)
                    DispatchQueue.main.async {
                        self.audioEventSink?(FlutterStandardTypedData(bytes: chunk))
                    }
                    offset = end
                }

                DispatchQueue.main.async {
                    result(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    NSLog("[KokoroTTS] Synthesis error: \(error)")
                    result(FlutterError(code: "SYNTH_ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
        #else
        result(FlutterError(code: "NOT_AVAILABLE", message: "KokoroSwift not included in this build", details: nil))
        #endif
    }

    #if canImport(KokoroSwift)
    private func floatArrayToPCM16(_ floats: [Float]) -> Data {
        var pcmData = Data(capacity: floats.count * 2)
        for sample in floats {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * Float(Int16.max))
            withUnsafeBytes(of: int16.littleEndian) { pcmData.append(contentsOf: $0) }
        }
        return pcmData
    }
    #endif

    private func handleDispose(result: @escaping FlutterResult) {
        #if canImport(KokoroSwift)
        ttsEngine = nil
        currentVoice = nil
        voiceStyles.removeAll()
        #endif
        isInitialized = false
        NSLog("[KokoroTTS] Disposed")
        result(nil)
    }
}
