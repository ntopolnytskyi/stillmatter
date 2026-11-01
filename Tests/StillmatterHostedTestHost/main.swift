// Test-only host. AppDelegate startup is intentionally absent: tests construct
// app services with disposable roots instead of loading user preferences/devices.
import AppKit

let application = NSApplication.shared
let controlsRoot = ProcessInfo.processInfo.environment["STILLMATTER_CONTROLS_UI_TEST_ROOT"]
let controlsDelegate = controlsRoot.flatMap { try? ControlsTestApplication(root: URL(fileURLWithPath: $0),
    scenario: ProcessInfo.processInfo.environment["STILLMATTER_CONTROLS_UI_TEST_SCENARIO"] ?? "ready") }
application.setActivationPolicy(controlsDelegate == nil ? .prohibited : .regular)
application.delegate = controlsDelegate
application.run()
