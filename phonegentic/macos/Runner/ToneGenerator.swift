import Foundation
import AVFoundation

/// Generates short PCM-16/Float tone bursts (DTMF, MF "Blue Box",
/// call-waiting, call-ended) and plays them locally for the operator.
///
/// Routing strategy:
///   • Local audibility: always plays through a private `AVAudioEngine`
///     so the operator hears tones whether or not a SIP call is active
///     (typing on the dialer pre-call, in-call DTMF, event tones).
///   • Recording capture: while a call is active and a recording is
///     running, we additionally feed `WebRTCAudioProcessor.ttsRecordingRing`
///     so the recorded WAV includes the tones the operator heard.
///   • Outbound call audio: tones are intentionally NOT written to the
///     capture/outbound ring. SIP DTMF still travels via signaling, and
///     the local key-feedback should not bleed into the remote's audio.
///
/// All tones are synthesised at 24 kHz mono float, matching the rate of
/// the WebRTC TTS rings and AVAudioEngine connection used here.
final class ToneGenerator {

    static let shared = ToneGenerator()

    /// Sample rate for synthesised tones. 24 kHz matches the WebRTC TTS
    /// pipeline rate so the recording-ring path is a pass-through and the
    /// engine connects cleanly.
    private static let sampleRate: Int = WebRTCAudioProcessor.ttsSourceRate

    /// Master output level for tones, expressed as a Float full-scale
    /// amplitude (engine path uses ±1.0). 0.18 ≈ −15 dBFS — comfortably
    /// audible without dominating mixed TTS or the remote voice.
    private static let amplitudeFloat: Float = 0.18

    /// Same level expressed in Int16 magnitude for the recording ring,
    /// which still expects the legacy Int16-magnitude float buffer used
    /// by WebRTCAudioProcessor's TTS path.
    private static let amplitudeInt16: Float = 32767.0 * 0.18

