import AppKit

if CLI.run(Array(CommandLine.arguments.dropFirst())) {
    WhisperEngine.shared.unload()
    fflush(stdout)
    _exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
