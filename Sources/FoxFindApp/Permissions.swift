import AppKit
import Darwin
import FoxFindCore

enum Permissions {
    private static var relaunch: PermissionRelaunch?
    private static var powerObserver: NSObjectProtocol?
    static func cancelRelaunch() { relaunch?.cancel(); relaunch = nil }
    static func hasFullDiskAccess() -> Bool {
        let path = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        let descriptor = Darwin.open(path, O_RDONLY)
        if descriptor >= 0 { Darwin.close(descriptor); return true }
        guard errno == ENOENT else { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/Library/Safari")) != nil
    }
    static func openSettings() {
        cancelRelaunch()
        if !hasFullDiskAccess(), Bundle.main.bundleURL.pathExtension == "app" {
            do {
                relaunch = try PermissionRelaunch.arm(parentPID: ProcessInfo.processInfo.processIdentifier, application: Bundle.main.bundleURL)
                if powerObserver == nil {
                    powerObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in cancelRelaunch() }
                }
            } catch { AppLog.logger.error("Could not prepare permission relaunch: \(error.localizedDescription, privacy: .public)") }
        }
        if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) { cancelRelaunch() }
    }
}
