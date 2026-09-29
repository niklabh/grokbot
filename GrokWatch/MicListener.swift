import AVFoundation
import Foundation

/// Records the watch microphone until speech pauses, the person taps again, or time runs out.
final class MicListener {
    var onRecorded: ((URL) -> Void)?
    var onEmpty: (() -> Void)?
    var onFailed: (() -> Void)?

    private enum State {
        case idle
        case armed
        case recording
    }

    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("grok-listen.wav")
    private let lock = NSLock()
    private var state: State = .idle
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var timer: Timer?
    private var heardSpeech = false
    private var lastSound: TimeInterval = 0
    private var startedAt: TimeInterval = 0

    func arm() {
        state = .armed
    }

    func start() {
        guard state == .armed, engine == nil else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [])
            try session.setActive(true)
            try? FileManager.default.removeItem(at: url)
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                fail()
                return
            }
            guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: inputFormat, to: target),
                  let scratch = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192)
            else {
                fail()
                return
            }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
            heardSpeech = false
            startedAt = Date().timeIntervalSinceReferenceDate
            lastSound = startedAt
            state = .recording
            self.engine = engine
            self.file = file
            self.converter = converter
            input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                self?.consume(buffer, scratch: scratch)
            }
            engine.prepare()
            try engine.start()
            timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                self?.tick()
            }
        } catch {
            print("mic failed: \(error)")
            fail()
        }
    }

    /// Stop and send whatever was recorded. A second tap before the mic is open cancels.
    func finish() {
        switch state {
        case .armed:
            state = .idle
            onEmpty?()
        case .recording:
            state = .idle
            stopEngine()
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > 1000 {
                onRecorded?(url)
            } else {
                onEmpty?()
            }
        case .idle:
            break
        }
    }

    private func tick() {
        guard state == .recording else { return }
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        let heard = heardSpeech
        let last = lastSound
        lock.unlock()
        if heard, now - last > 1.1 {
            finish()
        } else if now - startedAt > 15 {
            finish()
        } else if !heard, now - startedAt > 7 {
            state = .idle
            stopEngine()
            onEmpty?()
        }
    }

    private func fail() {
        state = .idle
        stopEngine()
        onFailed?()
    }

    private func stopEngine() {
        timer?.invalidate()
        timer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        if #available(watchOS 11, *) {
            file?.close()
        }
        file = nil
    }

    private func consume(_ buffer: AVAudioPCMBuffer, scratch: AVAudioPCMBuffer) {
        guard state == .recording, let converter, let file else { return }
        if rms(buffer) > 0.012 {
            lock.lock()
            heardSpeech = true
            lastSound = Date().timeIntervalSinceReferenceDate
            lock.unlock()
        }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: scratch, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, scratch.frameLength > 0 else { return }
        try? file.write(from: scratch)
    }

    private func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<frames {
                let sample = samples[index]
                sum += sample * sample
            }
        } else if let samples = buffer.int16ChannelData?[0] {
            let scale: Float = 1 / 32768
            for index in 0..<frames {
                let sample = Float(samples[index]) * scale
                sum += sample * sample
            }
        } else {
            return 0
        }
        return (sum / Float(frames)).squareRoot()
    }
}
