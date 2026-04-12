import ApplicationServices
import AppKit
import CoreGraphics

/// Extracts a pruned, compact textual description of an application's focused
/// window from the macOS Accessibility tree, suitable for sending to the model
/// alongside a screenshot. See `project_ax_context_layer.md` for motivation —
/// AX gives us structured roles/labels/values that pixel OCR can't, and for
/// AX-rich apps it's more accurate and cheaper (token-wise) than relying on a
/// larger screenshot.
enum AXExtractor {
    /// Below this, we assume the app exports a junk tree (Electron without AX,
    /// games, old Swing apps) and skip AX entirely — caller falls back to
    /// image+OCR only.
    static let minNodesForUsefulTree = 5
    static let maxNodes = 150
    static let maxDepth = 8
    /// Hard wall-clock budget. Per-element messaging timeouts don't propagate
    /// to children (Apple only applies the timeout to the exact element it
    /// was set on), so Electron apps with deep AX trees can stall us for
    /// minutes. This caps the entire extract regardless of depth.
    static let maxWallClockSeconds: TimeInterval = 0.5
    /// Hard cap on queue dequeues. Belt-and-suspenders against a single-app
    /// tree with millions of nodes bypassing the node cap via virtualized
    /// rows that all get rejected by frame-intersection.
    static let maxQueuePops = 3000

    /// Returns a compact pruned-AX description of the focused window of `pid`,
    /// or nil if AX is disabled, the app is unresponsive, or the pruned tree
    /// is below `minNodesForUsefulTree` entries.
    static func extractTree(forPID pid: pid_t) -> String? {
        // Non-prompting trust check. If Accessibility was revoked we return
        // nil silently — caller keeps the current image+OCR behavior.
        guard AXIsProcessTrusted() else { return nil }

        let app = AXUIElementCreateApplication(pid)
        // Cap per-message blocking so a hung target app can't stall the main
        // actor for seconds. Healthy apps answer in microseconds.
        AXUIElementSetMessagingTimeout(app, 0.3)

        guard let windowElement = copyElementAttribute(app, kAXFocusedWindowAttribute) else {
            return nil
        }
        let windowFrame = frame(of: windowElement) ?? .null

        var lines: [String] = []

        // Focused UI element first, unconditionally — it's often the subject
        // of the user's question ("what's wrong with this field I'm typing").
        // We stash it so the BFS walker can skip it and avoid emitting the
        // same element twice.
        let focusedElement = copyElementAttribute(app, kAXFocusedUIElementAttribute)
        if let focused = focusedElement,
           let line = serialize(focused, forceEmit: true, tag: "focused") {
            lines.append(line)
        }

        // BFS from window root so top-level chrome wins over deep virtualized
        // lists. That matches how a person scans a UI and keeps the most
        // load-bearing controls regardless of where the node cap lands.
        let deadline = Date().addingTimeInterval(maxWallClockSeconds)
        var queue: [(AXUIElement, Int)] = [(windowElement, 0)]
        var pops = 0
        while !queue.isEmpty && lines.count < maxNodes && pops < maxQueuePops {
            if Date() > deadline { break }
            pops += 1
            let (elem, depth) = queue.removeFirst()
            if depth > maxDepth { continue }

            // Clip to visible window bounds: drop off-screen menu items,
            // virtualized rows, etc. Biggest source of token bloat by far.
            if depth > 0, let f = frame(of: elem), !windowFrame.isNull, !f.intersects(windowFrame) {
                continue
            }

            // Skip the focused element during the walk — it was already
            // emitted at the top with the `focused` tag. AXUIElement supports
            // CFEqual (it's a CF type) so a direct equality check is safe.
            let isFocused: Bool = {
                guard let f = focusedElement else { return false }
                return CFEqual(elem, f)
            }()

            if depth > 0, !isFocused, let line = serialize(elem) {
                lines.append(line)
            }

            // Also apply the messaging timeout to this element before we
            // poll it for children — Apple's timeout only applies to the
            // specific element it was set on, so inheriting from the app
            // element isn't a thing and Electron children can hang.
            AXUIElementSetMessagingTimeout(elem, 0.3)

            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let kidsAny = childrenRef,
               CFGetTypeID(kidsAny) == CFArrayGetTypeID() {
                // CF array of AXUIElement — iterate via CFArray primitives
                // and typeID-check each entry, so a malformed child value
                // can't trap Swift's `as?` bridge.
                let kidsArray = kidsAny as! CFArray
                let count = CFArrayGetCount(kidsArray)
                for i in 0..<count {
                    let raw = CFArrayGetValueAtIndex(kidsArray, i)
                    let cfRef = unsafeBitCast(raw, to: CFTypeRef.self)
                    if CFGetTypeID(cfRef) == AXUIElementGetTypeID() {
                        queue.append((cfRef as! AXUIElement, depth + 1))
                    }
                }
            }
        }

        guard lines.count >= minNodesForUsefulTree else { return nil }
        return lines.joined(separator: "\n")
    }

