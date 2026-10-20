import Foundation
import XCTest
@testable import FoxFindCore

final class PermissionRelaunchTests: XCTestCase {
    private func exercise(cancel: Bool = false, timeout: Bool = false, cancelAfterExit: Bool = false) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Fox relaunch ' $ " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let opener = root.appendingPathComponent("record-open"), receipt = root.appendingPathComponent("opened")
        try Data("#!/bin/sh\n/usr/bin/printf '%s\\n' \"$@\" >> \"$(/usr/bin/dirname \"$0\")/opened\"\n".utf8).write(to: opener)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: opener.path)
        let parent = Process(); parent.executableURL = URL(fileURLWithPath: "/bin/sleep"); parent.arguments = ["20"]
        try parent.run(); defer { if parent.isRunning { parent.terminate(); parent.waitUntilExit() } }
        let app = root.appendingPathComponent("Fox ' $(touch should-not-exist).app")
        let watcher = try PermissionRelaunch.arm(parentPID: parent.processIdentifier, application: app, opener: opener,
                                                lifetimeTicks: timeout ? 3 : 300, interval: "0.02", settle: "0.2")
        defer { watcher.cancel(); if watcher.task.isRunning { watcher.task.terminate() } }
        Thread.sleep(forTimeInterval: 0.12)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path), "Must not relaunch a live parent")
        if cancel { watcher.cancel() }
        parent.terminate(); parent.waitUntilExit()
        if cancelAfterExit { watcher.cancel() }
        let deadline = Date().addingTimeInterval(3)
        while watcher.task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertFalse(watcher.task.isRunning, "The helper must be bounded and one-shot")
        XCTAssertFalse(FileManager.default.fileExists(atPath: watcher.ticket.deletingLastPathComponent().path))
        if cancel || timeout || cancelAfterExit {
            XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
        } else {
            XCTAssertEqual(try String(contentsOf: receipt), app.path + "\n--args\n--permission-relaunch\n")
            XCTAssertEqual(watcher.task.terminationStatus, 0)
        }
    }
    func testRelaunchesOnceAfterParentExitsAndPassesPathsLiterally() throws { try exercise() }
    func testExplicitQuitCancelsRelaunch() throws { try exercise(cancel: true) }
    func testAbandonedPermissionFlowExpires() throws { try exercise(timeout: true) }
    func testCancellationDuringSystemRelaunchGracePeriod() throws { try exercise(cancelAfterExit: true) }
}
