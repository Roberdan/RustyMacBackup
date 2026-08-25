import Cocoa

let args = ProcessInfo.processInfo.arguments
if args.count > 1 {
    let cliArgs = Array(args.dropFirst())
    let command = cliArgs.first ?? ""
    let config = CLIHandler.commandNeedsConfig(command) ? (try? Config.load(from: Config.defaultPath)) : nil
    CLIHandler.run(args: cliArgs, config: config)
} else {
    // Program entry: this is the main thread, but top-level code is nonisolated,
    // so the isolation has to be asserted rather than assumed.
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.setInitialConfig(try? Config.load(from: Config.defaultPath))
        app.delegate = delegate
        app.run()
    }
}
