import AppKit
import CoreGraphics
import Foundation

enum InputMode: String, Codable, CaseIterable, Identifiable {
    case pushToTalk
    case toggle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pushToTalk: "プッシュトーク"
        case .toggle: "トグル"
        }
    }

    var help: String {
        switch self {
        case .pushToTalk: "押している間だけ録音します"
        case .toggle: "1回押すと開始、もう1回押すと終了します"
        }
    }
}

enum RecognitionLanguage: String, Codable, CaseIterable, Identifiable {
    case japanese = "ja"
    case automatic = "auto"
    case english = "en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .japanese: "日本語"
        case .automatic: "自動判定"
        case .english: "英語"
        }
    }

    var workerValue: String? { self == .automatic ? nil : rawValue }
}

struct Hotkey: Codable, Equatable, Sendable {
    var keyCode: UInt16
    var modifiers: UInt64

    static let `default` = Hotkey(
        keyCode: 49,
        modifiers: CGEventFlags.maskAlternate.rawValue
    )

    var eventFlags: CGEventFlags { CGEventFlags(rawValue: modifiers) }

    var displayName: String {
        let flags = eventFlags
        var value = ""
        if flags.contains(.maskControl) { value += "⌃" }
        if flags.contains(.maskAlternate) { value += "⌥" }
        if flags.contains(.maskShift) { value += "⇧" }
        if flags.contains(.maskCommand) { value += "⌘" }
        if flags.contains(.maskSecondaryFn) { value += "fn " }
        value += Self.keyName(for: keyCode)
        return value
    }

    static let supportedModifierMask: CGEventFlags = [
        .maskCommand,
        .maskAlternate,
        .maskControl,
        .maskShift,
        .maskSecondaryFn,
    ]

    static func normalizedModifiers(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection(supportedModifierMask)
    }

    static func isUsable(modifiers: CGEventFlags) -> Bool {
        let normalized = normalizedModifiers(modifiers)
        return normalized.contains(.maskCommand)
            || normalized.contains(.maskAlternate)
            || normalized.contains(.maskControl)
            || normalized.contains(.maskSecondaryFn)
    }

    static func keyName(for keyCode: UInt16) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }

    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 49: "Space", 50: "`", 51: "⌫",
        53: "Esc", 65: ".", 67: "*", 69: "+", 71: "Clear", 75: "/",
        76: "↩", 78: "-", 81: "=", 82: "0", 83: "1", 84: "2", 85: "3",
        86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9", 96: "F5",
        97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12",
        113: "F15", 115: "Home", 116: "Page Up", 117: "⌦", 118: "F4",
        119: "End", 120: "F2", 121: "Page Down", 122: "F1", 123: "←",
        124: "→", 125: "↓", 126: "↑", 36: "↩", 48: "Tab",
    ]
}

struct WorkerDictionaryEntry: Codable, Equatable, Sendable {
    let source: String
    let replacement: String
}

struct VoxConfiguration: Decodable, Equatable, Sendable {
    let hotkey: Hotkey
    let inputMode: InputMode
    let language: RecognitionLanguage
    let model: String
    let dictionary: [WorkerDictionaryEntry]

    static let fallback = VoxConfiguration(
        hotkey: .default,
        inputMode: .pushToTalk,
        language: .japanese,
        model: "mlx-community/whisper-large-v3-turbo",
        dictionary: []
    )
}

struct WorkerRequest: Encodable, Sendable {
    let id: String
    let command: String
    var audioPath: String?
    var model: String?
    var language: String?
    var dictionary: [WorkerDictionaryEntry]?

    enum CodingKeys: String, CodingKey {
        case id, command, model, language, dictionary
        case audioPath = "audio_path"
    }
}

struct WorkerMessage: Decodable, Sendable {
    let id: String?
    let type: String
    let state: String?
    let message: String?
    let text: String?
    let language: String?
    let elapsedMs: Double?

    enum CodingKeys: String, CodingKey {
        case id, type, state, message, text, language
        case elapsedMs = "elapsed_ms"
    }
}

struct Transcript: Sendable {
    let text: String
    let language: String?
    let elapsedMilliseconds: Double?
}
