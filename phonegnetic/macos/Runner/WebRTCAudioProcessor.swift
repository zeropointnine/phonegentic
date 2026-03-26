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

    /// Mic injection ring: float samples in int16 range at mic native rate.
    /// Fed by CoreAudio IOProc, consumed by CapturePostProcessor when WebRTC's
    /// ADM fails to deliver mic audio (e.g. SDP negotiation issues).
    let micInjectionRing = SPSCRingBuffer(capacity: 48000 * 2)
    var micSourceRate: Int = 48000

    /// When true, mic audio is zeroed in the capture path so the remote
    /// party can't hear the local user, but TTS keeps flowing and the
    /// agent's whisper feed (via CoreAudio IOProc) stays active.
    var micMuted = false

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

        if capWritten < sampleCount || renWritten < sampleCount {
            NSLog("[WebRTCAudioProcessor] TTS DROP: wanted=%d capWrote=%d renWrote=%d capAvail=%d renAvail=%d",
                  sampleCount, capWritten, renWritten,
                  ttsCaptureRing.availableToRead, ttsRenderRing.availableToRead)
        }
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

        if owner.micMuted {
            // Zero mic audio so the remote party hears silence from the user,
            // but keep the pipeline alive for TTS mixing below.
            for i in 0..<frames { buf[i] = 0 }
        } else {
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
            NSLog("[CapturePostProc] #%llu frames=%d rate=%d postRMS=%.1f ttsAvail=%d injRingAvail=%d micMuted=%@",
                  diagCounter, frames, rate, postRms, ttsAvail, injAvail,
                  owner.micMuted ? "YES" : "NO")
        }

        mixTTSInto(buf: buf, frames: frames, ring: owner.ttsCaptureRing, rate: rate)
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

    init(owner: WebRTCAudioProcessor) {
        self.owner = owner
        super.init()
    }

    func audioProcessingInitialize(withSampleRate sampleRateHz: Int, channels: Int) {
        self.sampleRate = sampleRateHz
        self.channels = channels
        owner?.renderSampleRate = sampleRateHz
        owner?.renderChannels = channels
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

        diagCounter += 1
        if diagCounter <= 10 || diagCounter % 500 == 0 {
            let ttsAvail = owner.ttsRenderRing.availableToRead
            var rms: Float = 0
            for i in 0..<frames { rms += buf[i] * buf[i] }
            rms = sqrtf(rms / Float(frames))
            NSLog("[RenderPreProc] #%llu frames=%d rate=%d remoteRMS=%.1f ttsAvail=%d",
                  diagCounter, frames, rate, rms, ttsAvail)
        }

        writeToWhisper(src: buf, srcFrames: frames, srcRate: rate, owner: owner)
        mixTTSInto(buf: buf, frames: frames, ring: owner.ttsRenderRing, rate: rate)
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
