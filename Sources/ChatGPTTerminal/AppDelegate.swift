import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: TerminalController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMainMenu()
        controller = TerminalController()
        configureStatusItem()
        controller?.showWindow()
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "ChatGPT Terminal ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "ChatGPT Terminal beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)

        let edit = NSMenu(title: "Bearbeiten")
        edit.addItem(withTitle: "Widerrufen", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Wiederholen", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Einfügen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        NSApp.mainMenu = mainMenu
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "apple.terminal.fill", accessibilityDescription: "ChatGPT Terminal")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Terminal öffnen", action: #selector(show), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Screenshot aufnehmen", action: #selector(screenshot), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Beenden", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func show() { controller?.showWindow() }
    @objc private func screenshot() { controller?.captureScreenshot() }
    @objc private func quit() { NSApp.terminate(nil) }
}
