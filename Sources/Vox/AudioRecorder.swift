import AVFoundation
import Foundation

struct Recording: Sendable {
    let url: URL
    let duration: TimeInterval
}

enum AudioRecorderError: LocalizedError {
    case microphoneDenied
    case noInputDevice
    case alreadyRecording
    case notRecording
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "マイクへのアクセスが許可されていません"
        case .noInputDevice: "利用できるマイクが見つかりません"
        case .alreadyRecording: "すでに録音中です"
        case .notRecording: "録音されていません"
        case let .writeFailed(message): "音声の保存に失敗しました: \(message)"
        }
    }
}

final class AudioRecorder {
    var onLevel: (@Sendable (Float) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var outputURL: URL?
    private var startedAt: Date?
    private var callbackError: Error?

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    func start() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard audioFile == nil else { throw AudioRecorderError.alreadyRecording }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw AudioRecorderError.noInputDevice
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: format, to: targetFormat) else {
            throw AudioRecorderError.writeFailed("16kHz PCMへの変換を初期化できません")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vox-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let file = try AVAudioFile(
            forWriting: url,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        callbackError = nil
        audioFile = file
        self.converter = converter
        outputURL = url
        startedAt = Date()

        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            audioFile = nil
            self.converter = nil
            outputURL = nil
            startedAt = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    func stop() throws -> Recording {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        defer { lock.unlock() }
        guard let url = outputURL, let startedAt else { throw AudioRecorderError.notRecording }
        let duration = Date().timeIntervalSince(startedAt)
        audioFile = nil
        converter = nil
        outputURL = nil
        self.startedAt = nil

        if let callbackError {
            self.callbackError = nil
            try? FileManager.default.removeItem(at: url)
            throw AudioRecorderError.writeFailed(callbackError.localizedDescription)
        }
        return Recording(url: url, duration: duration)
    }

    func cancel() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        let url = outputURL
        audioFile = nil
        converter = nil
        outputURL = nil
        startedAt = nil
        callbackError = nil
        lock.unlock()

        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        if let converter {
            let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 32
            if let converted = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: capacity
            ) {
                var suppliedInput = false
                var conversionError: NSError?
                _ = converter.convert(to: converted, error: &conversionError) { _, status in
                    if suppliedInput {
                        status.pointee = .noDataNow
                        return nil
                    }
                    suppliedInput = true
                    status.pointee = .haveData
                    return buffer
                }

                if let conversionError {
                    callbackError = conversionError
                } else if converted.frameLength > 0 {
                    do {
                        try audioFile?.write(from: converted)
                    } catch {
                        callbackError = error
                    }
                }
            }
        }

        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        let samples = channels[0]
        let step = max(1, count / 256)
        var sum: Float = 0
        var sampled = 0
        for index in stride(from: 0, to: count, by: step) {
            let value = samples[index]
            sum += value * value
            sampled += 1
        }
        guard sampled > 0 else { return }
        let rms = sqrt(sum / Float(sampled))
        let decibels = 20 * log10(max(rms, 0.000_01))
        let normalized = min(1, max(0.04, (decibels + 52) / 48))
        onLevel?(normalized)
    }
}
