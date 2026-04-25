import Foundation
import AVFoundation

/// iOS tone synthesizer.  Plays DTMF / MF "Blue Box" / call-waiting /
/// call-ended tones through `AVAudioEngine` on the active audio route.
///
/// On macOS the equivalent class injects directly into the WebRTC render
/// ring buffer so tones share the call's audio path. On iOS the WebRTC
/// audio-injection pipeline is not yet implemented (see `AudioTapChannel`),
/// so we play through `AVAudioEngine`. When the iOS audio pipeline is
/// completed, this can be reworked to feed the same shared ring buffer.
final class ToneGenerator {

    static let shared = ToneGenerator()

    /// 24 kHz mono — matches the eventual TTS pipeline rate so a switch
    /// to ring-buffer injection later is a one-line change.
    private static let sampleRate: Double = 24000.0
    private static let amplitude: Float = 0.18 // -15 dBFS, full-scale Float

    private let queue = DispatchQueue(label: "com.agentic_ai.tone_generator", qos: .userInitiated)

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let format: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!

    private var heldKeys: [String: HeldTone] = [:]
    private let heldLock = NSLock()

    private final class HeldTone {
        var stopRequested: Bool = false
    }

    private init() {}

    // MARK: - Public API

    func startTone(key: String, style: String) {
        let normalized = normalize(key: key)
        let token = HeldTone()

        heldLock.lock()
        heldKeys[normalized]?.stopRequested = true
        heldKeys[normalized] = token
        heldLock.unlock()

        guard let pair = frequencies(forKey: normalized, style: style) else {
            NSLog("[ToneGenerator-iOS] startTone — unknown key=%@ style=%@", normalized, style)
            return
        }

        queue.async { [weak self] in
            self?.runHeldTone(token: token, low: pair.low, high: pair.high)
        }
    }

    func stopTone(key: String) {
        let normalized = normalize(key: key)
        heldLock.lock()
        let token = heldKeys.removeValue(forKey: normalized)
        heldLock.unlock()
        token?.stopRequested = true
    }

    func stopAll() {
        heldLock.lock()
        let tokens = Array(heldKeys.values)
        heldKeys.removeAll()
        heldLock.unlock()
        for t in tokens { t.stopRequested = true }
    }

    func playEvent(_ event: String) {
        let lower = event.lowercased()
        queue.async { [weak self] in
            switch lower {
            case "callwaiting":
                self?.playCallWaitingPattern()
            case "callended":
                self?.playCallEndedPattern()
            default:
                NSLog("[ToneGenerator-iOS] playEvent — unknown event=%@", event)
            }
        }
    }

    // MARK: - Patterns

    private func playCallWaitingPattern() {
        let beep = synthesizeTone(
            low: 0, high: 440,
            durationMs: 220, attackMs: 12, releaseMs: 18
        )
        playSamples(beep)
        Thread.sleep(forTimeInterval: 0.420)
        playSamples(beep)
    }

    private func playCallEndedPattern() {
        let beepA = synthesizeTone(
            low: 0, high: 480,
            durationMs: 180, attackMs: 10, releaseMs: 16
        )
        let beepB = synthesizeTone(
            low: 0, high: 620,
            durationMs: 180, attackMs: 10, releaseMs: 16
        )
        playSamples(beepA)
        Thread.sleep(forTimeInterval: 0.260)
        playSamples(beepB)
        Thread.sleep(forTimeInterval: 0.260)
        playSamples(beepA)
    }

    // MARK: - Held tone loop

    /// Each chunk is synthesised starting at the cumulative sample
    /// index so the sine wave is phase-continuous across chunks; without
    /// this DTMF tones (whose frequencies aren't integer cycles per
    /// chunk) produce an audible click every chunk that sounds like a
    /// rapid tone repeat.
    ///
    /// Only the first chunk has an attack envelope; sustain chunks are
    /// fade-free so adjacent chunks splice seamlessly. The release tail
    /// is a separate raised-cosine fade-out chunk.
    private func runHeldTone(token: HeldTone, low: Float, high: Float) {
        let chunkMs = 60
        var sampleOffset = 0

        let firstChunk = synthesizeTone(
            low: low, high: high,
            durationMs: chunkMs, attackMs: 12, releaseMs: 0,
            sampleOffset: sampleOffset
        )
        playSamples(firstChunk)
        sampleOffset += firstChunk.count

        while !token.stopRequested {
            let chunk = synthesizeTone(
                low: low, high: high,
                durationMs: chunkMs, attackMs: 0, releaseMs: 0,
                sampleOffset: sampleOffset
            )
            playSamples(chunk)
            sampleOffset += chunk.count
            Thread.sleep(forTimeInterval: Double(chunkMs - 10) / 1000.0)
        }

        let releaseChunk = synthesizeTone(
            low: low, high: high,
            durationMs: 22, attackMs: 0, releaseMs: 22,
            sampleOffset: sampleOffset
        )
        playSamples(releaseChunk)
    }

    // MARK: - Synthesis

