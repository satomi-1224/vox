import AppKit
import AVFoundation
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case recording
        case transcribing
        case error(String)

        var isBusy: Bool {
            switch self {
            case .preparing, .recording, .transcribing: true
            case .idle, .error: false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var modelState: TranscriptionService.ModelState = .stopped
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasInputMonitoringPermission = false
    @Published private(set) var hotkeyIsAvailable = false
    @Published private(set) var lastTranscript = ""
    @Published private(set) var lastElapsedMilliseconds: Double?
    let settings: SettingsStore
    let transcription: TranscriptionService

    private let recorder = AudioRecorder()
    private let injector = TextInjector()
    private let overlay = OverlayController()
    private let hotkeyManager: HotkeyManager
    private let singleInstanceGuard: SingleInstanceGuard
    private var cancellables = Set<AnyCancellable>()
    private var hotkeyHeld = false
    private var preparationID: UUID?
    private var transcriptionID: UUID?

    init() {
        let settings = SettingsStore()
        let transcription = TranscriptionService(modelID: settings.modelID)
        let singleInstanceGuard = SingleInstanceGuard.shared
        self.settings = settings
        self.transcription = transcription
        self.singleInstanceGuard = singleInstanceGuard
        hotkeyManager = HotkeyManager(hotkey: settings.hotkey)

        guard singleInstanceGuard.isPrimary else {
            phase = .error("Voxはすでに起動しています")
            DispatchQueue.main.async {
                let ownPID = ProcessInfo.processInfo.processIdentifier
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.satomi.vox")
                    .first { $0.processIdentifier != ownPID }?
                    .activate()
                NSApp.terminate(nil)
            }
            return
        }

        hotkeyManager.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkeyManager.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkeyManager.onAvailabilityChange = { [weak self] available in
            self?.hotkeyIsAvailable = available
            self?.refreshPermissions()
        }
        recorder.onLevel = { [weak self] level in
            Task { @MainActor [weak self] in self?.overlay.updateLevel(level) }
        }
        transcription.$modelState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.modelState = state
                guard self.phase == .transcribing else { return }
                if state.isReady {
                    self.overlay.showTranscribing()
                } else if state.isPreparing {
                    self.overlay.showPreparingModel()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshPermissions()
                if self.hasInputMonitoringPermission,
                   self.hasAccessibilityPermission,
                   !self.hotkeyIsAvailable {
                    self.hotkeyManager.restart()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.shutdown() }
            .store(in: &cancellables)

        refreshPermissions()
        hotkeyManager.start()
        transcription.startAndWarmUp()
    }

    var statusText: String {
        switch phase {
        case .idle: "待機中"
        case .preparing: "マイクを準備中"
        case .recording: "録音中"
        case .transcribing: "文字起こし中"
        case let .error(message): message
        }
    }

    var statusIcon: String {
        switch phase {
        case .recording: "waveform.circle.fill"
        case .transcribing, .preparing: "ellipsis.circle.fill"
        case .error: "exclamationmark.circle.fill"
        case .idle: "waveform.circle"
        }
    }

    func menuToggleRecording() {
        switch phase {
        case .recording:
            finishRecording()
        case .idle, .error:
            Task { await beginRecording(requireHeldHotkey: false) }
        case .transcribing:
            cancelTranscription()
        case .preparing:
            break
        }
    }

    func refreshPermissions() {
        hasMicrophonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasAccessibilityPermission = TextInjector.hasAccessibilityPermission
        hasInputMonitoringPermission = HotkeyManager.hasInputMonitoringPermission
    }

    func requestMicrophonePermission() {
        Task {
            _ = await recorder.requestPermission()
            refreshPermissions()
        }
    }

    func requestAccessibilityPermission() {
        _ = TextInjector.requestAccessibilityPermission()
        openPrivacySettings(anchor: "Privacy_Accessibility")
        schedulePermissionRefresh(restartHotkey: true)
    }

    func requestInputMonitoringPermission() {
        _ = HotkeyManager.requestInputMonitoringPermission()
        openPrivacySettings(anchor: "Privacy_ListenEvent")
        schedulePermissionRefresh(restartHotkey: true)
    }

    private func hotkeyPressed() {
        hotkeyHeld = true
        switch settings.inputMode {
        case .pushToTalk:
            guard !phase.isBusy else { return }
            Task { await beginRecording(requireHeldHotkey: true) }
        case .toggle:
            menuToggleRecording()
        }
    }

    private func hotkeyReleased() {
        hotkeyHeld = false
        guard settings.inputMode == .pushToTalk, phase == .recording else { return }
        finishRecording()
    }

    private func beginRecording(requireHeldHotkey: Bool) async {
        guard !phase.isBusy else { return }
        let id = UUID()
        preparationID = id
        phase = .preparing

        let permitted = await recorder.requestPermission()
        refreshPermissions()
        guard preparationID == id else { return }
        guard permitted else {
            phase = .error("マイクの許可が必要です")
            overlay.showMessage("マイクの許可が必要です", success: false)
            return
        }
        guard !requireHeldHotkey || hotkeyHeld else {
            phase = .idle
            return
        }

        do {
            _ = try recorder.start()
            phase = .recording
            overlay.showListening()
        } catch {
            phase = .error(error.localizedDescription)
            overlay.showMessage(error.localizedDescription, success: false, duration: 2)
        }
    }

    private func finishRecording() {
        guard phase == .recording else { return }
        do {
            let recording = try recorder.stop()
            if recording.duration < 0.18 {
                try? FileManager.default.removeItem(at: recording.url)
                phase = .idle
                overlay.hide()
                return
            }

            let id = UUID()
            transcriptionID = id
            phase = .transcribing
            if modelState.isReady {
                overlay.showTranscribing()
            } else {
                overlay.showPreparingModel()
            }
            Task { await transcribe(recording, id: id) }
        } catch {
            phase = .error(error.localizedDescription)
            overlay.showMessage(error.localizedDescription, success: false, duration: 2)
        }
    }

    private func transcribe(_ recording: Recording, id: UUID) async {
        defer {
            try? FileManager.default.removeItem(at: recording.url)
            if transcriptionID == id { transcriptionID = nil }
        }
        do {
            let transcript = try await transcription.transcribe(
                audioURL: recording.url,
                language: settings.language.workerValue,
                dictionary: settings.workerDictionary
            )
            guard transcriptionID == id else { return }
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            lastTranscript = text
            lastElapsedMilliseconds = transcript.elapsedMilliseconds
            phase = .idle

            guard !text.isEmpty else {
                overlay.showMessage("音声を検出できませんでした", success: false)
                return
            }
            switch injector.insert(text) {
            case .pasted:
                overlay.showMessage("入力しました", success: true, duration: 0.8)
            case .copied:
                overlay.showMessage("クリップボードにコピーしました", success: true, duration: 1.5)
            }
        } catch {
            guard transcriptionID == id else { return }
            phase = .error(error.localizedDescription)
            overlay.showMessage(error.localizedDescription, success: false, duration: 2.4)
        }
    }

    private func cancelTranscription() {
        guard phase == .transcribing else { return }
        transcriptionID = nil
        transcription.shutdown(reason: "文字起こしをキャンセルしました")
        phase = .idle
        overlay.showMessage("キャンセルしました", success: true, duration: 0.8)
    }

    private func shutdown() {
        preparationID = nil
        transcriptionID = nil
        if phase == .recording { recorder.cancel() }
        transcription.shutdown(reason: "Voxを終了しました")
    }

    private func schedulePermissionRefresh(restartHotkey: Bool = false) {
        for delay in [0.5, 1.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.refreshPermissions()
                if restartHotkey { self.hotkeyManager.restart() }
            }
        }
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}
