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

private enum AudioBufferConversionError: LocalizedError {
    case converterUnavailable(Double)
    case bufferUnavailable
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case let .converterUnavailable(sampleRate):
            "\(sampleRate)Hzから16kHzへ変換できません"
        case .bufferUnavailable:
            "音声変換用バッファを作成できません"
        case .conversionFailed:
            "音声バッファの変換に失敗しました"
        }
    }
}

final class AudioRecorder {
    var onLevel: (@Sendable (Float) -> Void)?

    private let lock = NSLock()
    private var session: AudioRecordingSession?

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
        guard session == nil else { throw AudioRecorderError.alreadyRecording }

        // AVAudioEngine retains the I/O graph and its formats after stop(). A
        // fresh engine prevents a device change while Vox is idle from leaving
        // the next recording attached to a stale hardware format.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardwareFormat = input.inputFormat(forBus: 0)
        guard hardwareFormat.channelCount > 0, hardwareFormat.sampleRate > 0 else {
            throw AudioRecorderError.noInputDevice
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else { throw AudioRecorderError.writeFailed("16kHz PCMを初期化できません") }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vox-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let file = try AVAudioFile(
            forWriting: url,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        let session = AudioRecordingSession(
            engine: engine,
            input: input,
            file: file,
            targetFormat: targetFormat,
            url: url,
            startedAt: Date()
        )
        self.session = session
        let levelHandler = onLevel

        // Let AVAudioEngine select the current input-node format. Supplying a
        // cached format can raise an Objective-C exception (which Swift cannot
        // catch) when the default microphone or its sample rate has changed.
        input.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak session] buffer, _ in
            session?.consume(buffer, onLevel: levelHandler)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            self.session = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    func stop() throws -> Recording {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { throw AudioRecorderError.notRecording }

        session.input.removeTap(onBus: 0)
        session.engine.stop()
        self.session = nil

        if let callbackErrorMessage = session.callbackErrorMessage {
            try? FileManager.default.removeItem(at: session.url)
            throw AudioRecorderError.writeFailed(callbackErrorMessage)
        }
        return Recording(
            url: session.url,
            duration: Date().timeIntervalSince(session.startedAt)
        )
    }

    func cancel() {
        lock.lock()
        guard let session else {
            lock.unlock()
            return
        }
        session.input.removeTap(onBus: 0)
        session.engine.stop()
        self.session = nil
        lock.unlock()

        try? FileManager.default.removeItem(at: session.url)
    }
}

private final class AudioRecordingSession {
    let engine: AVAudioEngine
    let input: AVAudioInputNode
    let url: URL
    let startedAt: Date

    private let file: AVAudioFile
    private let lock = NSLock()
    private let converter: AudioBufferConverter
    private var errorMessage: String?

    init(
        engine: AVAudioEngine,
        input: AVAudioInputNode,
        file: AVAudioFile,
        targetFormat: AVAudioFormat,
        url: URL,
        startedAt: Date
    ) {
        self.engine = engine
        self.input = input
        self.file = file
        converter = AudioBufferConverter(outputFormat: targetFormat)
        self.url = url
        self.startedAt = startedAt
    }

    var callbackErrorMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return errorMessage
    }

    func consume(_ buffer: AVAudioPCMBuffer, onLevel: (@Sendable (Float) -> Void)?) {
        lock.lock()
        if errorMessage == nil {
            do {
                let converted = try converter.convert(buffer)
                if converted.frameLength > 0 {
                    try file.write(from: converted)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        lock.unlock()

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

final class AudioBufferConverter {
    let outputFormat: AVAudioFormat
    private(set) var inputFormat: AVAudioFormat?

    private var converter: AVAudioConverter?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let sourceFormat = buffer.format
        if converter?.inputFormat != sourceFormat {
            guard let replacement = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
                throw AudioBufferConversionError.converterUnavailable(sourceFormat.sampleRate)
            }
            converter = replacement
            inputFormat = sourceFormat
        }

        guard let converter else {
            throw AudioBufferConversionError.converterUnavailable(sourceFormat.sampleRate)
        }
        let ratio = outputFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 32
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            throw AudioBufferConversionError.bufferUnavailable
        }

        let inputProvider = AudioConverterInput(buffer: buffer)
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            inputProvider.next(status: inputStatus)
        }

        if let conversionError {
            throw conversionError
        }
        if status == .error {
            throw AudioBufferConversionError.conversionFailed
        }
        return converted
    }
}

private final class AudioConverterInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var wasSupplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !wasSupplied else {
            status.pointee = .noDataNow
            return nil
        }
        wasSupplied = true
        status.pointee = .haveData
        return buffer
    }
}
