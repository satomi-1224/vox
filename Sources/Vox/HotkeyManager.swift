import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class HotkeyManager {
    var hotkey: Hotkey {
        didSet {
            if isKeyDown {
                isKeyDown = false
                onRelease?()
            }
        }
    }

    var isSuspended = false {
        didSet {
            if isSuspended, isKeyDown {
                isKeyDown = false
                onRelease?()
            }
        }
    }

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onAvailabilityChange: ((Bool) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isKeyDown = false
    private var suppressedKeyCode: UInt16?

    init(hotkey: Hotkey) {
        self.hotkey = hotkey
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    func start() {
        guard eventTap == nil else { return }

        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)

        let reference = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyEventCallback,
            userInfo: reference
        ) else {
            onAvailabilityChange?(false)
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        onAvailabilityChange?(true)
    }

    func restart() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        start()
    }

    /// Returns true when this event belongs to the configured hotkey and must
    /// not reach the foreground application.
    func receive(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return false
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if isSuspended {
            // If capture mode starts while the old hotkey is still held, keep
            // its repeat and key-up events from leaking into the active field.
            if keyCode == suppressedKeyCode, type == .keyDown {
                return true
            }
            if keyCode == suppressedKeyCode, type == .keyUp {
                suppressedKeyCode = nil
                return true
            }
            return false
        }

        let flags = Hotkey.normalizedModifiers(event.flags)
        let expectedFlags = Hotkey.normalizedModifiers(hotkey.eventFlags)

        switch type {
        case .keyDown:
            // Suppress every autorepeat after the initial matching key-down,
            // even if the user releases the modifier before the main key.
            if keyCode == suppressedKeyCode { return true }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            guard !isRepeat, !isKeyDown, keyCode == hotkey.keyCode, flags == expectedFlags else { return false }
            suppressedKeyCode = keyCode
            isKeyDown = true
            onPress?()
            return true

        case .keyUp:
            guard keyCode == suppressedKeyCode else { return false }
            suppressedKeyCode = nil
            if isKeyDown {
                isKeyDown = false
                onRelease?()
            }
            return true

        case .flagsChanged:
            if isKeyDown, flags != expectedFlags {
                isKeyDown = false
                onRelease?()
            }
            // Modifier transitions must remain visible to the foreground app,
            // otherwise it can be left believing Option/Command is held down.
            return false

        default:
            return false
        }
    }

    static var hasInputMonitoringPermission: Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    static func requestInputMonitoringPermission() -> Bool {
        CGRequestListenEventAccess()
    }
}

private let hotkeyEventCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    let shouldSuppress = MainActor.assumeIsolated {
        manager.receive(type: type, event: event)
    }
    return shouldSuppress ? nil : Unmanaged.passUnretained(event)
}
