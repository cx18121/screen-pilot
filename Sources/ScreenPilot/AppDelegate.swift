import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AssistantCoordinator!
    private var hotkeyManager: HotkeyManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        PermissionsManager.ensureAccessibility()
        PermissionsManager.ensureScreenRecording()

        coordinator = AssistantCoordinator()
        hotkeyManager = HotkeyManager { [weak self] in
            self?.coordinator.trigger()
        }
        hotkeyManager.install()
    }
}
