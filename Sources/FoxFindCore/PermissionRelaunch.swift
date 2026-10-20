import Foundation

/// A short-lived, one-shot companion survives the privacy pane terminating the app.
/// No login item or persistent launch agent is installed.
public final class PermissionRelaunch {
    let task: Process
    let ticket: URL
    private init(task: Process, ticket: URL) { self.task = task; self.ticket = ticket }

    public static func arm(parentPID: Int32, application: URL) throws -> PermissionRelaunch {
        try arm(parentPID: parentPID, application: application, opener: URL(fileURLWithPath: "/usr/bin/open"),
                lifetimeTicks: 1200, interval: "0.5", settle: "1")
    }

    // Injectable opener/timing allow real subprocess tests without touching TCC or launching the user's app.
    static func arm(parentPID: Int32, application: URL, opener: URL, lifetimeTicks: Int,
                    interval: String, settle: String) throws -> PermissionRelaunch {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("foxfind-permission-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let ticket = directory.appendingPathComponent("pending")
        let task = Process()
        do {
            try Data().write(to: ticket)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ticket.path)
            task.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            // All paths are positional arguments, never executable shell source.
            task.arguments = ["/bin/sh", "-c", """
            pid="$1"; app="$2"; ticket="$3"; directory="$4"; opener="$5"
            limit="$6"; interval="$7"; settle="$8"; ticks=0
            trap '/bin/rm -f "$ticket"; /bin/rmdir "$directory" 2>/dev/null' EXIT
            while [ -f "$ticket" ] && /bin/kill -0 "$pid" 2>/dev/null; do
                ticks=$((ticks + 1))
                if [ "$ticks" -ge "$limit" ]; then exit 0; fi
                /bin/sleep "$interval"
            done
            [ -f "$ticket" ] || exit 0
            /bin/sleep "$settle"
            [ -f "$ticket" ] || exit 0
            /bin/rm -f "$ticket"
            # No -n: if macOS already reopened the app, reuse that instance.
            "$opener" "$app" --args --permission-relaunch
            """, "foxfind-permission", String(parentPID), application.path, ticket.path, directory.path,
            opener.path, String(lifetimeTicks), interval, settle]
            task.standardInput = FileHandle.nullDevice; task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
            try task.run()
            return PermissionRelaunch(task: task, ticket: ticket)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    public func cancel() { try? FileManager.default.removeItem(at: ticket) }
}
