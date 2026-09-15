import Foundation

enum ApplicationLifecycle {
    static let automaticTerminationReason = "Vox must remain available for its global hotkey"

    static func keepMenuBarServiceRunning(
        enableAutomaticTerminationSupport: () -> Void = {
            ProcessInfo.processInfo.automaticTerminationSupportEnabled = true
        },
        disableAutomaticTermination: (String) -> Void = ProcessInfo.processInfo.disableAutomaticTermination
    ) {
        // Closing the settings window does not make the global hotkey service idle.
        enableAutomaticTerminationSupport()
        disableAutomaticTermination(automaticTerminationReason)
    }
}
