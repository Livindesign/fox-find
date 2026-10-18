import AppKit
import OilFindCore

public enum Application {
    public static func run(appExtension: ApplicationExtension? = nil, arguments: [String] = Array(CommandLine.arguments.dropFirst())) {
#if DEBUG
    if arguments.contains("--workflow-demo") {
        do { try WorkflowDemo.run(); return }
        catch { fputs("Workflow preview: \(error)\n", stderr); exit(1) }
    }
#endif
    if let status = appExtension?.handleLaunch(arguments: arguments) { exit(status) }
    let externalDrives = ExternalDriveCatalog()
#if DEBUG
    var arguments = arguments
    do { try externalDrives.prepareArguments(&arguments); try appExtension?.prepareArguments(&arguments) }
    catch { fputs("Fox Find arguments: \(error)\n", stderr); exit(1) }
    if arguments.contains("--snapshot") {
        appExtension?.attachExternalDrives(externalDrives)
        do { try Snapshot.run(arguments, appExtension: appExtension, externalDrives: externalDrives); exit(0) }
        catch { fputs("Fox Find snapshot: \(error)\n", stderr); exit(1) }
    }

#endif
    let app = NSApplication.shared
    SettingsPreferences.register()
    let delegate = AppDelegate(appExtension: appExtension, externalDrives: externalDrives)
    app.delegate = delegate
    app.run()
    }
}
