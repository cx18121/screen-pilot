import AppKit
import ApplicationServices
import CoreGraphics

enum PermissionsManager {
    @discardableResult
    static func ensureAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: NSDictionary = [key: true]
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            showAlert(
                title: "Accessibility Required",
                message: """
                ScreenPilot needs Accessibility permission to listen for the global hotkey (⌘⇧Space).

                Enable it in System Settings → Privacy & Security → Accessibility, then relaunch ScreenPilot.
                """,
                openPaneURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        }
        return trusted
    }

    @discardableResult
    static func ensureScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // Trigger the system prompt the first time.
        CGRequestScreenCaptureAccess()
        showAlert(
            title: "Screen Recording Required",
            message: """
            ScreenPilot needs Screen Recording permission to capture what you're looking at.

            Enable it in System Settings → Privacy & Security → Screen Recording, then relaunch ScreenPilot.
            """,
            openPaneURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
        return false
    }

    private static func showAlert(title: String, message: String, openPaneURL: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn, let url = URL(string: openPaneURL) {
            NSWorkspace.shared.open(url)
        }
    }
}
