import AppKit
import SwiftUI

@MainActor
final class OverlayViewModel: ObservableObject {
    enum Phase {
        case listening
        case preparingModel
        case transcribing
        case message
    }

    @Published var phase: Phase = .listening
    @Published var levels = Array(repeating: Float(0.08), count: 24)
    @Published var message = ""
    @Published var isSuccess = true

    func append(level: Float) {
        let previous = levels.last ?? 0.08
        let smoothed = previous * 0.36 + level * 0.64
        levels.removeFirst()
        levels.append(smoothed)
    }
}

@MainActor
final class OverlayController {
    private let model = OverlayViewModel()
    private let panel: NSPanel
    private var pendingHide: DispatchWorkItem?

    init() {
        panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 82),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: VoiceOverlayView(model: model))
    }

    func showListening() {
        pendingHide?.cancel()
        model.phase = .listening
        model.levels = Array(repeating: 0.08, count: model.levels.count)
        present()
    }

    func updateLevel(_ level: Float) {
        guard model.phase == .listening else { return }
        model.append(level: level)
    }

    func showTranscribing() {
        pendingHide?.cancel()
        model.phase = .transcribing
        present()
    }

    func showPreparingModel() {
        pendingHide?.cancel()
        model.phase = .preparingModel
        present()
    }

    func showMessage(_ message: String, success: Bool, duration: TimeInterval = 1.2) {
        pendingHide?.cancel()
        model.message = message
        model.isSuccess = success
        model.phase = .message
        present()
        hide(after: duration)
    }

    func hide(after delay: TimeInterval = 0) {
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func present() {
        positionOnActiveScreen()
        panel.orderFrontRegardless()
    }

    private func positionOnActiveScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.minY + 54
        )
        panel.setFrameOrigin(origin)
    }
}

private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct VoiceOverlayView: View {
    @ObservedObject var model: OverlayViewModel

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.47, green: 0.30, blue: 1.0), .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)

            Group {
                switch model.phase {
                case .listening:
                    VStack(alignment: .leading, spacing: 7) {
                        Text("聞いています…")
                            .font(.system(size: 13, weight: .semibold))
                        WaveformView(levels: model.levels)
                            .frame(height: 25)
                    }
                case .preparingModel:
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("モデルを準備中…")
                                .font(.system(size: 13, weight: .semibold))
                            Text("初回は大容量モデルをダウンロードします")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                case .transcribing:
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("文字起こし中…")
                                .font(.system(size: 13, weight: .semibold))
                            Text("large-v3-turbo")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                case .message:
                    Text(model.message)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 17)
        .frame(width: 350, height: 72)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.13), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .padding(.bottom, 10)
    }

    private var iconName: String {
        switch model.phase {
        case .listening: "mic.fill"
        case .preparingModel: "arrow.down.circle.fill"
        case .transcribing: "sparkles"
        case .message: model.isSuccess ? "checkmark" : "exclamationmark"
        }
    }
}

private struct WaveformView: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 3
            let barWidth = max(2, (geometry.size.width - spacing * CGFloat(levels.count - 1)) / CGFloat(levels.count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.blue, Color(red: 0.55, green: 0.33, blue: 1)],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: barWidth, height: max(3, geometry.size.height * CGFloat(level)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(.linear(duration: 0.075), value: levels)
        }
    }
}
