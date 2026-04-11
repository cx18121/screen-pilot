import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Listens for ⌘⇧Space globally via a CGEventTap.
/// Requires Accessibility permission to install the tap.
final class HotkeyManager {
    private let onTrigger: () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    func install() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: HotkeyManager.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = tap else {
            NSLog("ScreenPilot: failed to create CGEventTap — ensure Accessibility permission is granted.")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let hasCmd = flags.contains(.maskCommand)
        let hasShift = flags.contains(.maskShift)
        let hasOption = flags.contains(.maskAlternate)
        let hasControl = flags.contains(.maskControl)

        if keyCode == kVK_Space && hasCmd && hasShift && !hasOption && !hasControl {
            DispatchQueue.main.async { [weak self] in
                self?.onTrigger()
            }
            return nil // consume the event
        }

        return Unmanaged.passUnretained(event)
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo = userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
        return manager.handle(type: type, event: event)
    }
}
