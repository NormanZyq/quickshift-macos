import AppKit
import ApplicationServices
import InputSafety

if CommandLine.arguments.contains("--diagnostics") {
    let displays = ScreenSnapshot.current().map { display -> [String: Any] in
        ["id": display.id, "name": display.name, "frame": NSStringFromRect(display.frame),
         "visibleFrame": NSStringFromRect(display.visibleFrame)]
    }
    var report: [String: Any] = [
        "version": "1.1.1",
        "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
        "diagnosticProcessAccessibilityTrusted": AXIsProcessTrusted(),
        "displays": displays,
    ]
    if let status = GlobalShortcutMonitor.lastStatus() {
        report["inputEngine"] = [
            "processID": status.processID, "phase": status.phase, "fault": status.fault,
            "events": status.events, "suppressed": status.suppressed, "actions": status.actions,
            "maximumCallbackMicroseconds": Double(status.maximumCallbackNanoseconds) / 1000,
        ]
    }
    if let status = GlobalShortcutMonitor.readStatus(at: GlobalShortcutMonitor.previousFaultURL(for: GlobalShortcutMonitor.defaultStatusURL)) {
        report["previousSafetyExit"] = ["processID": status.processID, "fault": status.fault,
                                        "exitCode": 70 + status.fault, "events": status.events, "actions": status.actions]
    }
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) { print(text) }
} else {
    let application = NSApplication.shared
    application.setActivationPolicy(CommandLine.arguments.contains("--test-target-pid") ? .regular : .accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
