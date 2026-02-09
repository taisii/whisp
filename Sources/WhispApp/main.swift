import AppKit
import Foundation

if CommandLine.arguments.contains("--self-check") {
    print("ok")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