    private let queue = DispatchQueue(label: "com.agentic_ai.tone_generator", qos: .userInitiated)

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let format: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(WebRTCAudioProcessor.ttsSourceRate),
        channels: 1,
        interleaved: false
    )!

    /// Map of currently-held DTMF/MF keys → cancel tokens. A key being in
    /// this map means a press-and-hold tone is still running.
    private var heldKeys: [String: HeldTone] = [:]
    private let heldLock = NSLock()

    private final class HeldTone {
        var stopRequested: Bool = false
    }

    private init() {}

    // MARK: - Public API

    /// Begin a tone for [key] using [style]. Tone runs in chunks fed into
    /// AVAudioEngine until `stopTone` is called.
    func startTone(key: String, style: String) {
        let normalized = normalize(key: key)
        let token = HeldTone()

        heldLock.lock()
        heldKeys[normalized]?.stopRequested = true
        heldKeys[normalized] = token
        heldLock.unlock()

        guard let pair = frequencies(forKey: normalized, style: style) else {
            NSLog("[ToneGenerator] startTone — unknown key=%@ style=%@", normalized, style)
            return
        }

        queue.async { [weak self] in
            self?.runHeldTone(token: token, low: pair.low, high: pair.high)
        }
    }

    /// Stop a previously-started held tone. Safe to call multiple times.
    func stopTone(key: String) {
        let normalized = normalize(key: key)
        heldLock.lock()
        let token = heldKeys.removeValue(forKey: normalized)
        heldLock.unlock()
        token?.stopRequested = true
    }

    /// Stop every held tone immediately. Called when a call ends so a
    /// stuck DTMF key can't keep oscillating after teardown.
    func stopAll() {
        heldLock.lock()
        let tokens = Array(heldKeys.values)
        heldKeys.removeAll()
        heldLock.unlock()
        for t in tokens { t.stopRequested = true }
    }

    /// Fire one of the fixed event tone patterns: "callWaiting" or "callEnded".
    func playEvent(_ event: String) {
        let lower = event.lowercased()
        queue.async { [weak self] in
            switch lower {
            case "callwaiting":
                self?.playCallWaitingPattern()
            case "callended":
                self?.playCallEndedPattern()
            default:
                NSLog("[ToneGenerator] playEvent — unknown event=%@", event)
            }
        }
    }

    // MARK: - Patterns

    /// Two short 220 ms beeps at 440 Hz with a 200 ms gap.
    private func playCallWaitingPattern() {
        let beep = synthesizeTone(
            low: 0, high: 440,
            durationMs: 220, attackMs: 12, releaseMs: 18
        )
        play(beep)
        Thread.sleep(forTimeInterval: 0.420)
        play(beep)
    }

    /// Three short 180 ms beeps alternating 480 Hz / 620 Hz with 80 ms gaps.
    /// Roughly mimics the SIT/disconnect tones of legacy PSTN trunks
    /// without exactly reproducing them (we don't want to look like a
    /// real out-of-service SIT to the upstream provider).
    private func playCallEndedPattern() {
        let beepA = synthesizeTone(
            low: 0, high: 480,
            durationMs: 180, attackMs: 10, releaseMs: 16
        )
        let beepB = synthesizeTone(
            low: 0, high: 620,
            durationMs: 180, attackMs: 10, releaseMs: 16
        )
        play(beepA)
        Thread.sleep(forTimeInterval: 0.260)
        play(beepB)
        Thread.sleep(forTimeInterval: 0.260)
        play(beepA)
    }

    // MARK: - Held tone loop

    /// Runs in chunks until [token].stopRequested becomes true. Flutter
    /// is responsible for the 300 ms minimum hold time — see
    /// `ToneService.playDtmfDown/Up`.
    ///
    /// Each chunk is synthesised starting at the cumulative sample index
    /// (`sampleOffset`) instead of phase zero, so the sine waves keep
    /// running continuously across chunk boundaries. Without this, DTMF
    /// frequencies (697/770/852/941/1209/1336/1477/1633 Hz) — none of
    /// which are integer cycles per 60 ms chunk — produce a phase reset
    /// click every chunk that sounds like a 50 ms repeat. The Blue-Box
    /// MF tones happened to mask this because they're all multiples of
    /// 100 Hz, which line up with chunk boundaries by coincidence.
    ///
    /// Only the first chunk has an attack envelope; sustain chunks are
    /// fade-free (full amplitude in/out) so adjacent chunks splice
    /// seamlessly. The release tail is a separate raised-cosine fade-out.
    private func runHeldTone(token: HeldTone, low: Float, high: Float) {
        let chunkMs = 60
        var sampleOffset = 0

        let firstChunk = synthesizeTone(
            low: low, high: high,
            durationMs: chunkMs, attackMs: 12, releaseMs: 0,
            sampleOffset: sampleOffset
        )
        play(firstChunk)
        sampleOffset += firstChunk.count

        while !token.stopRequested {
            let chunk = synthesizeTone(
                low: low, high: high,
                durationMs: chunkMs, attackMs: 0, releaseMs: 0,
                sampleOffset: sampleOffset
            )
            play(chunk)
            sampleOffset += chunk.count
            // Sleep slightly less than chunk duration so the engine
            // queue stays primed without underrunning.
            Thread.sleep(forTimeInterval: Double(chunkMs - 10) / 1000.0)
        }

        let releaseChunk = synthesizeTone(
            low: low, high: high,
            durationMs: 22, attackMs: 0, releaseMs: 22,
            sampleOffset: sampleOffset
        )
        play(releaseChunk)
    }

    // MARK: - Synthesis

    /// Synthesise a [durationMs] tone as full-scale Float32 samples
    /// (range ±[Self.amplitudeFloat]). If [low] is zero, only [high] is
    /// used (single-frequency beep).
    ///
    /// The attack and release envelopes are independent raised-cosine
    /// (Hann) ramps — i.e. `0.5·(1 − cos(π·t))` — which start and end
    /// with zero slope, so the onset and release sound smooth instead
    /// of clicking the way a linear fade does. Pass `attackMs: 0` /
    /// `releaseMs: 0` to butt-splice phase-continuous sustain chunks
    /// without any envelope discontinuity.
    ///
    /// [sampleOffset] is the cumulative sample index of the first sample
    /// in the returned chunk. Held-tone playback advances this between
    /// chunks so the sine wave is phase-continuous (no clicks).
    private func synthesizeTone(
        low: Float,
        high: Float,
        durationMs: Int,
        attackMs: Int,
        releaseMs: Int,
        sampleOffset: Int = 0
    ) -> [Float] {
        let sr = Float(Self.sampleRate)
        let count = max(1, Self.sampleRate * durationMs / 1000)
        let attackCount = max(0, min(count, Self.sampleRate * attackMs / 1000))
        let releaseCount = max(0, min(count, Self.sampleRate * releaseMs / 1000))
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
            var sample = mix * Self.amplitudeFloat

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

    // MARK: - Engine + recording-ring playback

    /// Lazily start the AVAudioEngine. We use a private engine rather
    /// than piggy-backing on AudioTapChannel's because tones must keep
    /// working when the tap channel is between-calls or between buffer
    /// schedule cycles.
    ///
    /// On first start we also schedule a short silence buffer so the
    /// hardware output settles before the actual tone data arrives —
    /// otherwise the player ramping up from "no buffer scheduled" to
    /// "first tone sample" produces an audible startup tick.
    private func ensureEngine() -> Bool {
        if let e = engine, e.isRunning, player != nil { return true }

        // Tear down a stale engine if it stopped unexpectedly.
        if let e = engine {
            player?.stop()
            e.stop()
            engine = nil
            player = nil
        }

        let e = AVAudioEngine()
        let p = AVAudioPlayerNode()
        e.attach(p)
        e.connect(p, to: e.mainMixerNode, format: format)
        e.mainMixerNode.outputVolume = 1.0

        do {
            try e.start()
            p.play()
        } catch {
            NSLog("[ToneGenerator] Failed to start engine: %@", String(describing: error))
            return false
        }
        engine = e
        player = p

        // Prime the player with ~30 ms of silence so the audio device
        // has settled by the time we schedule the real tone buffer.
        if let silence = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(Self.sampleRate * 30 / 1000)
        ) {
            silence.frameLength = silence.frameCapacity
            if let chan = silence.floatChannelData?[0] {
                for i in 0..<Int(silence.frameLength) { chan[i] = 0 }
            }
            p.scheduleBuffer(silence, completionHandler: nil)
        }
        return true
    }

    /// Play [samples] both through the local engine (so the operator
    /// hears them) and, when in call mode with a recording in progress,
    /// into the TTS recording ring (so the WAV captures them too).
    private func play(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        playViaEngine(samples)
        feedRecordingRing(samples)
    }

    private func playViaEngine(_ samples: [Float]) {
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

    /// WebRTCAudioProcessor's TTS rings expect Int16-range floats (the
    /// existing render path multiplies by 32767 before writing). We
    /// replicate that scaling so the recording ring sees a consistent
    /// magnitude when it merges tones with TTS already in flight.
    private func feedRecordingRing(_ samples: [Float]) {
        let proc = WebRTCAudioProcessor.shared
        var scaled = [Float](repeating: 0, count: samples.count)
        let gain = Self.amplitudeInt16 / Self.amplitudeFloat
        for i in 0..<samples.count {
            scaled[i] = samples[i] * gain
        }
        scaled.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            proc.ttsRecordingRing.write(base, count: scaled.count)
        }
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

    /// AT&T MF "Blue Box" inband signaling tones (Bell System R1).
    /// Provided as a stylistic alternative; the SIP DTMF that's actually
    /// transmitted to the remote is unaffected.
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
        // KP (start-of-number) and ST (end-of-number) substitute for * and #.
        case "*": return ToneFreqs(low: 1100, high: 1700)
        case "#": return ToneFreqs(low: 1500, high: 1700)
        default:  return dtmfFrequencies(forKey: key)
        }
    }
}
