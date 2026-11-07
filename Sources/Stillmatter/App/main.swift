import AppKit

#if STILLMATTER_CAPTURE_PROBE
if CommandLine.arguments.count == 2 {
    exit(TeamsCallAudioProbe.run(CommandLine.arguments[1]))
}
fatalError("The disposable capture probe requires --permission or --capture")
#else
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
#endif
