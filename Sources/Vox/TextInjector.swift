import ApplicationServices
import AppKit
import Foundation

enum InjectionResult {
    case pasted
    case copied
}

@MainActor
final class TextInjector {
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func insert(_ text: String) -> InjectionResult {
        let pasteboard = NSPasteboard.general
        let previousContents = Self.snapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let insertedChangeCount = pasteboard.changeCount

        guard Self.hasAccessibilityPermission,
              let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else {
            return .copied
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        let restore = DispatchWorkItem {
            let currentPasteboard = NSPasteboard.general
            guard currentPasteboard.changeCount == insertedChangeCount else { return }
            currentPasteboard.clearContents()
            if !previousContents.isEmpty {
                let items = previousContents.map { contents in
                    let item = NSPasteboardItem()
                    for (rawType, data) in contents {
                        item.setData(data, forType: NSPasteboard.PasteboardType(rawValue: rawType))
                    }
                    return item
                }
                currentPasteboard.writeObjects(items)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(450), execute: restore)
        return .pasted
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[String: Data]] {
        pasteboard.pasteboardItems?.map { item in
            var contents: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    contents[type.rawValue] = data
                }
            }
            return contents
        } ?? []
    }
}
