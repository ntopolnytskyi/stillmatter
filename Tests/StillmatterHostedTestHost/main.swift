// Test-only host. AppDelegate startup is intentionally absent: tests construct
// app services with disposable roots instead of loading user preferences/devices.
import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
application.run()
