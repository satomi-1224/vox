import AppKit
import SwiftUI

@main
struct VoxApp: App {
    @StateObject private var appState = AppState()
    @State private var menuBarExtraIsInserted = true

    init() {
        // App initialization happens before applicationDidFinishLaunching, which
        // is within ProcessInfo's required window for enabling this support.
        ApplicationLifecycle.keepMenuBarServiceRunning()
    }

    var body: some Scene {
        // Giving the settings group one stable value preserves a single window
        // while retaining WindowGroup's keep-running behavior after it closes.
        WindowGroup("Vox", id: "settings", for: SettingsWindowID.self) { _ in
            SettingsView(appState: appState)
        } defaultValue: {
            .main
        }
        .defaultSize(width: 620, height: 760)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        // Use the multi-scene initializer because the status item coexists with
        // the settings window.
        MenuBarExtra(isInserted: persistentMenuBarExtraInsertion) {
            VoxMenu(appState: appState)
        } label: {
            Image(systemName: appState.statusIcon)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.menu)
    }

    private var persistentMenuBarExtraInsertion: Binding<Bool> {
        Binding(
            get: { menuBarExtraIsInserted },
            set: { requestedInsertion in
                menuBarExtraIsInserted = requestedInsertion
                guard !requestedInsertion else { return }

                // Without a Dock icon, removing the status item would leave no
                // route back to settings or Quit. Restore it on the next update.
                DispatchQueue.main.async {
                    menuBarExtraIsInserted = true
                }
            }
        )
    }
}

private struct VoxMenu: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow

    init(appState: AppState) {
        self.appState = appState
        _settings = ObservedObject(wrappedValue: appState.settings)
    }

    var body: some View {
        Button {
            appState.menuToggleRecording()
        } label: {
            Label(recordingActionTitle, systemImage: recordingActionIcon)
        }
        .disabled(appState.phase == .preparing)

        Text("状態: \(appState.statusText)")
        Text("ホットキー: \(settings.hotkey.displayName)")

        Divider()

        Button("設定を開く…") {
            openWindow(id: "settings", value: SettingsWindowID.main)
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")

        Button("Voxについて") {
            NSApp.orderFrontStandardAboutPanel(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Voxを終了") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var recordingActionTitle: String {
        switch appState.phase {
        case .recording: "録音を停止"
        case .transcribing: "文字起こしをキャンセル"
        default: "音声入力を開始"
        }
    }

    private var recordingActionIcon: String {
        switch appState.phase {
        case .recording: "stop.fill"
        case .transcribing: "xmark.circle.fill"
        default: "mic.fill"
        }
    }
}

private enum SettingsWindowID: String, Codable, Hashable {
    case main
}