    // Pure-layout wrappers with no label of their own get dropped — their
    // labeled descendants will still be walked by BFS and emitted on their
    // own lines.
    private static let layoutRoles: Set<String> = [
        "AXGroup",
        "AXLayoutArea",
        "AXLayoutItem",
        "AXSplitGroup",
        "AXSplitter",
        "AXScrollArea",
        "AXScrollBar",
        "AXToolbar",
        "AXUnknown"
    ]

    /// Labels we know are macOS-generated boilerplate that appears in every
    /// app's AX tree and never helps the model. Currently: the green
    /// traffic-light "zoom" button that shows up on every windowed app with
    /// this exact long string.
    private static let noiseLabels: Set<String> = [
        "this button also has an action to zoom the window"
    ]

    private static func serialize(
        _ elem: AXUIElement,
        forceEmit: Bool = false,
        tag: String? = nil
    ) -> String? {
        let role = stringAttr(elem, kAXRoleAttribute) ?? "AXUnknown"
        // Menu bar is huge and never what the user is asking about.
        if role == "AXMenuBar" || role == "AXMenuBarItem" { return nil }

        let title = stringAttr(elem, kAXTitleAttribute)
        let desc  = stringAttr(elem, kAXDescriptionAttribute)
        let help  = stringAttr(elem, kAXHelpAttribute)
        let value = stringAttr(elem, kAXValueAttribute)

        let label = title ?? desc ?? help
        let hasAnyText = (label != nil) || (value != nil)

        if !forceEmit, let l = label, noiseLabels.contains(l) { return nil }

        if !forceEmit {
            if !hasAnyText && layoutRoles.contains(role) { return nil }
            if !hasAnyText { return nil }
        }

        var out = ""
        if let tag = tag { out += "\(tag) " }
        out += role
        if let l = label, !l.isEmpty {
            out += " \"\(sanitize(l))\""
        }
        if let v = value, !v.isEmpty, v != label {
            out += " = \"\(sanitize(v))\""
        }
        if let f = frame(of: elem) {
            out += " @ (\(Int(f.origin.x)),\(Int(f.origin.y)),\(Int(f.width)),\(Int(f.height)))"
        }
        return out
    }

    private static func sanitize(_ s: String) -> String {
        // One big text-area value shouldn't blow the whole budget.
        let collapsed = s
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= 120 { return trimmed }
        return String(trimmed.prefix(120)) + "…"
    }

    private static func stringAttr(_ elem: AXUIElement, _ key: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elem, key as CFString, &ref) == .success else { return nil }
        if let s = ref as? String { return s.isEmpty ? nil : s }
        if let n = ref as? NSNumber { return n.stringValue }
        return nil
    }

    private static func frame(of elem: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elem, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(elem, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pos = posRef, let size = sizeRef else {
            return nil
        }
        // Apps occasionally return something that isn't an AXValue here (seen
        // in the wild with a few Electron apps). Type-check via CFGetTypeID so
        // we fall back to nil rather than trapping.
        let axValueTypeID = AXValueGetTypeID()
        guard CFGetTypeID(pos) == axValueTypeID,
              CFGetTypeID(size) == axValueTypeID else {
            return nil
        }
        let posVal = pos as! AXValue
        let sizeVal = size as! AXValue
        var point = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(posVal, .cgPoint, &point),
              AXValueGetValue(sizeVal, .cgSize, &sz) else {
            return nil
        }
        return CGRect(origin: point, size: sz)
    }

    /// Safe fetch of an AXUIElement attribute — returns nil if the value
    /// either can't be fetched or isn't the expected element type. Avoids
    /// `as! AXUIElement` traps from apps that return weird CF types.
    private static func copyElementAttribute(_ elem: AXUIElement, _ key: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elem, key as CFString, &ref) == .success,
              let any = ref else { return nil }
        guard CFGetTypeID(any) == AXUIElementGetTypeID() else { return nil }
        return (any as! AXUIElement)
    }
}
