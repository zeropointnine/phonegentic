import Foundation

/// Stateless logarithmic waveshaping compressor for real-time audio.
///
/// Pushes quiet samples toward full scale on a logarithmic curve while
/// keeping peaks controlled. No attack/release state, no lookahead —
/// just a per-sample transfer function that's safe for any block size.
///
/// Ported from https://github.com/zeropointnine/wave-edit/blob/master/simple_compressor.py
///
/// Operates on Float buffers in **int16 range** (-32768…32767) to match
/// the WebRTC `RTCAudioBuffer` format used throughout this project.
final class SimpleCompressor {

    /// Compression strength: 0.0 = no effect, 1.0 = maximum compression.
    /// Values above 1.0 are allowed for extreme squashing.
    var strength: Float

    init(strength: Float = 0.6) {
        self.strength = strength
    }

    /// Process audio in-place.
    ///
    /// Formula (on normalized -1…1 signal):
    ///   exponent = (1 - strength) * 2 + 0.5
    ///   out = sign(in) * (1 - (1 - |in|)^exponent)
    ///
    /// - Parameters:
    ///   - buf: Mutable pointer to Float samples in int16 range.
    ///   - frames: Number of samples to process.
    @inline(__always)
    func process(_ buf: UnsafeMutablePointer<Float>, frames: Int) {
        let s = strength
        if s == 0.5 { return }  // exponent 1.0 → linear identity

        let invScale: Float = 1.0 / 32768.0
        let scale: Float = 32768.0
        let exponent = (1.0 - s) * 2.0 + 0.5

        for i in 0..<frames {
            let raw = buf[i] * invScale
            let absVal = min(abs(raw), 1.0 - 1e-7)
            let compressed = 1.0 - powf(1.0 - absVal, exponent)
            buf[i] = copysignf(compressed, raw) * scale
        }
    }
}
