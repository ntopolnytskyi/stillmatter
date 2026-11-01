// Non-shipped, read-only hardware probe. Never requests permission or starts capture.
import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

var displayCount: UInt32 = 0
let displayStatus = CGGetOnlineDisplayList(0, nil, &displayCount)
let apps: [(String, String)] = [
    ("Teams", "/Applications/Microsoft Teams.localized/Microsoft Teams.app"),
    ("Zoom", "/Applications/zoom.us.app"),
    ("Chrome", "/Applications/Google Chrome.app")
]
let versions = apps.map { name, path -> [String: Any] in
    let bundle = Bundle(path: path)
    return ["application": name, "installed": bundle != nil,
            "version": bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unavailable"]
}
let result: [String: Any] = [
    "os": ProcessInfo.processInfo.operatingSystemVersionString,
    "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
    "processorCount": ProcessInfo.processInfo.processorCount,
    "screenCaptureAuthorized": CGPreflightScreenCaptureAccess(),
    "accessibilityAuthorized": AXIsProcessTrusted(),
    "microphoneAuthorizationRawValue": AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
    "displayQueryStatus": displayStatus.rawValue,
    "onlineDisplayCount": displayCount,
    "applications": versions,
    "captureStarted": false,
    "permissionRequested": false
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
