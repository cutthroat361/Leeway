import AppKit

// Leeway lives only in the menu bar: no Dock icon, no main window.
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
