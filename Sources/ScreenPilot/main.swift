import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Accessory = no dock icon, can still show floating panels.
app.setActivationPolicy(.accessory)
app.run()
