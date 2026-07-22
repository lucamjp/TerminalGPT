import AppKit

private let sentinel = "EXTERNAL_SELECTION_PROBE_91C4"

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var textView: NSTextView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: -5000, y: -5000, width: 420, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "ChatGPT Selection Probe"

        let textView = NSTextView(frame: window.contentView?.bounds ?? .zero)
        textView.string = sentinel
        textView.isEditable = true
        textView.isSelectable = true
        textView.selectAll(nil)
        window.contentView = textView

        self.window = window
        self.textView = textView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            textView.selectAll(nil)
        }
    }
}

let app = NSApplication.shared
let delegate = ProbeDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
