// Test-only host. AppDelegate startup is intentionally absent: tests construct
// app services with disposable roots instead of loading user preferences/devices.
import AppKit

let application = NSApplication.shared
let environment = ProcessInfo.processInfo.environment
let workflowDelegate = environment["STILLMATTER_WORKFLOW_UI_TEST_ROOT"].map {
    WorkflowTestApplication(root: URL(fileURLWithPath: $0))
}
let controlsDelegate = environment["STILLMATTER_CONTROLS_UI_TEST_ROOT"].flatMap { root in
    try? ControlsTestApplication(root: URL(fileURLWithPath: root),
        scenario: environment["STILLMATTER_CONTROLS_UI_TEST_SCENARIO"] ?? "ready")
}
let testDelegate: NSApplicationDelegate? = workflowDelegate ?? controlsDelegate
application.setActivationPolicy(testDelegate == nil ? .prohibited : .regular)
application.delegate = testDelegate
application.run()
