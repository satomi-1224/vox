import Foundation

enum TranscriptionError: LocalizedError {
    case workerNotFound
    case workerUnavailable(String)
    case invalidResponse
    case workerError(String)

    var errorDescription: String? {
        switch self {
        case .workerNotFound:
            "文字起こしワーカーが見つかりません。Nix経由で起動してください。"
        case let .workerUnavailable(message):
            "文字起こしワーカーを起動できません: \(message)"
        case .invalidResponse:
            "文字起こしワーカーから不正な応答を受信しました"
        case let .workerError(message):
            message
        }
    }
}

@MainActor
final class TranscriptionService: ObservableObject {
    enum ModelState: Equatable {
        case stopped
        case starting
        case downloading
        case loading
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .stopped: "停止中"
            case .starting: "ワーカー起動中"
            case .downloading: "モデルを準備中"
            case .loading: "モデルを読み込み中"
            case .ready: "準備完了"
            case .failed: "エラー"
            }
        }

        var isReady: Bool { self == .ready }

        var isPreparing: Bool {
            switch self {
            case .starting, .downloading, .loading: true
            case .stopped, .ready, .failed: false
            }
        }
    }

    @Published private(set) var modelState: ModelState = .stopped

    let modelID: String

    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputBuffer = Data()
    private var pending: [String: CheckedContinuation<WorkerMessage, Error>] = [:]

    init(modelID: String = ProcessInfo.processInfo.environment["VOX_MODEL_ID"]
        ?? "mlx-community/whisper-large-v3-turbo") {
        self.modelID = modelID
    }

    deinit {
        process?.terminationHandler = nil
        process?.terminate()
    }

    func startAndWarmUp() {
        guard process == nil else { return }
        do {
            try launchWorker()
            Task {
                do {
                    modelState = .loading
                    _ = try await send(WorkerRequest(
                        id: UUID().uuidString,
                        command: "warmup",
                        model: modelID
                    ))
                    modelState = .ready
                } catch {
                    if process != nil {
                        modelState = .failed(error.localizedDescription)
                    }
                }
            }
        } catch {
            modelState = .failed(error.localizedDescription)
        }
    }

    func transcribe(
        audioURL: URL,
        language: String?,
        dictionary: [WorkerDictionaryEntry]
    ) async throws -> Transcript {
        if process == nil { try launchWorker() }

        let response = try await send(WorkerRequest(
            id: UUID().uuidString,
            command: "transcribe",
            audioPath: audioURL.path,
            model: modelID,
            language: language,
            dictionary: dictionary
        ))
        guard let text = response.text else { throw TranscriptionError.invalidResponse }
        modelState = .ready
        return Transcript(
            text: text,
            language: response.language,
            elapsedMilliseconds: response.elapsedMs
        )
    }

    private func launchWorker() throws {
        modelState = .starting
        let launch = try workerLaunchConfiguration()
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()

        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.consumeOutput(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            NSLog("Vox worker: %@", line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.workerDidExit(status: process.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            throw TranscriptionError.workerUnavailable(error.localizedDescription)
        }

        self.process = process
        inputHandle = input.fileHandleForWriting
        outputHandle = output.fileHandleForReading
        errorHandle = errors.fileHandleForReading
    }

    private func workerLaunchConfiguration() throws -> (executable: URL, arguments: [String]) {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["VOX_WORKER_PATH"], FileManager.default.isExecutableFile(atPath: path) {
            return (URL(fileURLWithPath: path), [])
        }

        if let bundled = Bundle.main.url(forResource: "vox-worker", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return (bundled, [])
        }

        let sourceWorker = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("worker/vox_worker.py")
        if FileManager.default.fileExists(atPath: sourceWorker.path) {
            let python = environment["VOX_PYTHON"] ?? "/usr/bin/python3"
            return (URL(fileURLWithPath: python), [sourceWorker.path])
        }
        throw TranscriptionError.workerNotFound
    }

    private func send(_ request: WorkerRequest) async throws -> WorkerMessage {
        guard process?.isRunning == true, let inputHandle else {
            throw TranscriptionError.workerUnavailable("プロセスが停止しています")
        }

        let data: Data
        do {
            data = try JSONEncoder().encode(request) + Data([0x0A])
        } catch {
            throw TranscriptionError.workerUnavailable(error.localizedDescription)
        }

        return try await withCheckedThrowingContinuation { continuation in
            pending[request.id] = continuation
            do {
                try inputHandle.write(contentsOf: data)
            } catch {
                pending.removeValue(forKey: request.id)
                continuation.resume(throwing: TranscriptionError.workerUnavailable(error.localizedDescription))
            }
        }
    }

    private func consumeOutput(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do {
                let message = try JSONDecoder().decode(WorkerMessage.self, from: Data(line))
                handle(message)
            } catch {
                NSLog("Vox worker protocol error: %@", error.localizedDescription)
            }
        }
    }

    private func handle(_ message: WorkerMessage) {
        if message.type == "status" {
            switch message.state {
            case "downloading": modelState = .downloading
            case "preparing_model": modelState = .downloading
            case "loading_model": modelState = .loading
            case "transcribing": modelState = .ready
            case "ready": modelState = .ready
            default: break
            }
            return
        }

        guard let id = message.id, let continuation = pending.removeValue(forKey: id) else { return }
        if message.type == "error" {
            continuation.resume(throwing: TranscriptionError.workerError(message.message ?? "文字起こしに失敗しました"))
        } else {
            continuation.resume(returning: message)
        }
    }

    private func workerDidExit(status: Int32) {
        process = nil
        inputHandle = nil
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        outputHandle = nil
        errorHandle = nil
        outputBuffer.removeAll(keepingCapacity: false)
        let error = TranscriptionError.workerUnavailable("終了コード \(status)")
        let continuations = Array(pending.values)
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
        modelState = .failed(error.localizedDescription)
    }

    func shutdown(reason: String) {
        let runningProcess = process
        process = nil
        runningProcess?.terminationHandler = nil
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        try? inputHandle?.close()
        if runningProcess?.isRunning == true { runningProcess?.terminate() }

        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        outputBuffer.removeAll(keepingCapacity: false)
        let error = TranscriptionError.workerUnavailable(reason)
        let continuations = Array(pending.values)
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
        modelState = .stopped
    }
}
