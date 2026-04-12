import AppKit
import Foundation

// Debug mode: survey AX extractor across every running regular app and print
// a table of results. Useful for answering "is AX carrying its weight on the
// apps I actually use?" without wiring it into the real UI flow.
//
// TCC grants (Accessibility especially) are scoped to the bundle identity and
// only apply when launched via LaunchServices. So the intended invocation is
// `open -a /Applications/ScreenPilot.app --args --benchmark-ax`, which means
// stdout goes nowhere. We redirect it to a fixed path the caller can cat.
//
// Usage: swift run ScreenPilot --benchmark-ax   (works only if the swift-run
//        binary itself has AX grant — normally it doesn't)
//        open -a /Applications/ScreenPilot.app --args --benchmark-ax &&
//        sleep 1 && cat /tmp/screenpilot-ax-benchmark.txt
if CommandLine.arguments.contains("--benchmark-ax") {
    runAXBenchmark(outPath: "/tmp/screenpilot-ax-benchmark.txt")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Accessory = no dock icon, can still show floating panels.
app.setActivationPolicy(.accessory)
app.run()

private func runAXBenchmark(outPath: String) {
    // Write through Foundation directly — LaunchServices-launched processes
    // lose their stdout FILE* wiring, so `print` into a freopen'd stdout
    // silently drops. A FileHandle over an open() fd is reliable.
    FileManager.default.createFile(atPath: outPath, contents: nil, attributes: nil)
    guard let fh = FileHandle(forWritingAtPath: outPath) else { return }
    defer { try? fh.close() }
    func emit(_ s: String) {
        if let d = (s + "\n").data(using: .utf8) { fh.write(d) }
    }
    func emitSampleLine(_ s: String) {
        if let d = s.data(using: .utf8) { fh.write(d) }
    }

    guard AXIsProcessTrusted() else {
        emit("Accessibility not granted. Grant it in System Settings → Privacy & Security → Accessibility and re-run.")
        return
    }
    let apps = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular && $0.processIdentifier > 0
    }

    emit("App                                  nodes    chars  ~tokens    ms   result")
    emit(String(repeating: "-", count: 78))

    var kept = 0
    var skipped = 0
    var totalChars = 0
    var totalMs: Double = 0
    var samples: [(String, String)] = []

    // Sort by pid for stability across runs — makes it easy to diff output.
    let sorted = apps.sorted { $0.processIdentifier < $1.processIdentifier }

    for app in sorted {
        let name = app.localizedName ?? "?"
        let pid = app.processIdentifier
        // Emit a breadcrumb BEFORE the AX call so that if extractTree crashes
        // we can see in the output file which app was the culprit. The real
        // row gets appended on the next line either way.
        emit("# trying \(name) (pid \(pid))")
        let t0 = Date()
        var tree: String?
        autoreleasepool {
            tree = AXExtractor.extractTree(forPID: pid)
        }
        let ms = Date().timeIntervalSince(t0) * 1000
        totalMs += ms

        let nameCol = name.padding(toLength: 36, withPad: " ", startingAt: 0)
        if let tree = tree {
            let nodes = tree.split(separator: "\n").count
            let chars = tree.count
            let tokens = chars / 4
            kept += 1
            totalChars += chars
            emit(String(format: "%@ %6d %8d %8d %5.1f   kept", nameCol as NSString, nodes, chars, tokens, ms))
            samples.append((name, tree))
        } else {
            skipped += 1
            // Pre-format each dash column as a padded Swift string, then feed
            // them via %@. %s in String(format:) reads a C string, which
            // segfaults when passed a Swift String literal.
            let dashSmall = "-".padding(toLength: 6, withPad: " ", startingAt: 0)
            let dashBig = "-".padding(toLength: 8, withPad: " ", startingAt: 0)
            emit(String(
                format: "%@ %@ %@ %@ %5.1f   skipped",
                nameCol as NSString,
                dashSmall as NSString,
                dashBig as NSString,
                dashBig as NSString,
                ms
            ))
        }
    }

    emit(String(repeating: "-", count: 78))
    let avgChars = kept > 0 ? totalChars / kept : 0
    emit(String(format: "Total: %d apps — %d kept, %d skipped. Avg kept tree: %d chars (~%d tokens). Total AX time: %.0fms.",
                 apps.count, kept, skipped, avgChars, avgChars / 4, totalMs))

    // Sample dumps: first 25 lines of each kept tree so we can eyeball
    // whether the pruning is picking real controls vs. noise.
    emit("")
    emit("=== Sample extracts (first 25 lines per app) ===")
    for (name, tree) in samples {
        emit("")
        emit("— \(name) —")
        let head = tree.split(separator: "\n").prefix(25).joined(separator: "\n")
        emitSampleLine(head + "\n")
    }
}
