import Cocoa
import MachookCore

// Machook is a menu bar app and nothing else: no CLI modes, no headless
// branch. Everything remote arrives over the HTTP server that
// `AppDelegate` brings up, whether that is a webhook or an MCP tool call.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
