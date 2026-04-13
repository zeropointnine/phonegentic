import Foundation
import os

// MARK: - Lock-Free SPSC Ring Buffer

/// Single-producer, single-consumer ring buffer for real-time audio threads.
/// Uses UnsafeMutablePointer<Int> with OSMemoryBarrier to guarantee
/// cross-thread visibility of index updates on ARM64.
final class SPSCRingBuffer {
    private let buffer: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let _writePtr: UnsafeMutablePointer<Int>
    private let _readPtr: UnsafeMutablePointer<Int>

    init(capacity: Int) {
        self.capacity = capacity
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
        _writePtr = .allocate(capacity: 1)
        _writePtr.initialize(to: 0)
        _readPtr = .allocate(capacity: 1)
        _readPtr.initialize(to: 0)
    }

    deinit {
        buffer.deallocate()
        _writePtr.deallocate()
        _readPtr.deallocate()
    }

    @inline(__always)
    private func loadAcquire(_ ptr: UnsafeMutablePointer<Int>) -> Int {
        let val = ptr.pointee
        OSMemoryBarrier()
        return val
    }

    @inline(__always)
    private func storeRelease(_ ptr: UnsafeMutablePointer<Int>, _ val: Int) {
        OSMemoryBarrier()
        ptr.pointee = val
    }

    var availableToRead: Int {
        let w = loadAcquire(_writePtr)
        let r = _readPtr.pointee
        return w >= r ? w - r : capacity - r + w
    }

    var availableToWrite: Int {
        let w = _writePtr.pointee
        let r = loadAcquire(_readPtr)
        return capacity - 1 - (w >= r ? w - r : capacity - r + w)
    }

    @discardableResult
    func write(_ src: UnsafePointer<Float>, count: Int) -> Int {
        let space = availableToWrite
        let toWrite = min(count, space)
        if toWrite == 0 { return 0 }

        var w = _writePtr.pointee
        for i in 0..<toWrite {
            buffer[w] = src[i]
            w += 1
            if w >= capacity { w = 0 }
        }
        storeRelease(_writePtr, w)
        return toWrite
    }

    @discardableResult
    func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let avail = availableToRead
        let toRead = min(count, avail)
        if toRead == 0 { return 0 }

        var r = _readPtr.pointee
        for i in 0..<toRead {
            dst[i] = buffer[r]
            r += 1
            if r >= capacity { r = 0 }
        }
        storeRelease(_readPtr, r)
        return toRead
    }

    func reset() {
        _writePtr.pointee = 0
        _readPtr.pointee = 0
        OSMemoryBarrier()
    }
}

// MARK: - WebRTC Audio Processor

/// Hooks into flutter_webrtc's audio processing pipeline to:
/// 1. Mix AI TTS audio into the outgoing (capture) buffer → remote party hears AI
/// 2. Tap incoming (render) audio → AI agent hears remote party
/// 3. Mix AI TTS audio into the incoming (render) buffer → local user hears AI
/// 4. Tap outgoing (capture) audio → AI agent hears local user's mic
final class WebRTCAudioProcessor: NSObject {

    static let shared = WebRTCAudioProcessor()

    /// TTS source sample rate (OpenAI Realtime API sends 24 kHz PCM16)
    static let ttsSourceRate: Int = 24000

    /// Ring buffers: AI TTS PCM at native 24 kHz (float, int16 range).
    /// Stored at source rate; processors resample to their pipeline rate on read.
    /// 30 seconds — OpenAI streams full responses faster than real-time.
    let ttsCaptureRing = SPSCRingBuffer(capacity: 24000 * 30)
    let ttsRenderRing = SPSCRingBuffer(capacity: 24000 * 30)

    /// Ring buffer: remote party audio at 24 kHz from RenderPreProcessor,
    /// read by flush timer and mixed with mic audio from inputBuffer.
    let whisperRingBuffer = SPSCRingBuffer(capacity: 24000 * 2)

    /// TTS audio at 24 kHz for call recording. Fed alongside the capture/render
    /// rings in feedTTS(); drained by AudioTapChannel.flushBuffers() and mixed
    /// into the WAV file so the agent's voice is captured in recordings.
    let ttsRecordingRing = SPSCRingBuffer(capacity: 24000 * 30)

