import AVFoundation
import CoreGraphics
import Darwin
import Foundation

@MainActor
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@MainActor
private func keyEvent(
    keyCode: CGKeyCode = 49,
    keyDown: Bool,
    flags: CGEventFlags = [],
    isRepeat: Bool = false
) -> CGEvent {
    guard let source = CGEventSource(stateID: .privateState),
          let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
    else {
        fputs("FAIL: could not create synthetic key event\n", stderr)
        exit(1)
    }
    event.flags = flags
    event.setIntegerValueField(.keyboardEventAutorepeat, value: isRepeat ? 1 : 0)
    return event
}

@MainActor
private func testConfiguredHotkeyAndRepeatsAreSuppressed() {
    let manager = HotkeyManager(hotkey: .default)
    var presses = 0
    var releases = 0
    manager.onPress = { presses += 1 }
    manager.onRelease = { releases += 1 }

    expect(
        manager.receive(type: .keyDown, event: keyEvent(keyDown: true, flags: .maskAlternate)),
        "initial Option-Space key-down should be suppressed"
    )
    expect(
        manager.receive(
            type: .keyDown,
            event: keyEvent(keyDown: true, flags: .maskAlternate, isRepeat: true)
        ),
        "Option-Space autorepeat should be suppressed"
    )
    expect(
        manager.receive(type: .keyUp, event: keyEvent(keyDown: false, flags: .maskAlternate)),
        "Option-Space key-up should be suppressed"
    )
    expect(presses == 1, "hotkey should press exactly once")
    expect(releases == 1, "hotkey should release exactly once")
}

@MainActor
private func testPlainSpacePassesThrough() {
    let manager = HotkeyManager(hotkey: .default)
    expect(
        !manager.receive(type: .keyDown, event: keyEvent(keyDown: true)),
        "plain Space key-down should pass through"
    )
    expect(
        !manager.receive(type: .keyUp, event: keyEvent(keyDown: false)),
        "plain Space key-up should pass through"
    )
}

@MainActor
private func testModifierReleaseDoesNotLeakHeldSpace() {
    let manager = HotkeyManager(hotkey: .default)
    var releases = 0
    manager.onRelease = { releases += 1 }

    expect(
        manager.receive(type: .keyDown, event: keyEvent(keyDown: true, flags: .maskAlternate)),
        "hotkey key-down should be suppressed"
    )
    expect(
        !manager.receive(type: .flagsChanged, event: keyEvent(keyCode: 58, keyDown: false)),
        "modifier key-up must reach the foreground app"
    )
    expect(
        manager.receive(type: .keyDown, event: keyEvent(keyDown: true, isRepeat: true)),
        "held Space repeat must remain suppressed after Option is released"
    )
    expect(
        manager.receive(type: .keyUp, event: keyEvent(keyDown: false)),
        "held Space key-up must remain suppressed after Option is released"
    )
    expect(releases == 1, "modifier release should end push-to-talk exactly once")
}

@MainActor
private func testAudioConversionFollowsInputFormatChanges() {
    guard let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    ) else {
        expect(false, "output audio format should be available")
        return
    }
    let converter = AudioBufferConverter(outputFormat: outputFormat)

    for sampleRate in [44_100.0, 48_000.0] {
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 1_024)
        else {
            expect(false, "input audio buffer should be available")
            return
        }
        input.frameLength = input.frameCapacity
        if let samples = input.floatChannelData?[0] {
            for index in 0 ..< Int(input.frameLength) {
                samples[index] = sin(Float(index) * 0.05)
            }
        }

        do {
            let converted = try converter.convert(input)
            expect(converted.frameLength > 0, "audio conversion should produce samples")
            expect(
                converter.inputFormat?.sampleRate == sampleRate,
                "converter should follow the tap buffer's current sample rate"
            )
        } catch {
            expect(false, "audio conversion failed: \(error.localizedDescription)")
        }
    }
}

@MainActor
private func testManagedDictionaryHasPriority() {
    let settings = SettingsStore(configuration: VoxConfiguration(
        hotkey: Hotkey(keyCode: 36, modifiers: CGEventFlags.maskControl.rawValue),
        inputMode: .toggle,
        language: .english,
        model: "test/model",
        dictionary: [
            WorkerDictionaryEntry(source: "ぼっくす", replacement: "Vox"),
            WorkerDictionaryEntry(source: "ぼっくす", replacement: "Box"),
            WorkerDictionaryEntry(source: "えーぴーあい", replacement: "API"),
        ]
    ))

    expect(settings.hotkey.keyCode == 36, "Nix-managed key code should be loaded")
    expect(
        settings.hotkey.eventFlags == .maskControl,
        "Nix-managed modifiers should be loaded"
    )
    expect(settings.inputMode == .toggle, "Nix-managed input mode should be loaded")
    expect(settings.language == .english, "Nix-managed language should be loaded")
    expect(settings.modelID == "test/model", "model should be loaded")

    let merged = settings.workerDictionary
    expect(merged.count == 2, "duplicate sources should be removed")
    expect(
        merged[0].source == "ぼっくす" && merged[0].replacement == "Vox",
        "the first Nix-managed entry should win over a duplicate"
    )
    expect(
        merged[1].source == "えーぴーあい" && merged[1].replacement == "API",
        "unique Nix-managed entry should remain available"
    )
}

@MainActor
private func testMenuBarServiceDisablesAutomaticTermination() {
    var calls: [String] = []

    ApplicationLifecycle.keepMenuBarServiceRunning(
        enableAutomaticTerminationSupport: { calls.append("enable support") },
        disableAutomaticTermination: { reason in calls.append("disable: \(reason)") }
    )

    expect(
        calls == [
            "enable support",
            "disable: \(ApplicationLifecycle.automaticTerminationReason)",
        ],
        "menu bar service should enable support before opting out of automatic termination"
    )
}

MainActor.assumeIsolated {
    testConfiguredHotkeyAndRepeatsAreSuppressed()
    testPlainSpacePassesThrough()
    testModifierReleaseDoesNotLeakHeldSpace()
    testAudioConversionFollowsInputFormatChanges()
    testManagedDictionaryHasPriority()
    testMenuBarServiceDisablesAutomaticTermination()
    print("Swift behavior tests: OK")
}
