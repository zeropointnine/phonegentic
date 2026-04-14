import Foundation

/// Standalone Goertzel-based voicemail beep tone detector.
///
/// Processes successive audio frames (typically 10ms each) and fires callbacks
/// when a sustained pure tone matching common voicemail beep frequencies is
/// detected or ends. Platform-agnostic — operates on Float sample arrays.
///
/// Usage:
///   let detector = BeepDetector()
///   detector.onBeepDetected = { ... }
///   detector.onBeepEnded = { ... }
///   // In your audio render callback:
///   detector.process(buffer: floatPtr, frames: frameCount, sampleRate: 48000)
final class BeepDetector {

    /// Fired (on calling thread) when a sustained beep tone is first confirmed.
    var onBeepDetected: (() -> Void)?

    /// Fired (on calling thread) when a confirmed beep tone ends.
    var onBeepEnded: (() -> Void)?

    /// Standard voicemail beep frequencies to scan.
    /// Covers US dial tone (440+480), SIT tones (620, 950, 1400),
    /// common record tones (850, 1000).
    private let goertzelFreqs: [Float] = [440, 480, 620, 850, 950, 1000, 1400]

    /// Consecutive frames where a pure tone was detected.
    private var toneFrameCount: Int = 0

    /// Minimum consecutive tone frames to confirm a beep (40 x 10ms = 400ms).
    /// Voicemail beeps are typically 0.5-2s; short DTMF tones won't reach this.
    private static let toneConfirmFrames = 40

    /// True while a confirmed tone is ongoing — prevents duplicate callbacks.
    private(set) var toneActive = false

    /// Reset detector state (e.g. between calls).
    func reset() {
        toneFrameCount = 0
        toneActive = false
    }

    /// Process a single audio frame. Call once per WebRTC render callback
    /// (~10ms of audio). Fires callbacks synchronously on the calling thread.
    ///
    /// - Parameters:
    ///   - buffer: Pointer to Float samples (mono channel 0).
    ///   - frames: Number of samples in the buffer.
    ///   - sampleRate: Sample rate in Hz (e.g. 48000, 8000).
    func process(buffer: UnsafePointer<Float>, frames: Int, sampleRate: Float) {
        guard frames > 0 else { return }

        var totalEnergy: Float = 0
        for i in 0..<frames {
            totalEnergy += buffer[i] * buffer[i]
        }

        guard totalEnergy > 500.0 * Float(frames) else {
            endToneIfActive()
            return
        }

        var isTone = false
        for freq in goertzelFreqs {
            let mag = goertzelMagnitude(buf: buffer, frames: frames, freq: freq, rate: sampleRate)
            if mag > totalEnergy * 0.60 {
                isTone = true
                break
            }
        }

        if isTone {
            toneFrameCount += 1
            if toneFrameCount == Self.toneConfirmFrames && !toneActive {
                toneActive = true
                NSLog("[BeepDetector] Beep tone DETECTED (sustained %dms)", toneFrameCount * 10)
                onBeepDetected?()
            }
        } else {
            endToneIfActive()
        }
    }

    // MARK: - Goertzel Algorithm

    /// Compute energy at a single frequency from N samples.
    /// Cost: ~5 multiply-adds per sample — negligible for 80-sample frames.
    @inline(__always)
    private func goertzelMagnitude(buf: UnsafePointer<Float>, frames: Int, freq: Float, rate: Float) -> Float {
        let k = Float(frames) * freq / rate
        let w = 2.0 * Float.pi * k / Float(frames)
        let coeff = 2.0 * cosf(w)
        var s1: Float = 0, s2: Float = 0
        for i in 0..<frames {
            let s0 = buf[i] + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        return s1 * s1 + s2 * s2 - coeff * s1 * s2
    }

    private func endToneIfActive() {
        if toneActive {
            NSLog("[BeepDetector] Beep tone ENDED after %dms", toneFrameCount * 10)
            toneActive = false
            onBeepEnded?()
        }
        toneFrameCount = 0
    }
}