    /// Mic injection ring: float samples in int16 range at mic native rate.
    /// Fed by CoreAudio IOProc, consumed by CapturePostProcessor when WebRTC's
    /// ADM fails to deliver mic audio (e.g. SDP negotiation issues).
    let micInjectionRing = SPSCRingBuffer(capacity: 48000 * 2)
    var micSourceRate: Int = 48000

    /// When true, mic audio is zeroed in the capture path so the remote
    /// party can't hear the local user, but TTS keeps flowing and the
    /// agent's whisper feed (via CoreAudio IOProc) stays active.
    var micMuted = false

    /// When true, TTS injection and mic fallback injection are disabled in the
    /// capture/render processors to prevent ring buffer depletion across
    /// multiple peer connections (each would consume a portion, causing choppy audio).
    var conferenceMode = false

    /// Linear gain applied to the remote party's audio in the render path.
    /// Values > 1.0 boost volume; 1.0 = passthrough. Applied after whisper
    /// tap / tone detection so those see the original signal.
    var remoteGain: Float = 2.0

    /// Fired (on main thread) when a sustained beep tone is first confirmed.
    var beepDetectedCallback: (() -> Void)?
    /// Fired (on main thread) when a confirmed beep tone ends.
    var beepEndedCallback: (() -> Void)?

    private(set) var isRegistered = false
    private var captureProcessor: CapturePostProcessor?
    private var renderProcessor: RenderPreProcessor?

    var captureSampleRate: Int = 48000
    var captureChannels: Int = 1
    var renderSampleRate: Int = 48000
    var renderChannels: Int = 1

    private override init() {
        super.init()
    }

    // MARK: - Registration

    func register() {
        guard !isRegistered else { return }

        micInjectionRing.reset()

        captureProcessor = CapturePostProcessor(owner: self)
        renderProcessor = RenderPreProcessor(owner: self)

        let mgr = AudioManager.sharedInstance()
        mgr.capturePostProcessingAdapter.addProcessing(captureProcessor!)
        mgr.renderPreProcessingAdapter.addProcessing(renderProcessor!)

        isRegistered = true
        NSLog("[WebRTCAudioProcessor] Registered capture + render processors")
    }

    func unregister() {
        guard isRegistered else { return }

        let mgr = AudioManager.sharedInstance()
        if let cp = captureProcessor {
            mgr.capturePostProcessingAdapter.removeProcessing(cp)
        }
        if let rp = renderProcessor {
            mgr.renderPreProcessingAdapter.removeProcessing(rp)
        }

        captureProcessor = nil
        renderProcessor = nil
        isRegistered = false
        ttsCaptureRing.reset()
        ttsRenderRing.reset()
        ttsRecordingRing.reset()
        whisperRingBuffer.reset()
        micInjectionRing.reset()
        NSLog("[WebRTCAudioProcessor] Unregistered processors")
    }

    /// Feed AI TTS audio (PCM16, 24 kHz mono) into the ring buffers.
    /// Stored at native 24 kHz; processors resample to pipeline rate on read.
    func feedTTS(pcm16Data: Data) {
        let sampleCount = pcm16Data.count / 2
        guard sampleCount > 0 else { return }

        let floatBuf = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { floatBuf.deallocate() }

        pcm16Data.withUnsafeBytes { rawPtr in
            let int16Ptr = rawPtr.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                floatBuf[i] = Float(int16Ptr[i])
            }
        }

        let capWritten = ttsCaptureRing.write(floatBuf, count: sampleCount)
        let renWritten = ttsRenderRing.write(floatBuf, count: sampleCount)
        ttsRecordingRing.write(floatBuf, count: sampleCount)