    /// Independent attack/release envelopes use a raised-cosine (Hann)
    /// curve — `0.5·(1 − cos(π·t))` — which starts and ends with zero
    /// slope, so the onset/release is smooth instead of clicking the
    /// way a linear ramp does. Pass `attackMs: 0` / `releaseMs: 0` to
    /// butt-splice phase-continuous sustain chunks without an envelope
    /// discontinuity.
    ///
    /// [sampleOffset] is the cumulative sample index of the first sample
    /// in the returned chunk. Held-tone playback advances this between
    /// chunks so successive chunks are phase-continuous.
    private func synthesizeTone(
        low: Float,
        high: Float,
        durationMs: Int,
        attackMs: Int,
        releaseMs: Int,
        sampleOffset: Int = 0
    ) -> [Float] {
        let sr = Float(Self.sampleRate)
        let count = max(1, Int(Self.sampleRate) * durationMs / 1000)
        let attackCount = max(0, min(count, Int(Self.sampleRate) * attackMs / 1000))
        let releaseCount = max(0, min(count, Int(Self.sampleRate) * releaseMs / 1000))
        var out = [Float](repeating: 0, count: count)

        let two = Float(2.0 * Double.pi)
        let phaseLow = two * low / sr
        let phaseHigh = two * high / sr
        let pi = Float.pi

        for i in 0..<count {
            let f = Float(sampleOffset + i)
            let lo: Float = low > 0 ? sinf(phaseLow * f) : 0
            let hi: Float = high > 0 ? sinf(phaseHigh * f) : 0
            let mix: Float = (low > 0 && high > 0) ? (lo + hi) * 0.5 : (lo + hi)
            var sample = mix * Self.amplitude

            if attackCount > 0 && i < attackCount {
                let t = Float(i) / Float(attackCount)
                sample *= 0.5 * (1.0 - cosf(pi * t))
            }
            if releaseCount > 0 {
                let releaseStart = count - releaseCount
                if i >= releaseStart {
                    let t = Float(count - 1 - i) / Float(releaseCount)
                    sample *= 0.5 * (1.0 - cosf(pi * t))
                }
            }
            out[i] = sample
        }
        return out
    }

    /// Lazily start the engine. We also schedule a short silence buffer
    /// so the audio device has settled before the actual tone arrives —
    /// otherwise the player ramping up from "no buffer scheduled" to
    /// "first tone sample" produces an audible startup tick.
    private func ensureEngine() -> Bool {
        if let e = engine, e.isRunning, player != nil { return true }

        let e = AVAudioEngine()
        let p = AVAudioPlayerNode()
        e.attach(p)
        e.connect(p, to: e.mainMixerNode, format: format)
        e.mainMixerNode.outputVolume = 1.0

        do {
            try e.start()
            p.play()
        } catch {
            NSLog("[ToneGenerator-iOS] Failed to start engine: %@", String(describing: error))
            return false
        }
        engine = e
        player = p

        let silenceFrames = AVAudioFrameCount(Self.sampleRate * 0.030)
        if let silence = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: silenceFrames
        ) {
            silence.frameLength = silenceFrames
            if let chan = silence.floatChannelData?[0] {
                for i in 0..<Int(silence.frameLength) { chan[i] = 0 }
            }
            p.scheduleBuffer(silence, completionHandler: nil)
        }
        return true
    }

    private func playSamples(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        guard ensureEngine(), let p = player else { return }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let chan = buffer.floatChannelData?[0] {
            for i in 0..<samples.count { chan[i] = samples[i] }
        }
        p.scheduleBuffer(buffer, completionHandler: nil)
    }

    // MARK: - Frequency tables

    private struct ToneFreqs {
        let low: Float
        let high: Float
    }

    private func normalize(key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? key : String(trimmed.first!)
    }

    private func frequencies(forKey key: String, style: String) -> ToneFreqs? {
        let lowered = style.lowercased()
        if lowered == "blue" || lowered == "bluebox" || lowered == "mf" {
            return mfFrequencies(forKey: key)
        }
        return dtmfFrequencies(forKey: key)
    }

    private func dtmfFrequencies(forKey key: String) -> ToneFreqs? {
        switch key {
        case "1": return ToneFreqs(low: 697,  high: 1209)
        case "2": return ToneFreqs(low: 697,  high: 1336)
        case "3": return ToneFreqs(low: 697,  high: 1477)
        case "4": return ToneFreqs(low: 770,  high: 1209)
        case "5": return ToneFreqs(low: 770,  high: 1336)
        case "6": return ToneFreqs(low: 770,  high: 1477)
        case "7": return ToneFreqs(low: 852,  high: 1209)
        case "8": return ToneFreqs(low: 852,  high: 1336)
        case "9": return ToneFreqs(low: 852,  high: 1477)
        case "0": return ToneFreqs(low: 941,  high: 1336)
        case "*": return ToneFreqs(low: 941,  high: 1209)
        case "#": return ToneFreqs(low: 941,  high: 1477)
        case "A": return ToneFreqs(low: 697,  high: 1633)
        case "B": return ToneFreqs(low: 770,  high: 1633)
        case "C": return ToneFreqs(low: 852,  high: 1633)
        case "D": return ToneFreqs(low: 941,  high: 1633)
        default:  return nil
        }
    }

    private func mfFrequencies(forKey key: String) -> ToneFreqs? {
        switch key {
        case "1": return ToneFreqs(low: 700, high: 900)
        case "2": return ToneFreqs(low: 700, high: 1100)
        case "3": return ToneFreqs(low: 900, high: 1100)
        case "4": return ToneFreqs(low: 700, high: 1300)
        case "5": return ToneFreqs(low: 900, high: 1300)
        case "6": return ToneFreqs(low: 1100, high: 1300)
        case "7": return ToneFreqs(low: 700, high: 1500)
        case "8": return ToneFreqs(low: 900, high: 1500)
        case "9": return ToneFreqs(low: 1100, high: 1500)
        case "0": return ToneFreqs(low: 1300, high: 1500)
        case "*": return ToneFreqs(low: 1100, high: 1700)
        case "#": return ToneFreqs(low: 1500, high: 1700)
        default:  return dtmfFrequencies(forKey: key)
        }
    }
}
