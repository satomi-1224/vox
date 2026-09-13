import AppKit
import SwiftUI

@main
struct VoxApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        Window("Vox", id: "settings") {
            SettingsView(appState: appState)
        }
        .defaultSize(width: 620, height: 760)
        .windowResizability(.contentSize)

        MenuBarExtra {
            VoxMenu(appState: appState)
        } label: {
            Image(systemName: appState.statusIcon)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.menu)
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
            openWindow(id: "settings")
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
