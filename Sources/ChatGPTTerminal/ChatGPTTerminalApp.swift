import AppKit

/// Process entry point.
@main
struct ChatGPTTerminalApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
