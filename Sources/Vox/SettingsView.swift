import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var settings: SettingsStore

    init(appState: AppState) {
        self.appState = appState
        _settings = ObservedObject(wrappedValue: appState.settings)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                permissionsCard
                configurationCard
                dictionaryCard
                modelCard
                configurationFooter
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 24)
        }
        .frame(width: 620)
        .frame(minHeight: 700)
        .background {
            ZStack(alignment: .topLeading) {
                Color(nsColor: .windowBackgroundColor)
                RadialGradient(
                    colors: [Color.blue.opacity(0.09), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 390
                )
                .allowsHitTesting(false)
            }
        }
        .onAppear { appState.refreshPermissions() }
    }

    private var header: some View {
        HStack(spacing: 17) {
            Image(nsImage: applicationIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 68, height: 68)
                .shadow(color: Color.blue.opacity(0.22), radius: 13, y: 7)

            VStack(alignment: .leading, spacing: 4) {
                Text("Vox")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                Text("ローカルで、高速に音声入力")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(
                text: appState.modelState.label,
                active: appState.modelState.isReady
            )
        }
        .padding(.horizontal, 2)
    }

    private var permissionsCard: some View {
        SettingsCard(title: "システム権限", systemImage: "checkmark.shield") {
            VStack(spacing: 11) {
                PermissionRow(
                    title: "マイク",
                    detail: "声を録音するために使用",
                    granted: appState.hasMicrophonePermission,
                    action: appState.requestMicrophonePermission
                )
                Divider()
                PermissionRow(
                    title: "入力監視",
                    detail: inputMonitoringDetail,
                    granted: appState.hasInputMonitoringPermission && appState.hotkeyIsAvailable,
                    action: appState.requestInputMonitoringPermission
                )
                Divider()
                PermissionRow(
                    title: "アクセシビリティ",
                    detail: "認識したテキストを現在のアプリへ入力",
                    granted: appState.hasAccessibilityPermission,
                    action: appState.requestAccessibilityPermission
                )
            }
        }
    }

    private var configurationCard: some View {
        SettingsCard(title: "音声入力", systemImage: "waveform.badge.mic") {
            VStack(spacing: 0) {
                ConfigurationRow(
                    title: "ホットキー",
                    detail: "前面アプリへキーを入力せず音声入力を開始",
                    value: settings.hotkey.displayName,
                    monospaced: true
                )
                Divider()
                ConfigurationRow(
                    title: "操作方法",
                    detail: settings.inputMode.help,
                    value: settings.inputMode.title
                )
                Divider()
                ConfigurationRow(
                    title: "認識言語",
                    detail: "固定すると言語判定の待ち時間を省けます",
                    value: settings.language.title
                )
            }
        }
    }

    private var dictionaryCard: some View {
        SettingsCard(title: "辞書", systemImage: "text.book.closed") {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text("誤認識を希望する表記へ補正")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    CountPill(count: settings.dictionary.count)
                }

                if settings.dictionary.isEmpty {
                    HStack(spacing: 9) {
                        Image(systemName: "text.badge.plus")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("辞書はまだ空です")
                                .font(.system(size: 13, weight: .medium))
                            Text("config.nix に source と replacement を追加できます")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 5)
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(settings.dictionary.prefix(12).enumerated()), id: \.offset) { _, entry in
                            HStack(spacing: 10) {
                                Text(entry.source)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "arrow.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Text(entry.replacement)
                                    .fontWeight(.medium)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 12.5))
                            .textSelection(.enabled)

                            if entry != settings.dictionary.prefix(12).last {
                                Divider()
                            }
                        }
                    }
                    .padding(11)
                    .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    if settings.dictionary.count > 12 {
                        Text("ほか \(settings.dictionary.count - 12) 件も適用されています")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var modelCard: some View {
        SettingsCard(title: "音声認識モデル", systemImage: "cpu") {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("mlx-whisper / large-v3-turbo")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    if appState.modelState.isReady {
                        Label("メモリ常駐", systemImage: "bolt.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                Text(settings.modelID)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("初回のみモデルをダウンロードします。以降は起動時に先読みして、録音後の待ち時間を短縮します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !appState.lastTranscript.isEmpty {
                    Divider()
                    HStack(alignment: .firstTextBaseline) {
                        Text("直前の認識")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let elapsed = appState.lastElapsedMilliseconds {
                            Text(String(format: "%.2f秒", elapsed / 1_000))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(appState.lastTranscript)
                        .font(.caption)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var configurationFooter: some View {
        HStack(spacing: 7) {
            Image(systemName: settings.isNixManaged ? "lock.fill" : "exclamationmark.triangle.fill")
            Text(settings.isNixManaged
                ? "\(settings.configurationSourceLabel) から宣言的に管理されています"
                : "Nix構成が見つからないため、内蔵デフォルトで動作しています")
        }
        .font(.caption)
        .foregroundStyle(settings.isNixManaged ? Color.secondary : Color.orange)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var applicationIcon: NSImage {
        if let url = Bundle.main.url(forResource: "Vox", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApp.applicationIconImage
    }

    private var inputMonitoringDetail: String {
        if appState.hasInputMonitoringPermission && !appState.hotkeyIsAvailable {
            return "許可済み・ホットキーを再接続中"
        }
        return "どのアプリでもホットキーを検出"
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary, Color.blue)
            content
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.075), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.035), radius: 9, y: 3)
    }
}

private struct ConfigurationRow: View {
    let title: String
    let detail: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced
                    ? .system(size: 13, weight: .semibold, design: .rounded)
                    : .system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
        }
        .padding(.vertical, 10)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("許可する", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Text("許可済み")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
        }
    }
}

private struct StatusPill: View {
    let text: String
    let active: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? .green : .orange)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary, in: Capsule())
    }
}

private struct CountPill: View {
    let count: Int

    var body: some View {
        Text("\(count)件")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.blue.opacity(0.11), in: Capsule())
            .foregroundStyle(Color.blue)
    }
}
