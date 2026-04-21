import Foundation
import FluidAudio

/// Manages on-device speaker identification using FluidAudio's CoreML-based
/// speaker embedding extraction. Accumulates PCM16 audio from separate remote
/// and mic channels, periodically extracts embeddings, and matches them against
/// known speaker profiles stored via `SpeakerManager`.
final class SpeakerIdentifier {

    static let shared = SpeakerIdentifier()

    // MARK: - Configuration

    /// Minimum seconds of audio to accumulate before running embedding extraction.
    private let minAccumulationSeconds: Double = 3.0
    /// Target sample rate for FluidAudio (16 kHz mono Float32).
    private let targetSampleRate: Double = 16000
    /// Source sample rate from the audio pipeline (24 kHz PCM16).
    private let sourceSampleRate: Double = 24000

    // MARK: - State

    private var diarizer: DiarizerManager?
    private var models: DiarizerModels?
    private var isInitialized = false
    private var isInitializing = false

    /// Accumulated remote audio (PCM16 24 kHz).
    private var remoteBuffer = Data()
    /// Accumulated mic audio (PCM16 24 kHz).
    private var micBuffer = Data()
    private let bufferLock = NSLock()

    /// Identified remote speaker name (empty = unknown).
    private(set) var identifiedRemoteSpeaker: String = ""
    /// Identified host speaker name (empty = unknown).
    private(set) var identifiedHostSpeaker: String = ""
    /// Confidence of the most recent remote identification (0..1).
    private(set) var remoteConfidence: Double = 0
    /// Confidence of the most recent host identification (0..1).
    private(set) var hostConfidence: Double = 0

    /// Once a channel sees the same speaker twice at high confidence the
    /// identity is locked for the rest of the call. `reset()` clears locks.
    private static let lockThreshold: Double = 0.75
    private var remoteLocked = false
    private var hostLocked = false
    /// Tracks consecutive same-speaker hits needed before locking.
    private var remoteConsecutiveHits = 0
    private var hostConsecutiveHits = 0
    private var lastRemoteCandidate = ""
    private var lastHostCandidate = ""

    /// Agent TTS voiceprint for self-suppression.
    private var agentEmbedding: [Float]?
    private var agentExtractionInProgress = false
    private var agentEmbeddingAccumulated = Data()
    private let agentEmbeddingLock = NSLock()
    private static let agentAccumulationBytes = 24000 * 2 * 3 // 3 seconds at 24kHz PCM16

    /// Cached result of the last mic-vs-agent-voice check.
    private(set) var lastMicIsAgentVoice = false

    private init() {}

    // MARK: - Initialization

