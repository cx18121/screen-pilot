import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Speech

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

    /// Request Speech Recognition + Microphone together. Both are needed for
    /// SFSpeechRecognizer to work; returns true only if the caller can safely
    /// start the audio engine right now. Triggers the system prompts on first
    /// call; subsequent calls only nag if the user denied.
    static func ensureSpeech(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                DispatchQueue.main.async {
                    let speechOK = speechStatus == .authorized
                    if speechOK && micGranted {
                        completion(true)
                        return
                    }
                    let denied = (speechStatus == .denied || speechStatus == .restricted) || !micGranted
                    if denied {
                        showAlert(
                            title: "Speech Recognition Required",
                            message: """
                            ScreenPilot needs Speech Recognition and Microphone permission for voice input.

                            Enable both in System Settings → Privacy & Security, then try again.
                            """,
                            openPaneURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
                        )
                    }
                    completion(false)
                }
            }
        }
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