        if capWritten < sampleCount || renWritten < sampleCount {
            NSLog("[WebRTCAudioProcessor] TTS DROP: wanted=%d capWrote=%d renWrote=%d capAvail=%d renAvail=%d",
                  sampleCount, capWritten, renWritten,
                  ttsCaptureRing.availableToRead, ttsRenderRing.availableToRead)
        }
    }

    /// Read TTS audio queued for call recording (PCM16, 24 kHz mono).
    func drainTTSRecordingBuffer() -> Data? {
        let avail = ttsRecordingRing.availableToRead
        guard avail > 0 else { return nil }

        let floatBuf = UnsafeMutablePointer<Float>.allocate(capacity: avail)
        defer { floatBuf.deallocate() }
        let read = ttsRecordingRing.read(into: floatBuf, count: avail)
        guard read > 0 else { return nil }

        var pcm16 = [Int16](repeating: 0, count: read)
        for i in 0..<read {
            let clamped = max(-32768.0, min(32767.0, floatBuf[i]))
            pcm16[i] = Int16(clamped)
        }
        return pcm16.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Read captured whisper audio (PCM16, 24 kHz mono).
    func drainWhisperBuffer() -> Data? {
        let avail = whisperRingBuffer.availableToRead
        guard avail > 0 else { return nil }

        let floatBuf = UnsafeMutablePointer<Float>.allocate(capacity: avail)
        defer { floatBuf.deallocate() }
        let read = whisperRingBuffer.read(into: floatBuf, count: avail)
        guard read > 0 else { return nil }

        var pcm16 = [Int16](repeating: 0, count: read)
        for i in 0..<read {
            let clamped = max(-32768.0, min(32767.0, floatBuf[i]))
            pcm16[i] = Int16(clamped)
        }
        return pcm16.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

// MARK: - Capture Post-Processor (outgoing audio: mic → network)

final class CapturePostProcessor: NSObject, ExternalAudioProcessingDelegate {

    private weak var owner: WebRTCAudioProcessor?
    private var sampleRate: Int = 48000
    private var channels: Int = 1

    private var srcBuffer: UnsafeMutablePointer<Float>?
    private var srcCapacity: Int = 0
    private var resampleBuffer: UnsafeMutablePointer<Float>?
    private var resampleCapacity: Int = 0

    private var micSrcBuffer: UnsafeMutablePointer<Float>?
    private var micSrcCapacity: Int = 0

    /// TTS gain for the outgoing (capture) path. Attenuated so the mic
    /// isn't drowned out on the remote party's end.
    private let ttsGain: Float = 0.45

    private var diagCounter: UInt64 = 0

    init(owner: WebRTCAudioProcessor) {
        self.owner = owner
        super.init()
    }

    func audioProcessingInitialize(withSampleRate sampleRateHz: Int, channels: Int) {
        self.sampleRate = sampleRateHz
        self.channels = channels
        owner?.captureSampleRate = sampleRateHz
        owner?.captureChannels = channels
        owner?.micInjectionRing.reset()
        NSLog("[CapturePostProc] init rate=%d ch=%d micSrcRate=%d", sampleRateHz, channels, owner?.micSourceRate ?? 0)
    }

    /// WebRTC delivers 10ms of audio per callback, so frames * 100 = true rate.
    private func effectiveRate(frames: Int) -> Int {
        let detected = frames * 100
        if detected != sampleRate && detected > 0 {
            if diagCounter <= 5 || diagCounter % 500 == 0 {
                NSLog("[CapturePostProc] rate mismatch: init=%d detected=%d (frames=%d) — using detected",
                      sampleRate, detected, frames)
            }
            return detected
        }
        return sampleRate
    }

    func audioProcessingProcess(_ audioBuffer: RTCAudioBuffer) {
        guard let owner = owner else { return }
        let frames = audioBuffer.frames
        let ch = audioBuffer.channels
        guard frames > 0, ch > 0 else { return }

        let rate = effectiveRate(frames: frames)
        let buf = audioBuffer.rawBuffer(forChannel: 0)

        let inConference = owner.conferenceMode

        if owner.micMuted {
            for i in 0..<frames { buf[i] = 0 }
        } else if !inConference {
            var micRms: Float = 0
            for i in 0..<frames { micRms += buf[i] * buf[i] }
            micRms = sqrtf(micRms / Float(frames))

            if micRms < 10.0 {
                injectMicAudio(into: buf, frames: frames, owner: owner, rate: rate)
            }
        }

        diagCounter += 1
        if diagCounter <= 10 || diagCounter % 500 == 0 {
            var postRms: Float = 0
            for i in 0..<frames { postRms += buf[i] * buf[i] }
            postRms = sqrtf(postRms / Float(frames))
            let ttsAvail = owner.ttsCaptureRing.availableToRead
            let injAvail = owner.micInjectionRing.availableToRead
            NSLog("[CapturePostProc] #%llu frames=%d rate=%d postRMS=%.1f ttsAvail=%d injRingAvail=%d micMuted=%@ conf=%@",
                  diagCounter, frames, rate, postRms, ttsAvail, injAvail,
                  owner.micMuted ? "YES" : "NO",
                  inConference ? "YES" : "NO")
        }

        if !inConference {
            mixTTSInto(buf: buf, frames: frames, ring: owner.ttsCaptureRing, rate: rate)
        }
    }

    func audioProcessingRelease() {
        srcBuffer?.deallocate()
        srcBuffer = nil
        srcCapacity = 0
        resampleBuffer?.deallocate()
        resampleBuffer = nil
        resampleCapacity = 0
        micSrcBuffer?.deallocate()
        micSrcBuffer = nil
        micSrcCapacity = 0
        NSLog("[CapturePostProc] released")
    }

    private func injectMicAudio(into buf: UnsafeMutablePointer<Float>, frames: Int, owner: WebRTCAudioProcessor, rate: Int) {
        let srcRate = owner.micSourceRate
        let dstRate = rate
        guard srcRate > 0, dstRate > 0 else { return }

        let srcNeeded = Int(Double(frames) * Double(srcRate) / Double(dstRate))
        guard srcNeeded > 0 else { return }

        if micSrcCapacity < srcNeeded {
            micSrcBuffer?.deallocate()
            micSrcBuffer = .allocate(capacity: srcNeeded)
            micSrcCapacity = srcNeeded
        }
        guard let src = micSrcBuffer else { return }
        memset(src, 0, srcNeeded * MemoryLayout<Float>.size)
        let readCount = owner.micInjectionRing.read(into: src, count: srcNeeded)

        if diagCounter <= 10 || diagCounter % 500 == 0 {
            var srcRms: Float = 0
            for i in 0..<readCount { srcRms += src[i] * src[i] }
            srcRms = readCount > 0 ? sqrtf(srcRms / Float(readCount)) : 0
            NSLog("[CapturePostProc] injectMic: srcRate=%d dstRate=%d need=%d read=%d srcRMS=%.1f",
                  srcRate, dstRate, srcNeeded, readCount, srcRms)
        }

        if readCount == 0 { return }

        if dstRate == srcRate {
            for i in 0..<min(readCount, frames) {
                buf[i] = src[i]
            }
            return
        }

        let ratio = Double(srcRate) / Double(dstRate)
        for i in 0..<frames {
            let srcIdx = Double(i) * ratio
            let idx0 = Int(srcIdx)
            let frac = Float(srcIdx - Double(idx0))
            let s0 = idx0 < readCount ? src[idx0] : Float(0)
            let s1 = (idx0 + 1) < readCount ? src[idx0 + 1] : s0
            buf[i] = s0 + (s1 - s0) * frac
        }
    }

    private func mixTTSInto(buf: UnsafeMutablePointer<Float>, frames: Int, ring: SPSCRingBuffer, rate: Int) {
        let srcRate = WebRTCAudioProcessor.ttsSourceRate
        let dstRate = rate

        let srcNeeded = Int(Double(frames) * Double(srcRate) / Double(dstRate))
        guard srcNeeded > 0 else { return }

        if srcCapacity < srcNeeded {
            srcBuffer?.deallocate()
            srcBuffer = .allocate(capacity: srcNeeded)
            srcCapacity = srcNeeded
        }
        guard let src = srcBuffer else { return }
        memset(src, 0, srcNeeded * MemoryLayout<Float>.size)
        let readCount = ring.read(into: src, count: srcNeeded)
        if readCount == 0 { return }

        if dstRate == srcRate {
            for i in 0..<min(readCount, frames) {
                buf[i] = max(-32768.0, min(32767.0, buf[i] + src[i] * ttsGain))
            }
            return
        }

        if resampleCapacity < frames {
            resampleBuffer?.deallocate()
            resampleBuffer = .allocate(capacity: frames)
            resampleCapacity = frames
        }
        guard let dst = resampleBuffer else { return }

        let ratio = Double(srcRate) / Double(dstRate)
        for i in 0..<frames {
            let srcIdx = Double(i) * ratio
            let idx0 = Int(srcIdx)
            let frac = Float(srcIdx - Double(idx0))
            let s0 = idx0 < readCount ? src[idx0] : Float(0)
            let s1 = (idx0 + 1) < readCount ? src[idx0 + 1] : s0
            dst[i] = s0 + (s1 - s0) * frac
        }

        for i in 0..<frames {
            buf[i] = max(-32768.0, min(32767.0, buf[i] + dst[i] * ttsGain))
        }
    }
}

// MARK: - Render Pre-Processor (incoming audio: network → speaker)

final class RenderPreProcessor: NSObject, ExternalAudioProcessingDelegate {

    private weak var owner: WebRTCAudioProcessor?
    private var sampleRate: Int = 48000
    private var channels: Int = 1

    private var srcBuffer: UnsafeMutablePointer<Float>?
    private var srcCapacity: Int = 0
    private var resampleBuffer: UnsafeMutablePointer<Float>?
    private var resampleCapacity: Int = 0

    private var diagCounter: UInt64 = 0

    // MARK: - Goertzel Beep Detection

    /// Standard voicemail beep frequencies to scan.
    private let goertzelFreqs: [Float] = [440, 480, 620, 850, 950, 1000, 1400]

    /// Consecutive 10ms frames where a pure tone was detected.
    private var toneFrameCount: Int = 0

    /// Minimum consecutive tone frames to confirm a beep (40 × 10ms = 400ms).
    /// Voicemail beeps are typically 0.5–2s; short DTMF tones won't reach this.
    private static let toneConfirmFrames = 40

    /// True while a confirmed tone is ongoing — prevents duplicate callbacks.
    private var toneActive = false

    init(owner: WebRTCAudioProcessor) {
        self.owner = owner
        super.init()
    }

    func audioProcessingInitialize(withSampleRate sampleRateHz: Int, channels: Int) {
        self.sampleRate = sampleRateHz
        self.channels = channels
        owner?.renderSampleRate = sampleRateHz
        owner?.renderChannels = channels
        toneFrameCount = 0
        toneActive = false
        NSLog("[RenderPreProc] init rate=%d ch=%d", sampleRateHz, channels)
    }

    /// WebRTC delivers 10ms of audio per callback, so frames * 100 = true rate.
    private func effectiveRate(frames: Int) -> Int {
        let detected = frames * 100
        if detected != sampleRate && detected > 0 {
            if diagCounter <= 5 || diagCounter % 500 == 0 {
                NSLog("[RenderPreProc] rate mismatch: init=%d detected=%d (frames=%d) — using detected",
                      sampleRate, detected, frames)
            }
            return detected
        }
        return sampleRate
    }

    func audioProcessingProcess(_ audioBuffer: RTCAudioBuffer) {
        guard let owner = owner else { return }
        let frames = audioBuffer.frames
        let ch = audioBuffer.channels
        guard frames > 0, ch > 0 else { return }

        let rate = effectiveRate(frames: frames)
        let buf = audioBuffer.rawBuffer(forChannel: 0)
        let inConference = owner.conferenceMode

        diagCounter += 1
        if diagCounter <= 10 || diagCounter % 500 == 0 {
            let ttsAvail = owner.ttsRenderRing.availableToRead
            var rms: Float = 0
            for i in 0..<frames { rms += buf[i] * buf[i] }
            rms = sqrtf(rms / Float(frames))
            NSLog("[RenderPreProc] #%llu frames=%d rate=%d remoteRMS=%.1f ttsAvail=%d conf=%@",
                  diagCounter, frames, rate, rms, ttsAvail,
                  inConference ? "YES" : "NO")
        }

        if !inConference {
            if owner.ttsRenderRing.availableToRead == 0 {
                runToneDetection(buf: buf, frames: frames, rate: Float(rate))
            }
        }

        writeToWhisper(src: buf, srcFrames: frames, srcRate: rate, owner: owner)

        let gain = owner.remoteGain
        if gain != 1.0 {
            for i in 0..<frames {
                buf[i] = max(-32768.0, min(32767.0, buf[i] * gain))
            }
        }

        if !inConference {
            mixTTSInto(buf: buf, frames: frames, ring: owner.ttsRenderRing, rate: rate)
        }
    }

    // MARK: - Goertzel Tone Detection

    /// Goertzel algorithm: compute energy at a single frequency from N samples.
    /// Cost: ~5 multiply-adds per sample — negligible for 80-sample frames.
    @inline(__always)
    private func goertzelMagnitude(buf: UnsafeMutablePointer<Float>, frames: Int, freq: Float, rate: Float) -> Float {
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

    private func runToneDetection(buf: UnsafeMutablePointer<Float>, frames: Int, rate: Float) {
        var totalEnergy: Float = 0
        for i in 0..<frames { totalEnergy += buf[i] * buf[i] }

        // Silence: no tone possible. Use a generous threshold so quiet tones
        // that are clearly above noise floor still register.
        guard totalEnergy > 500.0 * Float(frames) else {
            endToneIfActive()
            return
        }

        var isTone = false
        for freq in goertzelFreqs {
            let mag = goertzelMagnitude(buf: buf, frames: frames, freq: freq, rate: rate)
            // If >60% of frame energy concentrates at one frequency, it's a tone.
            // Higher threshold reduces false positives from speech harmonics.
            if mag > totalEnergy * 0.60 {
                isTone = true
                break
            }
        }

        if isTone {
            toneFrameCount += 1
            if toneFrameCount == Self.toneConfirmFrames && !toneActive {
                toneActive = true
                NSLog("[RenderPreProc] Beep tone DETECTED (sustained %dms)", toneFrameCount * 10)
                DispatchQueue.main.async { [weak owner] in
                    owner?.beepDetectedCallback?()
                }
            }
        } else {
            endToneIfActive()
        }
    }

    private func endToneIfActive() {
        if toneActive {
            NSLog("[RenderPreProc] Beep tone ENDED after %dms", toneFrameCount * 10)
            toneActive = false
            DispatchQueue.main.async { [weak owner] in
                owner?.beepEndedCallback?()
            }
        }
        toneFrameCount = 0
    }

    func audioProcessingRelease() {
        srcBuffer?.deallocate()
        srcBuffer = nil
        srcCapacity = 0
        resampleBuffer?.deallocate()
        resampleBuffer = nil
        resampleCapacity = 0
        NSLog("[RenderPreProc] released")
    }

    private func mixTTSInto(buf: UnsafeMutablePointer<Float>, frames: Int, ring: SPSCRingBuffer, rate: Int) {
        let srcRate = WebRTCAudioProcessor.ttsSourceRate
        let dstRate = rate

        let srcNeeded = Int(Double(frames) * Double(srcRate) / Double(dstRate))
        guard srcNeeded > 0 else { return }

        if srcCapacity < srcNeeded {
            srcBuffer?.deallocate()
            srcBuffer = .allocate(capacity: srcNeeded)
            srcCapacity = srcNeeded
        }
        guard let src = srcBuffer else { return }
        memset(src, 0, srcNeeded * MemoryLayout<Float>.size)
        let readCount = ring.read(into: src, count: srcNeeded)
        if readCount == 0 { return }

        if dstRate == srcRate {
            for i in 0..<min(readCount, frames) {
                buf[i] = max(-32768.0, min(32767.0, buf[i] + src[i]))
            }
            return
        }

        if resampleCapacity < frames {
            resampleBuffer?.deallocate()
            resampleBuffer = .allocate(capacity: frames)
            resampleCapacity = frames
        }
        guard let dst = resampleBuffer else { return }

        let ratio = Double(srcRate) / Double(dstRate)
        for i in 0..<frames {
            let srcIdx = Double(i) * ratio
            let idx0 = Int(srcIdx)
            let frac = Float(srcIdx - Double(idx0))
            let s0 = idx0 < readCount ? src[idx0] : Float(0)
            let s1 = (idx0 + 1) < readCount ? src[idx0 + 1] : s0
            dst[i] = s0 + (s1 - s0) * frac
        }

        for i in 0..<frames {
            buf[i] = max(-32768.0, min(32767.0, buf[i] + dst[i]))
        }
    }

    private func writeToWhisper(src: UnsafeMutablePointer<Float>, srcFrames: Int, srcRate: Int, owner: WebRTCAudioProcessor) {
        let targetRate = 24000
        if srcRate == targetRate {
            owner.whisperRingBuffer.write(src, count: srcFrames)
            return
        }

        let ratio = Double(targetRate) / Double(srcRate)
        let outCount = Int(Double(srcFrames) * ratio)
        guard outCount > 0 else { return }

        let downBuf = UnsafeMutablePointer<Float>.allocate(capacity: outCount)
        defer { downBuf.deallocate() }
        for i in 0..<outCount {
            let srcIdx = Double(i) / ratio
            let idx0 = Int(srcIdx)
            let frac = Float(srcIdx - Double(idx0))
            let s0 = idx0 < srcFrames ? src[idx0] : 0
            let s1 = (idx0 + 1) < srcFrames ? src[idx0 + 1] : s0
            downBuf[i] = s0 + (s1 - s0) * frac
        }
        owner.whisperRingBuffer.write(downBuf, count: outCount)
    }
}