    func initialize() {
        guard !isInitialized && !isInitializing else { return }
        isInitializing = true

        Task {
            do {
                let m = try await DiarizerModels.downloadIfNeeded()
                let d = DiarizerManager(config: DiarizerConfig(
                    clusteringThreshold: 0.7,
                    minSpeechDuration: 1.0,
                    minSilenceGap: 0.5,
                    debugMode: false
                ))
                d.initialize(models: m)

                self.models = m
                self.diarizer = d
                self.isInitialized = true
                self.isInitializing = false
                NSLog("[SpeakerID] Initialized with FluidAudio models")
            } catch {
                self.isInitializing = false
                NSLog("[SpeakerID] Failed to initialize: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Known Speaker Management

    /// Load known speakers from embeddings passed over the MethodChannel.
    /// Each entry: { "id": String, "name": String, "embedding": [Float] }
    func loadKnownSpeakers(_ speakers: [[String: Any]]) {
        guard let diarizer = diarizer else { return }

        var fluidSpeakers: [Speaker] = []
        for s in speakers {
            guard let id = s["id"] as? String,
                  let name = s["name"] as? String,
                  let embedding = s["embedding"] as? [Double] else { continue }
            let floatEmbed = embedding.map { Float($0) }
            let speaker = Speaker(id: id, name: name, currentEmbedding: floatEmbed)
            fluidSpeakers.append(speaker)
        }

        if !fluidSpeakers.isEmpty {
            diarizer.initializeKnownSpeakers(fluidSpeakers)
            NSLog("[SpeakerID] Loaded %d known speakers", fluidSpeakers.count)
        }
    }

    // MARK: - Audio Accumulation

    /// Feed remote party PCM16 24kHz audio for embedding extraction.
    func feedRemoteAudio(_ data: Data) {
        guard isInitialized else { return }
        bufferLock.lock()
        remoteBuffer.append(data)
        bufferLock.unlock()
        checkAndProcess()
    }

    /// Feed host (mic) PCM16 24kHz audio for embedding extraction.
    func feedMicAudio(_ data: Data) {
        guard isInitialized else { return }
        bufferLock.lock()
        micBuffer.append(data)
        bufferLock.unlock()
        checkAndProcess()
    }

    /// Feed agent TTS PCM16 24kHz audio to build the agent's voiceprint
    /// for self-echo suppression.
    func feedAgentTTS(_ data: Data) {
        guard isInitialized, agentEmbedding == nil, !agentExtractionInProgress else { return }
        agentEmbeddingLock.lock()
        agentEmbeddingAccumulated.append(data)
        let ready = agentEmbeddingAccumulated.count >= SpeakerIdentifier.agentAccumulationBytes
        agentEmbeddingLock.unlock()

        if ready {
            agentExtractionInProgress = true
            extractAgentEmbedding()
        }
    }

    /// Returns true if the given audio embedding is likely the agent's own voice.
    func isAgentVoice(embedding: [Float]) -> Bool {
        guard let agent = agentEmbedding else { return false }
        let dist = cosineDistance(agent, embedding)
        return dist < 0.5
    }

    // MARK: - Extraction

    private func checkAndProcess() {
        let samplesPerSecond = Int(sourceSampleRate)
        let bytesPerSecond = samplesPerSecond * 2 // PCM16
        let minBytes = Int(Double(bytesPerSecond) * minAccumulationSeconds)

        bufferLock.lock()
        let remoteReady = remoteBuffer.count >= minBytes
        let micReady = micBuffer.count >= minBytes
        var remoteData: Data?
        var micData: Data?

        if remoteReady {
            remoteData = remoteBuffer
            remoteBuffer.removeAll(keepingCapacity: true)
        }
        if micReady {
            micData = micBuffer
            micBuffer.removeAll(keepingCapacity: true)
        }
        bufferLock.unlock()

        if let data = remoteData {
            processAudioSegment(data, isRemote: true)
        }
        if let data = micData {
            processAudioSegment(data, isRemote: false)
        }
    }

    private func processAudioSegment(_ pcm16_24k: Data, isRemote: Bool) {
        guard let diarizer = diarizer else { return }

        let samples = resampleToFloat32_16k(pcm16_24k)
        guard samples.count >= Int(targetSampleRate) else { return } // at least 1 second

        Task {
            do {
                let embedding = try diarizer.extractSpeakerEmbedding(from: samples)

                // Check against agent voiceprint first
                if self.isAgentVoice(embedding: embedding) {
                    if !isRemote {
                        self.lastMicIsAgentVoice = true
                    }
                    NSLog("[SpeakerID] Suppressed agent echo (voiceprint match, isRemote=%d)", isRemote ? 1 : 0)
                    return
                }
                if !isRemote {
                    self.lastMicIsAgentVoice = false
                }

                let result = diarizer.speakerManager.assignSpeaker(
                    embedding,
                    speechDuration: Float(samples.count) / Float(targetSampleRate),
                    confidence: 0.9
                )

                if let speaker = result {
                    let confidence = 1.0 - Double(cosineDistance(
                        speaker.currentEmbedding, embedding
                    ))

                    if isRemote {
                        if self.remoteLocked {
                            NSLog("[SpeakerID] Remote locked as %@ — ignoring %@ (conf=%.2f)",
                                  self.identifiedRemoteSpeaker, speaker.name, confidence)
                            return
                        }
                        if confidence < 0.6 {
                            NSLog("[SpeakerID] Remote low-conf ignored: %@ (conf=%.2f)", speaker.name, confidence)
                            self.lastRemoteCandidate = ""
                            self.remoteConsecutiveHits = 0
                            return
                        }
                        // Track consecutive same-speaker hits before locking.
                        if speaker.name == self.lastRemoteCandidate {
                            self.remoteConsecutiveHits += 1
                        } else {
                            self.lastRemoteCandidate = speaker.name
                            self.remoteConsecutiveHits = 1
                        }
                        self.identifiedRemoteSpeaker = speaker.name
                        self.remoteConfidence = confidence
                        if confidence >= SpeakerIdentifier.lockThreshold && self.remoteConsecutiveHits >= 2 {
                            self.remoteLocked = true
                            NSLog("[SpeakerID] Remote LOCKED: %@ (conf=%.2f, hits=%d)",
                                  speaker.name, confidence, self.remoteConsecutiveHits)
                        } else {
                            NSLog("[SpeakerID] Remote identified: %@ (conf=%.2f, hits=%d)",
                                  speaker.name, confidence, self.remoteConsecutiveHits)
                        }
                    } else {
                        if self.hostLocked {
                            NSLog("[SpeakerID] Host locked as %@ — ignoring %@ (conf=%.2f)",
                                  self.identifiedHostSpeaker, speaker.name, confidence)
                            return
                        }
                        if confidence < 0.6 {
                            NSLog("[SpeakerID] Host low-conf ignored: %@ (conf=%.2f)", speaker.name, confidence)
                            self.lastHostCandidate = ""
                            self.hostConsecutiveHits = 0
                            return
                        }
                        if speaker.name == self.lastHostCandidate {
                            self.hostConsecutiveHits += 1
                        } else {
                            self.lastHostCandidate = speaker.name
                            self.hostConsecutiveHits = 1
                        }
                        self.identifiedHostSpeaker = speaker.name
                        self.hostConfidence = confidence
                        if confidence >= SpeakerIdentifier.lockThreshold && self.hostConsecutiveHits >= 2 {
                            self.hostLocked = true
                            NSLog("[SpeakerID] Host LOCKED: %@ (conf=%.2f, hits=%d)",
                                  speaker.name, confidence, self.hostConsecutiveHits)
                        } else {
                            NSLog("[SpeakerID] Host identified: %@ (conf=%.2f, hits=%d)",
                                  speaker.name, confidence, self.hostConsecutiveHits)
                        }
                    }
                }
            } catch {
                NSLog("[SpeakerID] Embedding extraction failed: %@", error.localizedDescription)
            }
        }
    }

    private func extractAgentEmbedding() {
        guard let diarizer = diarizer else { return }

        agentEmbeddingLock.lock()
        let data = agentEmbeddingAccumulated
        agentEmbeddingLock.unlock()

        let samples = resampleToFloat32_16k(data)

        Task {
            do {
                let embedding = try diarizer.extractSpeakerEmbedding(from: samples)
                self.agentEmbedding = embedding
                NSLog("[SpeakerID] Agent voiceprint captured (%d-dim)", embedding.count)
            } catch {
                NSLog("[SpeakerID] Agent embedding failed: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Speaker Query

    /// Returns extended speaker info for the current dominant speaker:
    /// { "source": "remote"|"host", "identity": "name"|"", "confidence": Double }
    func speakerInfo(dominantSource: String) -> [String: Any] {
        let hasAgentVoiceprint = agentEmbedding != nil
        switch dominantSource {
        case "remote":
            return [
                "source": "remote",
                "identity": identifiedRemoteSpeaker,
                "confidence": remoteConfidence,
                "isAgentVoice": false,
                "hasAgentVoiceprint": hasAgentVoiceprint,
            ]
        case "host":
            return [
                "source": "host",
                "identity": identifiedHostSpeaker,
                "confidence": hostConfidence,
                "isAgentVoice": lastMicIsAgentVoice,
                "hasAgentVoiceprint": hasAgentVoiceprint,
            ]
        default:
            return [
                "source": dominantSource,
                "identity": "",
                "confidence": 0.0,
                "isAgentVoice": lastMicIsAgentVoice,
                "hasAgentVoiceprint": hasAgentVoiceprint,
            ]
        }
    }

    /// Returns the latest embedding for the identified remote speaker, if any.
    /// Used to store the voiceprint in SQLite after a call ends.
    func getRemoteSpeakerEmbedding() -> [Double]? {
        guard let diarizer = diarizer, !identifiedRemoteSpeaker.isEmpty else { return nil }
        let allIds = diarizer.speakerManager.speakerIds
        for id in allIds {
            if let speaker = diarizer.speakerManager.getSpeaker(for: id),
               speaker.name == identifiedRemoteSpeaker {
                return speaker.currentEmbedding.map { Double($0) }
            }
        }
        return nil
    }

    /// Extract and return the current embedding for the given audio segment
    /// (for storage in SQLite). Returns nil if not initialized.
    func extractEmbeddingForStorage(_ pcm16_24k: Data) -> [Float]? {
        guard let diarizer = diarizer else { return nil }
        let samples = resampleToFloat32_16k(pcm16_24k)
        guard samples.count >= Int(targetSampleRate) else { return nil }

        var result: [Float]?
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                result = try diarizer.extractSpeakerEmbedding(from: samples)
            } catch {
                NSLog("[SpeakerID] extractEmbeddingForStorage failed: %@", error.localizedDescription)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    /// Reset identification state (e.g. when a call ends).
    func reset() {
        bufferLock.lock()
        remoteBuffer.removeAll()
        micBuffer.removeAll()
        bufferLock.unlock()

        identifiedRemoteSpeaker = ""
        identifiedHostSpeaker = ""
        remoteConfidence = 0
        hostConfidence = 0
        remoteLocked = false
        hostLocked = false
        remoteConsecutiveHits = 0
        hostConsecutiveHits = 0
        lastRemoteCandidate = ""
        lastHostCandidate = ""
    }

    // MARK: - Audio Conversion

    /// Resample PCM16 24kHz mono to Float32 16kHz mono for FluidAudio.
    private func resampleToFloat32_16k(_ pcm16Data: Data) -> [Float] {
        let sampleCount = pcm16Data.count / 2
        guard sampleCount > 0 else { return [] }

        // Convert PCM16 to Float32 at source rate
        var float32 = [Float](repeating: 0, count: sampleCount)
        pcm16Data.withUnsafeBytes { raw in
            let int16s = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                float32[i] = Float(int16s[i]) / 32768.0
            }
        }

        // Downsample 24kHz -> 16kHz (ratio 2:3, linear interpolation)
        let ratio = sourceSampleRate / targetSampleRate // 1.5
        let outCount = Int(Double(sampleCount) / ratio)
        var resampled = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcIdx = Double(i) * ratio
            let lo = Int(srcIdx)
            let hi = min(lo + 1, sampleCount - 1)
            let frac = Float(srcIdx - Double(lo))
            resampled[i] = float32[lo] * (1.0 - frac) + float32[hi] * frac
        }

        return resampled
    }

    /// Cosine distance between two embeddings (0 = identical, 2 = opposite).
    private func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2.0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = (normA * normB).squareRoot()
        guard denom > 0 else { return 2.0 }
        return 1.0 - dot / denom
    }
}
