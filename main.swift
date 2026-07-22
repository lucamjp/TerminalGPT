import AppKit
import ApplicationServices
import Carbon
import PDFKit
import UniformTypeIdentifiers
import WebKit

private let hotKeySignature: OSType = 0x54525633 // TRV3

#if BETA_BUILD
private let terminalPanelTitle = "ChatGPT Terminal Beta 3.3.2 (Build 33)"
private let terminalAddress = "chatgpt://terminal/v3-beta"
private let selectionShortcutLabel = "⌃⌥⇧C"
#else
private let terminalPanelTitle = "ChatGPT Terminal 3.3.3 (Build 34)"
private let terminalAddress = "chatgpt://terminal/v3"
private let selectionShortcutLabel = "⌘⇧C"
#endif

private enum HotKeyID: UInt32 {
    case window = 1
    case screenshot = 2
    case copyLatest = 3
    case send = 4
    case captureSelection = 5
}

private struct PendingAttachment {
    let data: Data
    let pasteboardType: NSPasteboard.PasteboardType
    let preview: NSImage
    let fileName: String
    let mimeType: String
}

private func imageAttachment(from image: NSImage, fileName: String = "clipboard-image.png") -> PendingAttachment? {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
    return PendingAttachment(data: png, pasteboardType: .png, preview: image, fileName: fileName, mimeType: "image/png")
}

private func pdfAttachment(from data: Data, fileName: String = "clipboard-document.pdf") -> PendingAttachment? {
    guard let document = PDFDocument(data: data), let firstPage = document.page(at: 0) else { return nil }
    let preview = firstPage.thumbnail(of: NSSize(width: 180, height: 180), for: .cropBox)
    return PendingAttachment(data: data, pasteboardType: .pdf, preview: preview, fileName: fileName, mimeType: "application/pdf")
}

private final class TerminalInputView: NSTextView {
    var attachmentsDidChange: (([PendingAttachment]) -> Void)?
    var historyNavigationRequested: ((Int) -> Void)?
    var sendRequested: (() -> Void)?
    private(set) var pendingAttachments: [PendingAttachment] = []

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty, event.keyCode == UInt16(kVK_UpArrow) {
            historyNavigationRequested?(-1)
            return
        }
        if modifiers.isEmpty, event.keyCode == UInt16(kVK_DownArrow) {
            historyNavigationRequested?(1)
            return
        }
        if modifiers.isEmpty, event.keyCode == UInt16(kVK_Return) {
            sendRequested?()
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if importAttachments(from: board) { return }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canImportAttachments(from: sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        importAttachments(from: sender.draggingPasteboard) || super.performDragOperation(sender)
    }

    func clearAll() {
        string = ""
        pendingAttachments.removeAll()
        attachmentsDidChange?(pendingAttachments)
    }

    func setAttachments(_ attachments: [PendingAttachment]) {
        pendingAttachments = attachments
        attachmentsDidChange?(pendingAttachments)
    }

    private func canImportAttachments(from board: NSPasteboard) -> Bool {
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png, .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("org.webmproject.webp")
        ]
        return board.availableType(from: imageTypes + [.pdf]) != nil ||
            board.canReadObject(forClasses: [NSImage.self, NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    @discardableResult
    private func importAttachments(from board: NSPasteboard) -> Bool {
        var imported: [PendingAttachment] = []

        if let data = board.data(forType: .pdf), let item = pdfAttachment(from: data) {
            imported.append(item)
        }

        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png, .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("org.webmproject.webp")
        ]
        if let type = board.availableType(from: imageTypes),
           let data = board.data(forType: type),
           let image = NSImage(data: data),
           let item = imageAttachment(from: image) {
            imported.append(item)
        }

        if imported.isEmpty, let objects = board.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            for image in objects {
                if let item = imageAttachment(from: image) { imported.append(item) }
            }
        }

        if imported.isEmpty, let image = NSImage(pasteboard: board), let item = imageAttachment(from: image) {
            imported.append(item)
        }

        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in urls {
                let type = UTType(filenameExtension: url.pathExtension)
                if type?.conforms(to: .pdf) == true,
                   let data = try? Data(contentsOf: url),
                   let item = pdfAttachment(from: data, fileName: url.lastPathComponent) {
                    imported.append(item)
                } else if type?.conforms(to: .image) == true,
                          let image = NSImage(contentsOf: url),
                          let item = imageAttachment(from: image, fileName: url.deletingPathExtension().lastPathComponent + ".png") {
                    imported.append(item)
                }
            }
        }

        var seen = Set<String>()
        imported = imported.filter { attachment in
            let key = "\(attachment.mimeType)|\(attachment.data.count)|\(attachment.data.hashValue)"
            return seen.insert(key).inserted
        }
        guard !imported.isEmpty else { return false }
        pendingAttachments.append(contentsOf: imported)
        attachmentsDidChange?(pendingAttachments)
        return true
    }
}

final class TerminalController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NSTextViewDelegate, NSSearchFieldDelegate {
    private let panel: NSPanel
    private let transcriptView: WKWebView
    private let sessionView: WKWebView
    private let inputView: TerminalInputView
    private let imageStrip = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "Sitzung wird geladen …")
    private let modelPopup = NSPopUpButton()
    private let themePopup = NSPopUpButton()
    private let searchBar = NSView()
    private let searchField = NSSearchField()
    private let searchResultLabel = NSTextField(labelWithString: "")
    private let sessionWindow: NSWindow
    private let hiddenSessionHost = NSView()
    private var hotKeyRef: EventHotKeyRef?
    private var screenshotHotKeyRef: EventHotKeyRef?
    private var copyHotKeyRef: EventHotKeyRef?
    private var sendHotKeyRef: EventHotKeyRef?
    private var captureSelectionHotKeyRef: EventHotKeyRef?
    private var captureSelectionHotKeyRegistrationStatus: OSStatus = -1
    private var eventHandler: EventHandlerRef?
    private var keyMonitor: Any?
    private var userInteractionGeneration = 0
    private var lockHandled = false
    private var isSending = false
    private var responseObserverInstalled = false
    private var thinkingPlaceholderShown = false
    private var exactLatexMode = false
    private var exactLatexFinalizationScheduled = false
    private var exactLatexFinalizationToken = 0
    private var pendingExactLatexHTML: String?
    private var submissionHasAttachments = false
    private var submissionGeneration = 0
    private var pendingNativeUploadURLs: [URL]?
    private var nativeUploadCompletion: ((Bool) -> Void)?
    private var nativeUploadRequestID: UUID?
    private var currentAssistantID: String?
    private var didFinishInitialLoad = false
    private var detectedModel = "awaiting first response …"
    private var terminalDocumentReady = false
    private var windowShortcut = "⌥ Leertaste"
    private var screenshotShortcut = "⌥⇧4"
    private var inputHistory = UserDefaults.standard.stringArray(forKey: "ChatGPTTerminalInputHistory") ?? []
    private var historyIndex: Int?
    private var historyDraft = ""
    private var savedTranscriptHTML: String?
    private var savedTranscriptModel: String?
    private let persistenceQueue = DispatchQueue(label: "local.chatgpt.terminal.persistence", qos: .utility)
    private weak var rootView: NSView?
    private weak var headerView: NSView?
    private weak var composerView: NSView?
    private weak var titleLabel: NSTextField?
    private weak var promptLabel: NSTextField?
    private weak var searchPromptLabel: NSTextField?
    private var symbolButtons: [NSButton] = []
    private var searchBarHeightConstraint: NSLayoutConstraint?
    private var isSearchVisible = false
    private var selectionCaptureGeneration = 0
    private var pendingConversationImport = false
    private var conversationImportGeneration = 0
    private var conversationReturnURL: URL?

    private var readyStatusText: String {
        "Bereit · \(windowShortcut) · Screenshot \(screenshotShortcut)"
    }

    override init() {
        let terminalConfig = WKWebViewConfiguration()
        terminalConfig.defaultWebpagePreferences.allowsContentJavaScript = true
        let terminalContentController = WKUserContentController()
        terminalConfig.userContentController = terminalContentController
        transcriptView = WKWebView(frame: .zero, configuration: terminalConfig)

        let contentController = WKUserContentController()
        let sessionConfig = WKWebViewConfiguration()
        sessionConfig.websiteDataStore = .default()
        sessionConfig.defaultWebpagePreferences.allowsContentJavaScript = true
        sessionConfig.userContentController = contentController
        sessionView = WKWebView(frame: .zero, configuration: sessionConfig)

        inputView = TerminalInputView(frame: .zero)
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        sessionWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        savedTranscriptHTML = UserDefaults.standard.string(forKey: "ChatGPTTerminalSavedTranscriptHTML")
        savedTranscriptModel = UserDefaults.standard.string(forKey: "ChatGPTTerminalSavedTranscriptModel")
        terminalContentController.add(self, name: "terminalStateBridge")
        contentController.add(self, name: "terminalBridge")
        configurePanel()
        configureSessionWindow()
        configureHotKeys()
        configureKeyboard()
        configureLockHandling()
        loadTerminalDocument()
        loadChatGPT(newChat: false)
    }

    deinit {
        transcriptView.configuration.userContentController.removeScriptMessageHandler(forName: "terminalStateBridge")
        sessionView.configuration.userContentController.removeScriptMessageHandler(forName: "terminalBridge")
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let screenshotHotKeyRef { UnregisterEventHotKey(screenshotHotKeyRef) }
        if let copyHotKeyRef { UnregisterEventHotKey(copyHotKeyRef) }
        if let sendHotKeyRef { UnregisterEventHotKey(sendHotKeyRef) }
        if let captureSelectionHotKeyRef { UnregisterEventHotKey(captureSelectionHotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func configurePanel() {
        panel.title = terminalPanelTitle
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.06, alpha: 1)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.alphaValue = 0.96
        panel.delegate = self
        panel.minSize = NSSize(width: 520, height: 560)
        panel.setFrameAutosaveName("ChatGPTTerminalV3Frame")
        if !panel.setFrameUsingName("ChatGPTTerminalV3Frame"), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 24, y: visible.midY - panel.frame.height / 2))
        }

        let root = NSView()
        rootView = root
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.06, alpha: 1).cgColor
        panel.contentView = root

        let header = makeHeader()
        headerView = header
        root.addSubview(header)

        transcriptView.translatesAutoresizingMaskIntoConstraints = false
        transcriptView.navigationDelegate = self
        transcriptView.setValue(false, forKey: "drawsBackground")
        root.addSubview(transcriptView)

        configureSearchBar()
        root.addSubview(searchBar)

        let composer = makeComposer()
        composerView = composer
        root.addSubview(composer)

        hiddenSessionHost.translatesAutoresizingMaskIntoConstraints = false
        hiddenSessionHost.alphaValue = 0.01
        hiddenSessionHost.wantsLayer = true
        hiddenSessionHost.layer?.masksToBounds = true
        root.addSubview(hiddenSessionHost)
        attachSessionToPanel()

        let searchHeight = searchBar.heightAnchor.constraint(equalToConstant: 0)
        searchBarHeightConstraint = searchHeight
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 58),

            transcriptView.topAnchor.constraint(equalTo: header.bottomAnchor),
            transcriptView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transcriptView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transcriptView.bottomAnchor.constraint(equalTo: searchBar.topAnchor),

            searchBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            searchBar.bottomAnchor.constraint(equalTo: composer.topAnchor),
            searchHeight,

            composer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            composer.heightAnchor.constraint(greaterThanOrEqualToConstant: 146),

            hiddenSessionHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hiddenSessionHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            hiddenSessionHost.widthAnchor.constraint(equalToConstant: 2),
            hiddenSessionHost.heightAnchor.constraint(equalToConstant: 2)
        ])
        applyTheme()
    }

    private func configureSearchBar() {
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.wantsLayer = true
        searchBar.isHidden = true
        searchBar.layer?.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.065, alpha: 1).cgColor
        searchBar.layer?.borderColor = NSColor(calibratedWhite: 0.3, alpha: 0.35).cgColor
        searchBar.layer?.borderWidth = 1

        let prompt = NSTextField(labelWithString: "SEARCH >")
        searchPromptLabel = prompt
        prompt.translatesAutoresizingMaskIntoConstraints = false
        prompt.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        prompt.textColor = NSColor(calibratedRed: 0.72, green: 0.92, blue: 0.38, alpha: 1)
        searchBar.addSubview(prompt)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        searchField.placeholderString = "Im Chatverlauf suchen"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchBar.addSubview(searchField)

        searchResultLabel.translatesAutoresizingMaskIntoConstraints = false
        searchResultLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        searchResultLabel.textColor = .secondaryLabelColor
        searchResultLabel.alignment = .right
        searchBar.addSubview(searchResultLabel)

        NSLayoutConstraint.activate([
            prompt.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: 14),
            prompt.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            prompt.widthAnchor.constraint(equalToConstant: 68),

            searchField.leadingAnchor.constraint(equalTo: prompt.trailingAnchor, constant: 4),
            searchField.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: searchResultLabel.leadingAnchor, constant: -8),

            searchResultLabel.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -16),
            searchResultLabel.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            searchResultLabel.widthAnchor.constraint(equalToConstant: 66)
        ])
    }

    private func makeHeader() -> NSView {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(calibratedRed: 0.075, green: 0.09, blue: 0.08, alpha: 1).cgColor

        let title = NSTextField(labelWithString: terminalAddress)
        titleLabel = title
        title.font = .monospacedSystemFont(ofSize: 14, weight: .bold)
        title.textColor = NSColor(calibratedRed: 0.72, green: 0.92, blue: 0.38, alpha: 1)

        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [title, statusLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        modelPopup.addItems(withTitles: ["Automatisch"])
        modelPopup.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        modelPopup.toolTip = "Modell für den nächsten neuen Chat"

        themePopup.addItems(withTitles: ["Dunkel", "Blau"])
        themePopup.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        themePopup.toolTip = "Farbschema"
        themePopup.target = self
        themePopup.action = #selector(themeChanged)
        let savedTheme = UserDefaults.standard.string(forKey: "ChatGPTTerminalTheme") ?? "Dunkel"
        themePopup.selectItem(withTitle: savedTheme)

        let newButton = button(symbol: "square.and.pencil", tip: "Neuer Chat", action: #selector(startNewChat))
        let searchButton = button(symbol: "magnifyingglass", tip: "Chatverlauf durchsuchen (⌘F)", action: #selector(toggleSearchBar))
        let sessionButton = button(symbol: "person.crop.circle", tip: "ChatGPT-Sitzung / Login anzeigen", action: #selector(showSession))
        let hideButton = button(symbol: "chevron.up", tip: "Fenster ausblenden", action: #selector(hideWindow))

        let controls = NSStackView(views: [labels, NSView(), modelPopup, themePopup, searchButton, newButton, sessionButton, hideButton])
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        header.addSubview(controls)

        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 74),
            controls.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            controls.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: 6)
        ])
        return header
    }

    private func makeComposer() -> NSView {
        let composer = NSView()
        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.wantsLayer = true
        composer.layer?.backgroundColor = NSColor(calibratedRed: 0.065, green: 0.075, blue: 0.07, alpha: 1).cgColor
        composer.layer?.borderColor = NSColor(calibratedWhite: 0.3, alpha: 0.45).cgColor
        composer.layer?.borderWidth = 1

        let prompt = NSTextField(labelWithString: "INPUT >")
        promptLabel = prompt
        prompt.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        prompt.textColor = NSColor(calibratedRed: 0.72, green: 0.92, blue: 0.38, alpha: 1)
        prompt.translatesAutoresizingMaskIntoConstraints = false
        composer.addSubview(prompt)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        inputView.drawsBackground = false
        inputView.textColor = NSColor(calibratedWhite: 0.93, alpha: 1)
        inputView.insertionPointColor = NSColor(calibratedRed: 0.72, green: 0.92, blue: 0.38, alpha: 1)
        inputView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        inputView.textContainerInset = NSSize(width: 0, height: 3)
        inputView.textContainer?.lineFragmentPadding = 0
        inputView.isRichText = false
        inputView.isAutomaticQuoteSubstitutionEnabled = false
        inputView.isAutomaticDashSubstitutionEnabled = false
        inputView.allowsUndo = true
        inputView.delegate = self
        inputView.registerForDraggedTypes([.png, .tiff, .pdf, .fileURL])
        scroll.documentView = inputView
        composer.addSubview(scroll)

        imageStrip.translatesAutoresizingMaskIntoConstraints = false
        imageStrip.orientation = .horizontal
        imageStrip.alignment = .centerY
        imageStrip.spacing = 6
        composer.addSubview(imageStrip)

        let screenshot = button(symbol: "viewfinder", tip: "Bildschirmbereich aufnehmen", action: #selector(captureScreenshot))
        let image = button(symbol: "photo", tip: "Bild oder PDF hinzufügen", action: #selector(chooseAttachments))
        let send = NSButton(title: "SEND ↵", target: self, action: #selector(sendMessage))
        send.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        send.bezelStyle = .rounded
        send.keyEquivalent = "\r"
        send.contentTintColor = NSColor(calibratedRed: 0.55, green: 0.82, blue: 0.25, alpha: 1)
        let copyLatest = button(symbol: "doc.on.doc", tip: "Neueste ChatGPT-Antwort kopieren (⌥⇧C)", action: #selector(copyLatestResponse))
        let jumpToBottom = button(symbol: "arrow.down.to.line", tip: "Zur neuesten Ausgabe springen (⌘↓)", action: #selector(scrollTranscriptToBottom))

        let actions = NSStackView(views: [screenshot, image, send, copyLatest, jumpToBottom])
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.orientation = .horizontal
        actions.spacing = 7
        composer.addSubview(actions)

        inputView.attachmentsDidChange = { [weak self] attachments in self?.renderAttachmentStrip(attachments) }
        inputView.historyNavigationRequested = { [weak self] direction in
            self?.navigateInputHistory(direction: direction)
        }
        inputView.sendRequested = { [weak self] in self?.sendMessage() }

        NSLayoutConstraint.activate([
            prompt.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 14),
            prompt.topAnchor.constraint(equalTo: composer.topAnchor, constant: 14),
            prompt.widthAnchor.constraint(equalToConstant: 66),

            scroll.leadingAnchor.constraint(equalTo: prompt.trailingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: composer.topAnchor, constant: 9),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 72),

            imageStrip.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            imageStrip.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 5),
            imageStrip.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -18),

            actions.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -24),
            actions.centerYAnchor.constraint(equalTo: imageStrip.centerYAnchor),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: imageStrip.trailingAnchor, constant: 8)
        ])
        return composer
    }

    private func button(symbol: String, tip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.toolTip = tip
        symbolButtons.append(button)
        return button
    }

    @objc private func themeChanged() {
        UserDefaults.standard.set(themePopup.titleOfSelectedItem ?? "Dunkel", forKey: "ChatGPTTerminalTheme")
        applyTheme()
    }

    private func applyTheme() {
        let blue = themePopup.titleOfSelectedItem == "Blau"
        let background = blue
            ? NSColor(calibratedRed: 0.025, green: 0.045, blue: 0.13, alpha: 1)
            : NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.06, alpha: 1)
        let header = blue
            ? NSColor(calibratedRed: 0.04, green: 0.065, blue: 0.17, alpha: 1)
            : NSColor(calibratedRed: 0.075, green: 0.09, blue: 0.08, alpha: 1)
        let composer = blue
            ? NSColor(calibratedRed: 0.0285, green: 0.05225, blue: 0.13775, alpha: 1)
            : NSColor(calibratedRed: 0.065, green: 0.075, blue: 0.07, alpha: 1)
        let accent = blue
            ? NSColor(calibratedRed: 0.55, green: 0.68, blue: 0.91, alpha: 1)
            : NSColor(calibratedRed: 0.72, green: 0.92, blue: 0.38, alpha: 1)
        panel.backgroundColor = background
        rootView?.layer?.backgroundColor = background.cgColor
        headerView?.layer?.backgroundColor = header.cgColor
        composerView?.layer?.backgroundColor = composer.cgColor
        searchBar.layer?.backgroundColor = (blue
            ? NSColor(calibratedRed: 0.027, green: 0.049, blue: 0.13, alpha: 1)
            : NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.065, alpha: 1)).cgColor
        searchBar.layer?.borderColor = (blue
            ? NSColor(calibratedRed: 0.30, green: 0.40, blue: 0.64, alpha: 0.36)
            : NSColor(calibratedWhite: 0.3, alpha: 0.35)).cgColor
        composerView?.layer?.borderColor = (blue
            ? NSColor(calibratedRed: 0.30, green: 0.40, blue: 0.64, alpha: 0.42)
            : NSColor(calibratedWhite: 0.3, alpha: 0.45)).cgColor
        titleLabel?.textColor = accent
        promptLabel?.textColor = accent
        searchPromptLabel?.textColor = accent
        inputView.insertionPointColor = accent
        symbolButtons.forEach { $0.contentTintColor = blue ? .white : nil }
        evaluateTerminal("terminal.setTheme(\(Self.jsString(blue ? "blue" : "dark")))")
    }

    private func configureSessionWindow() {
        sessionWindow.title = "ChatGPT-Sitzung — V3 Hintergrund"
        sessionWindow.isReleasedWhenClosed = false
        sessionWindow.delegate = self
        sessionWindow.setFrameAutosaveName("ChatGPTTerminalV3SessionFrame")
        sessionView.navigationDelegate = self
        sessionView.uiDelegate = self
        sessionWindow.center()
    }

    private func attachSessionToPanel() {
        guard sessionView.superview !== hiddenSessionHost else { return }
        sessionView.removeFromSuperview()
        // A real browser-sized viewport prevents ChatGPT from virtualizing long
        // replies just because the invisible host is only two pixels large.
        sessionView.translatesAutoresizingMaskIntoConstraints = true
        sessionView.autoresizingMask = []
        sessionView.frame = NSRect(x: 0, y: 0, width: 980, height: 760)
        hiddenSessionHost.addSubview(sessionView)
    }

    private func configureHotKeys() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard hotKeyID.signature == hotKeySignature else { return noErr }
            let controller = Unmanaged<TerminalController>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                switch hotKeyID.id {
                case HotKeyID.screenshot.rawValue: controller.captureScreenshot()
                case HotKeyID.copyLatest.rawValue: controller.copyLatestResponse()
                case HotKeyID.send.rawValue: controller.sendMessage()
                case HotKeyID.captureSelection.rawValue: controller.captureSelectedText()
                default: controller.toggleWindow()
                }
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)

        let windowID = EventHotKeyID(signature: hotKeySignature, id: HotKeyID.window.rawValue)
        let primaryWindow = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), windowID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if primaryWindow != noErr {
            windowShortcut = "⌥⌘ Leertaste"
            RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey | cmdKey), windowID, GetApplicationEventTarget(), 0, &hotKeyRef)
        }

        let screenshotID = EventHotKeyID(signature: hotKeySignature, id: HotKeyID.screenshot.rawValue)
        let primaryScreenshot = RegisterEventHotKey(UInt32(kVK_ANSI_4), UInt32(optionKey | shiftKey), screenshotID, GetApplicationEventTarget(), 0, &screenshotHotKeyRef)
        if primaryScreenshot != noErr {
            screenshotShortcut = "⌥⌘⇧4"
            RegisterEventHotKey(UInt32(kVK_ANSI_4), UInt32(optionKey | shiftKey | cmdKey), screenshotID, GetApplicationEventTarget(), 0, &screenshotHotKeyRef)
        }

        let copyID = EventHotKeyID(signature: hotKeySignature, id: HotKeyID.copyLatest.rawValue)
        RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(optionKey | shiftKey), copyID, GetApplicationEventTarget(), 0, &copyHotKeyRef)

        let sendID = EventHotKeyID(signature: hotKeySignature, id: HotKeyID.send.rawValue)
        RegisterEventHotKey(UInt32(kVK_Return), UInt32(cmdKey), sendID, GetApplicationEventTarget(), 0, &sendHotKeyRef)

        let captureSelectionID = EventHotKeyID(signature: hotKeySignature, id: HotKeyID.captureSelection.rawValue)
#if BETA_BUILD
        let captureSelectionModifiers = UInt32(controlKey | optionKey | shiftKey)
#else
        let captureSelectionModifiers = UInt32(cmdKey | shiftKey)
#endif
        captureSelectionHotKeyRegistrationStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_C),
            captureSelectionModifiers,
            captureSelectionID,
            GetApplicationEventTarget(),
            0,
            &captureSelectionHotKeyRef
        )
    }

    private func configureKeyboard() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            // Every local interaction invalidates delayed focus restoration.
            // Response updates must never reclaim focus after the user started
            // scrolling, selecting, copying, or typing somewhere else.
            self.userInteractionGeneration += 1
            guard event.type == .keyDown else {
                return event
            }
            if event.keyCode == UInt16(kVK_ANSI_F), event.modifierFlags.contains(.command), self.panel.isKeyWindow {
                self.toggleSearchBar()
                return nil
            }
            if self.isSearchVisible,
               let editor = self.searchField.currentEditor(),
               self.panel.firstResponder === editor,
               event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                if event.keyCode == UInt16(kVK_LeftArrow) {
                    self.stepTranscriptSearch(-1)
                    return nil
                }
                if event.keyCode == UInt16(kVK_RightArrow) {
                    self.stepTranscriptSearch(1)
                    return nil
                }
            }
            if event.keyCode == UInt16(kVK_ANSI_V), event.modifierFlags.contains(.command), self.panel.isKeyWindow {
                self.panel.makeFirstResponder(self.inputView)
                self.inputView.paste(nil)
                return nil
            }
            if event.keyCode == UInt16(kVK_DownArrow), event.modifierFlags.contains(.command), self.panel.isKeyWindow {
                self.scrollTranscriptToBottom()
                return nil
            }
            if event.keyCode == UInt16(kVK_Escape), self.panel.isVisible, self.panel.isKeyWindow {
                if self.isSearchVisible {
                    self.hideSearchBar()
                    return nil
                }
                self.panel.orderOut(nil)
                return nil
            }
            if event.keyCode == UInt16(kVK_Return), event.modifierFlags.contains(.command), self.panel.isKeyWindow {
                self.sendMessage()
                return nil
            }
            return event
        }
    }

    private func configureLockHandling() {
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenLocked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenUnlocked), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenLocked), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenUnlocked), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    private func loadTerminalDocument() {
        transcriptView.loadHTMLString(Self.terminalHTML, baseURL: URL(string: "https://cdn.jsdelivr.net/"))
    }

    private func loadChatGPT(newChat: Bool) {
        didFinishInitialLoad = false
        currentAssistantID = nil
        statusLabel.stringValue = newChat ? "Neuer Chat wird vorbereitet …" : "Sitzung wird geladen …"
        let home = URL(string: "https://chatgpt.com/")!
        let url: URL
        if newChat {
            if let current = UserDefaults.standard.string(forKey: "ChatGPTTerminalLastChatURL") {
                UserDefaults.standard.set(current, forKey: "ChatGPTTerminalPreviousChatURL")
            }
            UserDefaults.standard.removeObject(forKey: "ChatGPTTerminalLastChatURL")
            url = home
        } else if let saved = UserDefaults.standard.string(forKey: "ChatGPTTerminalLastChatURL"),
                  let savedURL = URL(string: saved),
                  savedURL.host?.hasSuffix("chatgpt.com") == true,
                  savedURL.path.contains("/c/") {
            url = savedURL
        } else {
            url = home
        }
        sessionView.load(URLRequest(url: url))
    }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(inputView)
    }

    func toggleWindow() { panel.isVisible ? panel.orderOut(nil) : showWindow() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === panel {
            panel.orderOut(nil)
            return false
        }
        if sender === sessionWindow {
            sessionWindow.orderOut(nil)
            sessionWindow.contentView = NSView(frame: sessionWindow.contentLayoutRect)
            attachSessionToPanel()
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(inputView)
            return false
        }
        return true
    }

    @objc private func hideWindow() { panel.orderOut(nil) }

    @objc private func scrollTranscriptToBottom() {
        evaluateTerminal("terminal.jumpToBottom()")
    }

    @objc private func toggleSearchBar() {
        if isSearchVisible {
            hideSearchBar()
            return
        }
        isSearchVisible = true
        searchBar.isHidden = false
        searchBarHeightConstraint?.constant = 40
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.makeFirstResponder(searchField)
        searchField.selectText(nil)
        if !searchField.stringValue.isEmpty {
            performTranscriptSearch(searchField.stringValue)
        }
    }

    private func hideSearchBar() {
        isSearchVisible = false
        searchBarHeightConstraint?.constant = 0
        searchBar.isHidden = true
        searchResultLabel.stringValue = ""
        evaluateTerminal("terminal.clearSearch()")
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.makeFirstResponder(inputView)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === searchField else { return }
        performTranscriptSearch(searchField.stringValue)
    }

    private func performTranscriptSearch(_ query: String) {
        transcriptView.evaluateJavaScript("terminal.search(\(Self.jsString(query)))") { [weak self] result, _ in
            self?.updateSearchResultLabel(from: result)
        }
    }

    private func stepTranscriptSearch(_ direction: Int) {
        transcriptView.evaluateJavaScript("terminal.searchStep(\(direction))") { [weak self] result, _ in
            self?.updateSearchResultLabel(from: result)
        }
    }

    private func updateSearchResultLabel(from result: Any?) {
        guard let payload = result as? [String: Any],
              let count = (payload["count"] as? NSNumber)?.intValue,
              count > 0 else {
            searchResultLabel.stringValue = searchField.stringValue.isEmpty ? "" : "0 Treffer"
            return
        }
        let index = (payload["index"] as? NSNumber)?.intValue ?? 0
        searchResultLabel.stringValue = "\(index + 1) / \(count)"
    }

    @objc private func captureSelectedText() {
        guard AXIsProcessTrusted() else {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            statusLabel.stringValue = "\(selectionShortcutLabel) benötigt Bedienungshilfen-Zugriff"
            return
        }

        selectionCaptureGeneration += 1
        let generation = selectionCaptureGeneration
        if let selectedText = accessibilitySelectedText() {
            acceptSelectedText(selectedText)
            return
        }

        let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let pasteboard = NSPasteboard.general
        let originalChangeCount = pasteboard.changeCount
        let originalItems: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false) else {
            statusLabel.stringValue = "Ausgewählter Text konnte nicht übernommen werden"
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        if let targetPID, targetPID != ProcessInfo.processInfo.processIdentifier {
            keyDown.postToPid(targetPID)
            keyUp.postToPid(targetPID)
        } else {
            keyDown.post(tap: .cgSessionEventTap)
            keyUp.post(tap: .cgSessionEventTap)
        }
        readCopiedSelection(
            generation: generation,
            originalChangeCount: originalChangeCount,
            originalItems: originalItems,
            remainingAttempts: 60
        )
    }

    private func accessibilitySelectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let focusedElement = unsafeBitCast(focusedValue, to: AXUIElement.self)

        var selectedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, &selectedValue) == .success,
           let selectedText = selectedValue as? String,
           !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return selectedText
        }

        var fullValue: CFTypeRef?
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &fullValue) == .success,
              let fullText = fullValue as? String,
              AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var selectedRange = CFRange()
        guard AXValueGetValue(unsafeBitCast(rangeValue, to: AXValue.self), .cfRange, &selectedRange),
              selectedRange.location >= 0,
              selectedRange.length > 0 else { return nil }
        let value = fullText as NSString
        guard selectedRange.location + selectedRange.length <= value.length else { return nil }
        return value.substring(with: NSRange(location: selectedRange.location, length: selectedRange.length))
    }

    private func readCopiedSelection(
        generation: Int,
        originalChangeCount: Int,
        originalItems: [[NSPasteboard.PasteboardType: Data]],
        remainingAttempts: Int
    ) {
        guard generation == selectionCaptureGeneration else { return }
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount != originalChangeCount {
            if let selectedText = textFromPasteboard(pasteboard),
               !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                restorePasteboard(originalItems)
                acceptSelectedText(selectedText)
                return
            }
            guard remainingAttempts > 0 else {
                restorePasteboard(originalItems)
                statusLabel.stringValue = "Keine Textauswahl gefunden"
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.readCopiedSelection(
                    generation: generation,
                    originalChangeCount: originalChangeCount,
                    originalItems: originalItems,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }
        guard remainingAttempts > 0 else {
            statusLabel.stringValue = "Keine Textauswahl gefunden"
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.readCopiedSelection(
                generation: generation,
                originalChangeCount: originalChangeCount,
                originalItems: originalItems,
                remainingAttempts: remainingAttempts - 1
            )
        }
    }

    private func textFromPasteboard(_ pasteboard: NSPasteboard) -> String? {
        if let text = pasteboard.string(forType: .string), !text.isEmpty { return text }
        let utf8Type = NSPasteboard.PasteboardType("public.utf8-plain-text")
        if let data = pasteboard.data(forType: utf8Type),
           let text = String(data: data, encoding: .utf8),
           !text.isEmpty { return text }
        if let data = pasteboard.data(forType: .html),
           let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
           ), !attributed.string.isEmpty { return attributed.string }
        if let data = pasteboard.data(forType: .rtf),
           let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
           ), !attributed.string.isEmpty { return attributed.string }
        return nil
    }

    private func acceptSelectedText(_ text: String) {
        appendToComposer(text)
        statusLabel.stringValue = "Auswahl in INPUT übernommen ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.statusLabel.stringValue == "Auswahl in INPUT übernommen ✓", !self.isSending else { return }
            self.statusLabel.stringValue = self.readyStatusText
        }
    }

    private func restorePasteboard(_ archivedItems: [[NSPasteboard.PasteboardType: Data]]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = archivedItems.map { archived -> NSPasteboardItem in
            let item = NSPasteboardItem()
            archived.forEach { type, data in item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    private func appendToComposer(_ text: String) {
        let existing = inputView.string
        if existing.isEmpty {
            inputView.string = text
        } else if existing.last?.isWhitespace == true {
            inputView.string += text
        } else {
            inputView.string += "\n" + text
        }
        let end = (inputView.string as NSString).length
        inputView.setSelectedRange(NSRange(location: end, length: 0))
        inputView.scrollRangeToVisible(inputView.selectedRange())
    }

#if BETA_BUILD
    func runExternalSelectionSelfTest() {
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let sentinel = "EXTERNAL_SELECTION_PROBE_91C4"
        inputView.string = ""
        panel.orderOut(nil)
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/private/tmp/ChatGPT Selection Probe")
        do {
            try probe.run()
        } catch {
            let report = "probe_started=false\nresult=FAIL\n"
            try? report.write(
                to: URL(fileURLWithPath: "/private/tmp/chatgpt-terminal-beta-external-selection-test.txt"),
                atomically: true,
                encoding: .utf8
            )
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            let probeApplication = NSRunningApplication(processIdentifier: probe.processIdentifier)
            probeApplication?.activate(options: [.activateAllWindows])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self else { return }
                let externalFocused = NSWorkspace.shared.frontmostApplication?.processIdentifier == probe.processIdentifier
                let terminalUnfocused = !NSApp.isActive && !self.panel.isKeyWindow
                let source = CGEventSource(stateID: .hidSystemState)
                let down = source.flatMap { CGEvent(keyboardEventSource: $0, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true) }
                let up = source.flatMap { CGEvent(keyboardEventSource: $0, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false) }
                down?.flags = [.maskControl, .maskAlternate, .maskShift]
                up?.flags = [.maskControl, .maskAlternate, .maskShift]
                down?.post(tap: .cgSessionEventTap)
                up?.post(tap: .cgSessionEventTap)

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self else { return }
                    let captured = self.inputView.string == sentinel
                    let focusStayedExternal = NSWorkspace.shared.frontmostApplication?.processIdentifier == probe.processIdentifier
                    let trusted = AXIsProcessTrusted()
                    let hotKeyPassed = self.captureSelectionHotKeyRegistrationStatus == noErr
                    let passed = trusted && hotKeyPassed && externalFocused && terminalUnfocused && captured && focusStayedExternal
                    let report = [
                        "trusted=\(trusted)",
                        "hotkey_registered=\(hotKeyPassed)",
                        "external_app_focused=\(externalFocused)",
                        "terminal_unfocused=\(terminalUnfocused)",
                        "text_captured=\(captured)",
                        "focus_stayed_external=\(focusStayedExternal)",
                        "result=\(passed ? "PASS" : "FAIL")"
                    ].joined(separator: "\n") + "\n"
                    try? report.write(
                        to: URL(fileURLWithPath: "/private/tmp/chatgpt-terminal-beta-external-selection-test.txt"),
                        atomically: true,
                        encoding: .utf8
                    )
                    probe.terminate()
                    previousApplication?.activate(options: [])
                }
            }
        }
    }

    func runSelectionSelfTest() {
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let sentinel = "TERMINAL_BETA_SELECTION_7F3A"
        showWindow()
        inputView.string = sentinel
        inputView.setSelectedRange(NSRange(location: 0, length: (sentinel as NSString).length))
        panel.makeFirstResponder(inputView)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let trusted = AXIsProcessTrusted()
            let accessibilityValue = self.accessibilitySelectedText()
            let accessibilityPassed = accessibilityValue == sentinel

            let pasteboard = NSPasteboard.general
            let oldCount = pasteboard.changeCount
            let oldItems: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
            }
            let source = CGEventSource(stateID: .hidSystemState)
            let down = source.flatMap { CGEvent(keyboardEventSource: $0, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true) }
            let up = source.flatMap { CGEvent(keyboardEventSource: $0, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false) }
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.postToPid(ProcessInfo.processInfo.processIdentifier)
            up?.postToPid(ProcessInfo.processInfo.processIdentifier)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                let copiedValue = self.textFromPasteboard(pasteboard)
                let clipboardPassed = pasteboard.changeCount != oldCount && copiedValue == sentinel
                self.restorePasteboard(oldItems)
                let hotKeyPassed = self.captureSelectionHotKeyRegistrationStatus == noErr
                self.inputView.string = sentinel
                self.inputView.setSelectedRange(NSRange(location: 0, length: (sentinel as NSString).length))
                self.panel.makeFirstResponder(self.inputView)
                let shortcutSource = CGEventSource(stateID: .hidSystemState)
                let shortcutDown = shortcutSource.flatMap { CGEvent(keyboardEventSource: $0, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true) }
                let shortcutUp = shortcutSource.flatMap { CGEvent(keyboardEventSource: $0, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false) }
                shortcutDown?.flags = [.maskControl, .maskAlternate, .maskShift]
                shortcutUp?.flags = [.maskControl, .maskAlternate, .maskShift]
                shortcutDown?.post(tap: .cgSessionEventTap)
                shortcutUp?.post(tap: .cgSessionEventTap)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                    guard let self else { return }
                    let endToEndPassed = self.inputView.string == sentinel + "\n" + sentinel
                    let passed = trusted && hotKeyPassed && accessibilityPassed && clipboardPassed && endToEndPassed
                    let report = [
                        "trusted=\(trusted)",
                        "hotkey_registered=\(hotKeyPassed)",
                        "accessibility_selection=\(accessibilityPassed)",
                        "targeted_copy=\(clipboardPassed)",
                        "end_to_end_hotkey=\(endToEndPassed)",
                        "result=\(passed ? "PASS" : "FAIL")"
                    ].joined(separator: "\n") + "\n"
                    try? report.write(
                        to: URL(fileURLWithPath: "/private/tmp/chatgpt-terminal-beta-selection-test.txt"),
                        atomically: true,
                        encoding: .utf8
                    )
                    self.inputView.string = ""
                    self.panel.orderOut(nil)
                    previousApplication?.activate(options: [])
                }
            }
        }
    }
#endif

    @objc func copyLatestResponse() {
        let pasteboard = NSPasteboard.general
        let previousChangeCount = pasteboard.changeCount
        sessionView.evaluateJavaScript(Self.copyLatestResponseScript) { [weak self] result, _ in
            guard let self,
                  let payload = result as? [String: Any],
                  payload["found"] as? Bool == true else {
                self?.statusLabel.stringValue = "Keine ChatGPT-Antwort zum Kopieren gefunden"
                return
            }
            guard payload["complete"] as? Bool == true else {
                self.statusLabel.stringValue = "Antwort noch nicht vollständig — Kopieren wartet"
                return
            }
            let markdown = payload["markdown"] as? String ?? ""
            let html = payload["html"] as? String ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                // ChatGPT's own button preserves its original Markdown/LaTeX
                // representation. If WebKit blocks that synthetic click, retain
                // reconstructed Markdown/LaTeX and rich HTML as a complete
                // native fallback sourced from the hidden ChatGPT response.
                if pasteboard.changeCount == previousChangeCount {
                    pasteboard.clearContents()
                    if !markdown.isEmpty { pasteboard.setString(markdown, forType: .string) }
                    if let data = html.data(using: .utf8), !data.isEmpty {
                        pasteboard.setData(data, forType: .html)
                    }
                }
                self.statusLabel.stringValue = "Neueste Antwort kopiert ✓"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                    guard let self, self.statusLabel.stringValue == "Neueste Antwort kopiert ✓", !self.isSending else { return }
                    self.statusLabel.stringValue = self.readyStatusText
                }
            }
        }
    }

    @objc private func showSession() {
        NSApp.activate(ignoringOtherApps: true)
        sessionView.removeFromSuperview()
        sessionView.translatesAutoresizingMaskIntoConstraints = true
        sessionView.autoresizingMask = [.width, .height]
        sessionView.frame = sessionWindow.contentLayoutRect
        sessionWindow.contentView = sessionView
        sessionWindow.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sessionView.evaluateJavaScript("window.__terminalResponseExtract?.(true)")
        }
    }

    @objc private func startNewChat() {
        submissionGeneration += 1
        isSending = false
        responseObserverInstalled = false
        thinkingPlaceholderShown = false
        resetExactLatexState()
        currentAssistantID = nil
        sessionView.evaluateJavaScript(Self.stopResponseObserverScript)
        detectedModel = "awaiting first response …"
        evaluateTerminalPreservingComposer("terminal.clear(); terminal.boot(\(Self.jsString(detectedModel)))")
        loadChatGPT(newChat: true)
        applySelectedModel(after: 2.0)
        focusComposerWhileNewChatLoads()
    }

    private func focusComposerWhileNewChatLoads() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        for delay in [0.0, 0.1, 0.35, 0.85, 1.5, 2.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.panel.isVisible, self.panel.isKeyWindow, !self.sessionWindow.isKeyWindow else { return }
                self.panel.makeFirstResponder(self.inputView)
            }
        }
    }

    private func switchToPreviousChat() {
        guard !isSending else {
            statusLabel.stringValue = "\\cd last ist während einer Antwort nicht verfügbar"
            return
        }
        statusLabel.stringValue = "\\cd last · vorherigen Chat suchen …"
        if let rawURL = UserDefaults.standard.string(forKey: "ChatGPTTerminalPreviousChatURL"),
           let url = URL(string: rawURL),
           url.host?.hasSuffix("chatgpt.com") == true,
           url.path.contains("/c/"),
           url.path != sessionView.url?.path {
            openPreviousChat(url)
            return
        }
        resolvePreviousChatFromSidebar(remainingAttempts: 3)
    }

    private func resolvePreviousChatFromSidebar(remainingAttempts: Int) {
        sessionView.evaluateJavaScript(Self.previousChatURLScript) { [weak self] result, _ in
            guard let self else { return }
            if let payload = result as? [String: Any],
               payload["retry"] as? Bool == true,
               remainingAttempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    self?.resolvePreviousChatFromSidebar(remainingAttempts: remainingAttempts - 1)
                }
                return
            }
            guard let payload = result as? [String: Any],
                  payload["ok"] as? Bool == true,
                  let rawURL = payload["url"] as? String,
                  let url = URL(string: rawURL),
                  url.host?.hasSuffix("chatgpt.com") == true else {
                self.statusLabel.stringValue = "\\cd last · kein vorheriger Chat gefunden"
                self.restoreComposerFocus()
                return
            }
            self.openPreviousChat(url)
        }
    }

    private func openPreviousChat(_ url: URL) {
        submissionGeneration += 1
        isSending = false
        responseObserverInstalled = false
        thinkingPlaceholderShown = false
        resetExactLatexState()
        currentAssistantID = nil
        sessionView.evaluateJavaScript(Self.stopResponseObserverScript)
        conversationReturnURL = sessionView.url
        conversationImportGeneration += 1
        pendingConversationImport = true
        statusLabel.stringValue = "\\cd last · Chat wird geladen …"
        sessionView.load(URLRequest(url: url))
    }

    private func importPendingConversation(generation: Int, remainingAttempts: Int = 30) {
        guard pendingConversationImport, conversationImportGeneration == generation else { return }
        sessionView.evaluateJavaScript(Self.conversationImportScript) { [weak self] result, _ in
            guard let self,
                  self.pendingConversationImport,
                  self.conversationImportGeneration == generation else { return }
            if let payload = result as? [String: Any],
               payload["ready"] as? Bool == true,
               let messages = payload["messages"] as? [[String: Any]],
               !messages.isEmpty {
                let importedModel = (payload["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if let importedModel { self.detectedModel = importedModel }
                var script = "terminal.clear(); terminal.boot(\(Self.jsString(self.detectedModel)));"
                for message in messages {
                    guard let role = message["role"] as? String,
                          let html = message["html"] as? String else { continue }
                    if role == "user" {
                        script += "terminal.addUser(\(Self.jsString(html)));"
                    } else if role == "assistant" {
                        let id = UUID().uuidString
                        script += "terminal.beginAssistant(\(Self.jsString(id)));terminal.updateAssistant(\(Self.jsString(id)),\(Self.jsString(html)),false);"
                    }
                }
                self.evaluateTerminal(script)
                self.pendingConversationImport = false
                self.conversationReturnURL = nil
                self.statusLabel.stringValue = self.readyStatusText
                self.persistSessionURL(self.sessionView.url?.absoluteString)
                self.restoreComposerFocus()
                return
            }

            guard remainingAttempts > 0 else {
                self.pendingConversationImport = false
                self.statusLabel.stringValue = "\\cd last · Chatverlauf konnte nicht geladen werden"
                if let returnURL = self.conversationReturnURL {
                    self.sessionView.load(URLRequest(url: returnURL))
                }
                self.conversationReturnURL = nil
                self.restoreComposerFocus()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.importPendingConversation(generation: generation, remainingAttempts: remainingAttempts - 1)
            }
        }
    }

    @objc private func chooseAttachments() {
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.allowedContentTypes = [.image, .pdf]
        picker.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let self else { return }
            let imported = picker.urls.compactMap { url -> PendingAttachment? in
                let type = UTType(filenameExtension: url.pathExtension)
                if type?.conforms(to: .pdf) == true, let data = try? Data(contentsOf: url) {
                    return pdfAttachment(from: data, fileName: url.lastPathComponent)
                }
                guard type?.conforms(to: .image) == true, let image = NSImage(contentsOf: url) else { return nil }
                return imageAttachment(from: image, fileName: url.deletingPathExtension().lastPathComponent + ".png")
            }
            self.inputView.setAttachments(self.inputView.pendingAttachments + imported)
        }
    }

    private func renderAttachmentStrip(_ attachments: [PendingAttachment]) {
        imageStrip.arrangedSubviews.forEach { view in imageStrip.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, item) in attachments.prefix(4).enumerated() {
            let preview = NSImageView(image: item.preview)
            preview.imageScaling = .scaleProportionallyUpOrDown
            preview.wantsLayer = true
            preview.layer?.cornerRadius = 5
            preview.layer?.masksToBounds = true
            preview.widthAnchor.constraint(equalToConstant: 42).isActive = true
            preview.heightAnchor.constraint(equalToConstant: 34).isActive = true

            let remove = NSButton(title: "×", target: self, action: #selector(removeAttachment(_:)))
            remove.tag = index
            remove.bezelStyle = .inline
            remove.toolTip = "\(item.fileName) entfernen"
            let holder = NSStackView(views: [preview, remove])
            holder.orientation = .horizontal
            holder.spacing = 0
            imageStrip.addArrangedSubview(holder)
        }
        if attachments.count > 4 {
            let more = NSTextField(labelWithString: "+\(attachments.count - 4)")
            more.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            imageStrip.addArrangedSubview(more)
        }
    }

    @objc private func removeAttachment(_ sender: NSButton) {
        var attachments = inputView.pendingAttachments
        guard attachments.indices.contains(sender.tag) else { return }
        attachments.remove(at: sender.tag)
        inputView.setAttachments(attachments)
    }

    @objc func captureScreenshot() {
        panel.orderOut(nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-c"]
        process.terminationHandler = { [weak self] task in
            guard task.terminationStatus == 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard let self else { return }
                self.showWindow()
                self.inputView.paste(nil)
            }
        }
        do { try process.run() }
        catch {
            showError("Screenshot konnte nicht gestartet werden", detail: error.localizedDescription)
            showWindow()
        }
    }

    @objc private func sendMessage() {
        let text = inputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = text.lowercased()
        if command == "\\stop" {
            rememberInput(text)
            inputView.clearAll()
            stopCurrentOperation()
            return
        }
        if command == "\\clear" {
            rememberInput(text)
            inputView.clearAll()
            evaluateTerminal("terminal.clear()")
            statusLabel.stringValue = readyStatusText
            restoreComposerFocus()
            return
        }
        if command == "\\new" {
            rememberInput(text)
            inputView.clearAll()
            startNewChat()
            return
        }
        if command == "\\cd last" {
            rememberInput(text)
            inputView.clearAll()
            switchToPreviousChat()
            return
        }
        guard !isSending else { return }
        let attachments = inputView.pendingAttachments
        guard !text.isEmpty || !attachments.isEmpty else { return }
        rememberInput(text)

        submissionGeneration += 1
        let generation = submissionGeneration
        currentAssistantID = nil
        responseObserverInstalled = false
        thinkingPlaceholderShown = false
        resetExactLatexState()
        exactLatexMode = !attachments.isEmpty && text == "$$"
        submissionHasAttachments = !attachments.isEmpty
        sessionView.evaluateJavaScript(Self.stopResponseObserverScript)
        isSending = true
        statusLabel.stringValue = "Übergabe an ChatGPT …"
        let userHTML = Self.userMessageHTML(text: text, attachmentCount: attachments.count)
        evaluateTerminal("terminal.addUser(\(Self.jsString(userHTML)))")
        if !attachments.isEmpty { updateTransferStatus("FILES > Dateien laden hoch …") }
        inputView.clearAll()

        ensurePromptAvailable { [weak self] available in
            guard let self else { return }
            guard self.submissionGeneration == generation, self.isSending else { return }
            guard available else {
                self.isSending = false
                self.statusLabel.stringValue = "Login oder Sitzung prüfen"
                self.showSession()
                self.showError("ChatGPT-Eingabe nicht gefunden", detail: "Melde dich im Sitzungsfenster an oder lade ChatGPT dort neu.")
                return
            }
            self.upload(attachments: attachments) { uploaded in
                guard self.submissionGeneration == generation, self.isSending else { return }
                guard uploaded else {
                    self.isSending = false
                    self.statusLabel.stringValue = "Dateiübergabe fehlgeschlagen — Sitzung öffnen"
                    self.showSession()
                    self.showError("Datei konnte nicht übergeben werden", detail: "ChatGPT hat seinen Datei-Upload nicht bereitgestellt. Im Sitzungsfenster kannst du die Datei weiterhin direkt einfügen.")
                    return
                }
                self.insertTextAndSubmit(text, generation: generation)
            }
        }
    }

    private func rememberInput(_ text: String) {
        guard !text.isEmpty else {
            historyIndex = nil
            historyDraft = ""
            return
        }
        inputHistory.append(text)
        if inputHistory.count > 100 {
            inputHistory.removeFirst(inputHistory.count - 100)
        }
        UserDefaults.standard.set(inputHistory, forKey: "ChatGPTTerminalInputHistory")
        historyIndex = nil
        historyDraft = ""
    }

    private func navigateInputHistory(direction: Int) {
        guard !inputHistory.isEmpty else { return }

        if direction < 0 {
            if let index = historyIndex {
                historyIndex = max(0, index - 1)
            } else {
                historyDraft = inputView.string
                historyIndex = inputHistory.count - 1
            }
        } else {
            guard let index = historyIndex else { return }
            if index < inputHistory.count - 1 {
                historyIndex = index + 1
            } else {
                historyIndex = nil
            }
        }

        let restoredText = historyIndex.map { inputHistory[$0] } ?? historyDraft
        inputView.string = restoredText
        inputView.setSelectedRange(NSRange(location: (restoredText as NSString).length, length: 0))
        inputView.scrollRangeToVisible(inputView.selectedRange())
    }

    private func stopCurrentOperation() {
        submissionGeneration += 1
        isSending = false
        responseObserverInstalled = false
        thinkingPlaceholderShown = false
        resetExactLatexState()
        currentAssistantID = nil
        pendingNativeUploadURLs = nil
        nativeUploadRequestID = nil
        let completion = nativeUploadCompletion
        nativeUploadCompletion = nil
        completion?(false)
        sessionView.evaluateJavaScript(Self.stopCurrentOperationScript)
        statusLabel.stringValue = "Vorgang abgebrochen — bereit"
        updateTransferStatus("STOP > Vorgang abgebrochen")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, !self.isSending else { return }
            self.updateTransferStatus(nil)
        }
        restoreComposerFocus()
    }

    private func ensurePromptAvailable(completion: @escaping (Bool) -> Void) {
        sessionView.evaluateJavaScript(Self.promptExistsScript) { result, _ in
            completion(result as? Bool ?? false)
        }
    }

    private func upload(attachments: [PendingAttachment], completion: @escaping (Bool) -> Void) {
        guard !attachments.isEmpty else { completion(true); return }
        if attachments.contains(where: { $0.mimeType == "application/pdf" }) {
            uploadUsingTrustedFilePaste(attachments: attachments, completion: completion)
            return
        }
        sessionView.evaluateJavaScript(Self.uploadAttachmentsScript(attachments: attachments)) { [weak self] result, _ in
            guard let self else { return }
            if result as? Bool == true {
                completion(true)
            } else {
                self.pasteAttachmentsAsFallback(attachments: attachments, index: 0, completion: completion)
            }
        }
    }

    private func createTemporaryFiles(for attachments: [PendingAttachment], requestID: UUID) throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatGPTTerminalUploads", isDirectory: true)
            .appendingPathComponent(requestID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try attachments.enumerated().map { index, attachment -> URL in
            let original = URL(fileURLWithPath: attachment.fileName).lastPathComponent
            let fileName = original.isEmpty ? "attachment-\(index + 1)" : original
            let url = directory.appendingPathComponent(fileName)
            try attachment.data.write(to: url, options: .atomic)
            return url
        }
    }

    private func uploadUsingTrustedFilePaste(attachments: [PendingAttachment], completion: @escaping (Bool) -> Void) {
        let requestID = UUID()
        let urls: [URL]
        do { urls = try createTemporaryFiles(for: attachments, requestID: requestID) }
        catch { completion(false); return }

        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects(urls.map { $0 as NSURL })
        sessionView.evaluateJavaScript(Self.focusPromptScript) { [weak self] focused, _ in
            guard let self, focused as? Bool == true else { completion(false); return }
            self.panel.makeFirstResponder(self.sessionView)
            let pasted = NSApp.sendAction(#selector(NSText.paste(_:)), to: self.sessionView, from: self)
            self.restoreComposerFocus()
            guard pasted else {
                self.uploadUsingNativeFilePanel(attachments: attachments, completion: completion)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.sessionView.evaluateJavaScript(Self.attachmentPresenceScript(fileNames: attachments.map(\.fileName))) { result, _ in
                    if result as? Bool == true {
                        completion(true)
                    } else {
                        self.uploadUsingNativeFilePanel(attachments: attachments, completion: completion)
                    }
                }
            }
        }
    }

    private func uploadUsingNativeFilePanel(attachments: [PendingAttachment], completion: @escaping (Bool) -> Void) {
        let requestID = UUID()
        do {
            let urls = try createTemporaryFiles(for: attachments, requestID: requestID)
            pendingNativeUploadURLs = urls
            nativeUploadCompletion = completion
            nativeUploadRequestID = requestID
        } catch {
            completion(false)
            return
        }

        sessionView.evaluateJavaScript(Self.openNativeUploadScript) { [weak self] result, _ in
            guard let self, self.nativeUploadRequestID == requestID else { return }
            if result as? String == "menu" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard self.nativeUploadRequestID == requestID else { return }
                    self.sessionView.evaluateJavaScript(Self.clickNativeUploadMenuItemScript)
                }
            } else if result as? String == "none" {
                self.finishNativeUpload(requestID: requestID, success: false)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self, self.nativeUploadRequestID == requestID else { return }
            self.finishNativeUpload(requestID: requestID, success: false)
        }
    }

    private func finishNativeUpload(requestID: UUID, success: Bool) {
        guard nativeUploadRequestID == requestID else { return }
        let completion = nativeUploadCompletion
        pendingNativeUploadURLs = nil
        nativeUploadCompletion = nil
        nativeUploadRequestID = nil
        completion?(success)
    }

    private func pasteAttachmentsAsFallback(attachments: [PendingAttachment], index: Int, completion: @escaping (Bool) -> Void) {
        guard attachments.indices.contains(index) else {
            panel.makeFirstResponder(inputView)
            completion(true)
            return
        }
        let item = attachments[index]
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(item.data, forType: item.pasteboardType)
        sessionView.evaluateJavaScript(Self.focusPromptScript) { [weak self] focused, _ in
            guard let self, focused as? Bool == true else { completion(false); return }
            self.panel.makeFirstResponder(self.sessionView)
            NSApp.sendAction(#selector(NSText.paste(_:)), to: self.sessionView, from: self)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                self.pasteAttachmentsAsFallback(attachments: attachments, index: index + 1, completion: completion)
            }
        }
    }

    private func insertTextAndSubmit(_ text: String, generation: Int) {
        let script = Self.prepareMessageScript(text: text)
        sessionView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self else { return }
            guard self.submissionGeneration == generation, self.isSending else { return }
            let prepared = result as? Bool ?? false
            if error != nil || !prepared {
                self.isSending = false
                self.statusLabel.stringValue = "Eingabe fehlgeschlagen — Sitzung öffnen"
                self.showSession()
                self.showError("Nachricht konnte nicht vorbereitet werden", detail: "Die ChatGPT-Oberfläche hat sich möglicherweise geändert. Im Sitzungsfenster kannst du die Eingabe prüfen.")
                return
            }
            self.statusLabel.stringValue = self.submissionHasAttachments ? "Dateien laden hoch …" : "Nachricht wird gesendet …"
            self.sessionView.evaluateJavaScript(Self.beginSubmissionMonitorScript) { [weak self] _, _ in
                guard let self, self.submissionGeneration == generation, self.isSending else { return }
                // Arm the observer before the send click. ChatGPT can create its
                // assistant turn synchronously while the click is being handled.
                self.installResponseObserver()
                self.attemptSubmit(remainingAttempts: 480, generation: generation)
            }
        }
    }

    private func attemptSubmit(remainingAttempts: Int, generation: Int) {
        guard submissionGeneration == generation, isSending else { return }
        sessionView.evaluateJavaScript(Self.submissionAttemptScript) { [weak self] result, _ in
            guard let self else { return }
            guard self.submissionGeneration == generation, self.isSending else { return }
            let state = (result as? [String: Any])?["state"] as? String ?? "waiting"
            switch state {
            case "uploading":
                self.statusLabel.stringValue = "Dateien laden hoch …"
                self.updateTransferStatus("FILES > Dateien laden hoch …")
            case "clicked":
                self.statusLabel.stringValue = "Absenden wird bestätigt …"
                if self.submissionHasAttachments { self.updateTransferStatus("SEND > Absenden wird bestätigt …") }
                self.installResponseObserver()
                self.restoreComposerFocus()
            case "accepted":
                self.statusLabel.stringValue = "Nachricht gesendet — warte auf ChatGPT …"
                if self.submissionHasAttachments { self.updateTransferStatus("SEND > Dateien hochgeladen · Nachricht gesendet ✓") }
                self.installResponseObserver()
                self.showThinkingPlaceholder()
                self.restoreComposerFocus()
                return
            case "response":
                self.statusLabel.stringValue = "ChatGPT antwortet …"
                self.updateTransferStatus(nil)
                self.installResponseObserver()
                self.showThinkingPlaceholder()
                self.restoreComposerFocus()
                return
            default:
                self.statusLabel.stringValue = self.submissionHasAttachments ? "Warte auf Datei-Upload und Sendebereitschaft …" : "Warte auf Sendebereitschaft …"
            }
            guard remainingAttempts > 0 else {
                self.isSending = false
                self.statusLabel.stringValue = "Senden fehlgeschlagen — Sitzung öffnen"
                self.updateTransferStatus("ERROR > Upload oder Absenden nicht bestätigt")
                self.showSession()
                self.showError("Nachricht konnte nicht gesendet werden", detail: "ChatGPT hat Upload oder Absenden innerhalb von zwei Minuten nicht bestätigt. Die vorbereitete Nachricht bleibt im Sitzungsfenster erhalten.")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.attemptSubmit(remainingAttempts: remainingAttempts - 1, generation: generation)
            }
        }
    }

    private func installResponseObserver() {
        guard !responseObserverInstalled else { return }
        responseObserverInstalled = true
        let responseID = UUID().uuidString
        currentAssistantID = responseID
        sessionView.evaluateJavaScript(Self.responseObserverScript(responseID: responseID))
    }

    private func showThinkingPlaceholder() {
        guard !thinkingPlaceholderShown, let id = currentAssistantID else { return }
        thinkingPlaceholderShown = true
        evaluateTerminalPreservingComposer("terminal.beginThinking(\(Self.jsString(id)))")
    }

    private func applySelectedModel(after delay: TimeInterval) {
        let choice = modelPopup.titleOfSelectedItem ?? "Automatisch"
        guard choice != "Automatisch" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.sessionView.evaluateJavaScript(Self.modelSelectionScript(choice: choice)) { result, _ in
                if !(result as? Bool ?? false) {
                    self.statusLabel.stringValue = "Modell bitte einmal in ‚Sitzung‘ wählen"
                }
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "terminalStateBridge",
           let payload = message.body as? [String: Any],
           let html = payload["html"] as? String,
           let model = payload["model"] as? String {
            persistenceQueue.async {
                UserDefaults.standard.set(html, forKey: "ChatGPTTerminalSavedTranscriptHTML")
                UserDefaults.standard.set(model, forKey: "ChatGPTTerminalSavedTranscriptModel")
            }
            return
        }
        guard message.name == "terminalBridge", let payload = message.body as? [String: Any], let type = payload["type"] as? String else { return }
        switch type {
        case "assistant":
            guard let id = payload["id"] as? String, let html = payload["html"] as? String else { return }
            let streaming = payload["streaming"] as? Bool ?? false
            let generating = payload["generating"] as? Bool ?? streaming
            let contentChanged = payload["changed"] as? Bool ?? true
            guard currentAssistantID == id else { return }
            if let model = payload["model"] as? String, !model.isEmpty {
                detectedModel = model
                evaluateTerminal("terminal.setModel(\(Self.jsString(model)))")
            } else if !streaming && detectedModel == "awaiting first response …" {
                detectedModel = "not exposed by ChatGPT"
                evaluateTerminal("terminal.setModel(\(Self.jsString(detectedModel)))")
            }
            if exactLatexMode {
                pendingExactLatexHTML = html
                if streaming {
                    if generating { isSending = true }
                    statusLabel.stringValue = generating ? "ChatGPT erzeugt LaTeX …" : "LaTeX wird final geprüft …"
                    if exactLatexFinalizationScheduled {
                        exactLatexFinalizationToken += 1
                        exactLatexFinalizationScheduled = false
                    }
                } else {
                    statusLabel.stringValue = "LaTeX wird final geprüft …"
                    scheduleExactLatexFinalization(id: id)
                }
                return
            }
            // Updating the transcript never needs to restore the composer focus.
            // In particular, a final state-only message during the grace period
            // must not touch the transcript, selection, scroll position, or focus.
            if contentChanged {
                evaluateTerminal("terminal.updateAssistant(\(Self.jsString(id)), \(Self.jsString(html)), \(streaming ? "true" : "false"))")
            }
            statusLabel.stringValue = (streaming || generating) ? "ChatGPT antwortet …" : readyStatusText
            if streaming { isSending = true }
            if !streaming {
                isSending = false
                responseObserverInstalled = false
                thinkingPlaceholderShown = false
                // Do not stop the Web observer here. ChatGPT can briefly look
                // final between tokens; its own grace period keeps watching and
                // forwards any continuation into the same terminal response.
                updateTransferStatus(nil)
            }
        case "ready":
            persistSessionURL(payload["url"] as? String)
            if !isSending {
                statusLabel.stringValue = readyStatusText
            }
            if terminalDocumentReady {
                evaluateTerminal("terminal.setModel(\(Self.jsString(detectedModel)))")
            }
        default:
            break
        }
    }

    private func evaluateTerminal(_ script: String) {
        transcriptView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func updateTransferStatus(_ text: String?) {
        let value = text.map(Self.jsString) ?? "null"
        evaluateTerminal("terminal.setTransferStatus(\(value))")
    }

    private func evaluateTerminalPreservingComposer(_ script: String) {
        let composerWasFocused = panel.firstResponder === inputView
        let interactionGeneration = userInteractionGeneration
        transcriptView.evaluateJavaScript(script) { [weak self] _, _ in
            guard let self,
                  composerWasFocused,
                  self.userInteractionGeneration == interactionGeneration else { return }
            self.restoreComposerFocus(ifUninterruptedSince: interactionGeneration)
        }
    }

    private func restoreComposerFocus(ifUninterruptedSince interactionGeneration: Int? = nil) {
        guard panel.isVisible, panel.isKeyWindow, !sessionWindow.isKeyWindow else { return }
        for delay in [0.0, 0.08, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.panel.isVisible,
                      self.panel.isKeyWindow,
                      !self.sessionWindow.isKeyWindow,
                      interactionGeneration == nil || self.userInteractionGeneration == interactionGeneration else { return }
                self.panel.makeFirstResponder(self.inputView)
            }
        }
    }

    private func resetExactLatexState() {
        exactLatexFinalizationToken += 1
        exactLatexMode = false
        exactLatexFinalizationScheduled = false
        pendingExactLatexHTML = nil
    }

    private func scheduleExactLatexFinalization(id: String) {
        guard !exactLatexFinalizationScheduled else { return }
        exactLatexFinalizationScheduled = true
        exactLatexFinalizationToken += 1
        let token = exactLatexFinalizationToken

        for delay in [0.3, 0.85] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.exactLatexMode,
                      self.exactLatexFinalizationToken == token,
                      self.currentAssistantID == id else { return }
                self.sessionView.evaluateJavaScript("window.__terminalResponseExtract?.(true)")
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self,
                  self.exactLatexMode,
                  self.exactLatexFinalizationToken == token,
                  self.currentAssistantID == id,
                  let html = self.pendingExactLatexHTML else { return }
            self.evaluateTerminal("terminal.updateAssistant(\(Self.jsString(id)), \(Self.jsString(html)), false)")
            self.isSending = false
            self.responseObserverInstalled = false
            self.thinkingPlaceholderShown = false
            self.exactLatexMode = false
            self.exactLatexFinalizationScheduled = false
            self.pendingExactLatexHTML = nil
            self.sessionView.evaluateJavaScript(Self.stopResponseObserverScript)
            self.updateTransferStatus(nil)
            self.statusLabel.stringValue = self.readyStatusText
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === transcriptView {
            terminalDocumentReady = true
            if let html = savedTranscriptHTML, !html.isEmpty {
                detectedModel = savedTranscriptModel ?? detectedModel
                evaluateTerminal("terminal.restore(\(Self.jsString(html)), \(Self.jsString(detectedModel))); terminal.enablePersistence()")
            } else {
                evaluateTerminal("terminal.setModel(\(Self.jsString(detectedModel))); terminal.enablePersistence()")
            }
            applyTheme()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in self?.restoreComposerFocus() }
            return
        }
        guard webView === sessionView else { return }
        persistSessionURL(webView.url?.absoluteString)
        didFinishInitialLoad = true
        statusLabel.stringValue = "Sitzung geladen — prüfe Login falls nötig"
        installReadinessProbe()
        if pendingConversationImport {
            let generation = conversationImportGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                self?.importPendingConversation(generation: generation)
            }
        }
        restoreComposerFocus()
    }

    private func installReadinessProbe() {
        sessionView.evaluateJavaScript(Self.readinessScript)
    }

    private func persistSessionURL(_ rawURL: String?) {
        guard let rawURL,
              let url = URL(string: rawURL),
              url.host?.hasSuffix("chatgpt.com") == true,
              url.path.contains("/c/") else { return }
        if let current = UserDefaults.standard.string(forKey: "ChatGPTTerminalLastChatURL"),
           current != url.absoluteString {
            UserDefaults.standard.set(current, forKey: "ChatGPTTerminalPreviousChatURL")
        }
        UserDefaults.standard.set(url.absoluteString, forKey: "ChatGPTTerminalLastChatURL")
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            sessionView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        if let urls = pendingNativeUploadURLs, let requestID = nativeUploadRequestID {
            completionHandler(urls)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.finishNativeUpload(requestID: requestID, success: true)
            }
            return
        }
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = parameters.allowsMultipleSelection
        picker.canChooseDirectories = parameters.allowsDirectories
        picker.canChooseFiles = true
        picker.begin { response in completionHandler(response == .OK ? picker.urls : nil) }
    }

    @objc private func screenLocked() {
        guard !lockHandled else { return }
        lockHandled = true
        panel.orderOut(nil)
        sessionWindow.orderOut(nil)
    }

    @objc private func screenUnlocked() { lockHandled = false }

    private func showError(_ title: String, detail: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = detail
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private static func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return "\(encoded).at(0)"
    }

    private static func userMessageHTML(text: String, attachmentCount: Int) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        let badge = attachmentCount > 0 ? "<span class='image-badge'>▣ \(attachmentCount) Datei\(attachmentCount == 1 ? "" : "en")</span>" : ""
        return escaped + (escaped.isEmpty || badge.isEmpty ? "" : "<br>") + badge
    }

    private static let promptExistsScript = """
    (() => !!(document.querySelector('#prompt-textarea') || document.querySelector('textarea') || document.querySelector('[contenteditable="true"]')))()
    """

    private static let focusPromptScript = """
    (() => {
      const p = document.querySelector('#prompt-textarea') || document.querySelector('textarea') || document.querySelector('[contenteditable="true"]');
      if (!p) return false; p.focus(); return true;
    })()
    """

    private static let previousChatURLScript = """
    (() => {
      const normalize = raw => {
        try {
          const url = new URL(raw, location.href);
          return url.pathname.replace(/\\/$/, '');
        } catch (_) { return ''; }
      };
      const currentPath = normalize(location.href);
      const candidates = [...document.querySelectorAll('a[href*="/c/"]')];
      const seen = new Set();
      const chats = candidates.filter(anchor => {
        const path = normalize(anchor.href);
        if (!path.includes('/c/') || seen.has(path)) return false;
        seen.add(path);
        return true;
      });
      let activeIndex = chats.findIndex(anchor => normalize(anchor.href) === currentPath);
      if (activeIndex < 0) {
        activeIndex = chats.findIndex(anchor => anchor.getAttribute('aria-current') === 'page' || anchor.dataset.active === 'true');
      }
      if (activeIndex >= 0 && activeIndex + 1 < chats.length) {
        const target = chats[activeIndex + 1];
        return {ok:true, url:new URL(target.href, location.href).href, title:(target.textContent || '').trim()};
      }
      if (activeIndex < 0) {
        const target = chats.find(anchor => normalize(anchor.href) !== currentPath);
        if (target) return {ok:true, url:new URL(target.href, location.href).href, title:(target.textContent || '').trim()};
      }
      const buttons = [...document.querySelectorAll('button')];
      const sidebarButton = buttons.find(button => {
        const description = ((button.getAttribute('aria-label') || '') + ' ' + (button.getAttribute('title') || '')).toLowerCase();
        return /open.*sidebar|sidebar.*open|seitenleiste.*öffnen|menü.*öffnen/.test(description);
      });
      if (sidebarButton) {
        sidebarButton.click();
        return {ok:false, retry:true};
      }
      return {ok:false, reason:'no-next-sidebar-chat'};
    })()
    """

    private static let conversationImportScript = """
    (() => {
      if (!location.pathname.includes('/c/')) return {ready:false};
      const nodes = [...document.querySelectorAll('[data-message-author-role="user"], [data-message-author-role="assistant"]')];
      if (!nodes.length) return {ready:false};
      const signature = nodes.length + ':' + ((nodes.at(-1)?.textContent || '').length);
      if (window.__terminalImportSignature !== signature) {
        window.__terminalImportSignature = signature;
        window.__terminalImportStableSince = Date.now();
        return {ready:false};
      }
      if (Date.now() - (window.__terminalImportStableSince || 0) < 1200) return {ready:false};
      const cleanHTML = (node, role) => {
        const content = role === 'assistant'
          ? (node.querySelector('.markdown, [class*="markdown"]') || node)
          : (node.querySelector('[class*="whitespace-pre-wrap"], [data-message-content]') || node);
        const clone = content.cloneNode(true);
        clone.querySelectorAll('script, style, button, [contenteditable="true"]').forEach(element => element.remove());
        clone.querySelectorAll('*').forEach(element => {
          [...element.attributes].forEach(attribute => {
            if (/^on/i.test(attribute.name) || ['data-state','contenteditable'].includes(attribute.name)) element.removeAttribute(attribute.name);
          });
        });
        return clone.innerHTML.trim();
      };
      const messages = nodes.map(node => {
        const role = node.getAttribute('data-message-author-role');
        return {role, html:cleanHTML(node, role)};
      }).filter(message => message.html);
      if (!messages.length) return {ready:false};
      const latestAssistant = [...nodes].reverse().find(node => node.getAttribute('data-message-author-role') === 'assistant');
      const modelNode = latestAssistant?.matches?.('[data-message-model-slug], [data-model-slug], [data-model]')
        ? latestAssistant
        : latestAssistant?.querySelector?.('[data-message-model-slug], [data-model-slug], [data-model]');
      let model = modelNode?.getAttribute('data-message-model-slug') || modelNode?.getAttribute('data-model-slug') || modelNode?.getAttribute('data-model') || '';
      model = model.replace(/^gpt-(\\d+)-(\\d+)(?=-|$)/i, 'gpt-$1.$2');
      return {ready:true, messages, model};
    })()
    """

    private static let copyLatestResponseScript = """
    (() => {
      const assistants = [...document.querySelectorAll('[data-message-author-role="assistant"]')];
      const node = assistants.at(-1) || [...document.querySelectorAll('article .markdown, article [class*="markdown"]')].at(-1);
      if (!node) return {found:false};
      const turn = node.closest('[data-testid^="conversation-turn-"]') || node.closest('article') || node.parentElement;
      const content = node.querySelector('.markdown, [class*="markdown"]') || node;
      const buttons = [...document.querySelectorAll('button')];
      const stopButton = document.querySelector('[data-testid="stop-button"], [data-testid*="stop" i]') || buttons.find(button => {
        const description = ((button.getAttribute('aria-label') || '') + ' ' +
          (button.getAttribute('title') || '') + ' ' +
          (button.getAttribute('data-testid') || '')).toLowerCase();
        return /stop|stopp|abbrechen|cancel|generierung.*beenden|antwort.*(?:stoppen|abbrechen|beenden)/.test(description);
      });
      const streamingMarker = turn?.querySelector?.('[aria-busy="true"], [data-streaming="true"], [class*="streaming" i]');
      const complete = !stopButton && !streamingMarker;

      const richClone = content.cloneNode(true);
      richClone.querySelectorAll('script, style, button').forEach(element => element.remove());
      richClone.querySelectorAll('*').forEach(element => {
        [...element.attributes].forEach(attribute => {
          if (/^on/i.test(attribute.name) || ['contenteditable','data-state'].includes(attribute.name)) element.removeAttribute(attribute.name);
        });
      });
      const source = richClone.cloneNode(true);
      const replaceMath = (element, display) => {
        const annotation = element.querySelector('annotation[encoding="application/x-tex"]');
        const latex = (annotation?.textContent || '').trim();
        if (!latex) return;
        const replacement = document.createElement('span');
        replacement.dataset.terminalLatex = `$$${latex}$$`;
        replacement.dataset.terminalDisplay = display ? 'true' : 'false';
        element.replaceWith(replacement);
      };
      [...source.querySelectorAll('.katex-display')].forEach(element => replaceMath(element, true));
      [...source.querySelectorAll('.katex')].forEach(element => replaceMath(element, false));

      const protectedBlocks = [];
      const protect = value => {
        const token = `TERMINALPROTECTED${protectedBlocks.length}TOKEN`;
        protectedBlocks.push(value);
        return token;
      };
      const children = element => [...element.childNodes].map(render).join('');
      const inline = element => children(element).trim();
      function render(current) {
        if (current.nodeType === Node.TEXT_NODE) return current.nodeValue || '';
        if (current.nodeType !== Node.ELEMENT_NODE) return '';
        if (current.dataset?.terminalLatex) return current.dataset.terminalLatex;
        const tag = current.tagName.toLowerCase();
        if (tag === 'br') return '\\n';
        if (tag === 'pre') {
          const code = current.querySelector('code') || current;
          const language = [...code.classList].map(name => name.match(/^language-(.+)$/)?.[1]).find(Boolean) || '';
          return '\\n\\n' + protect('```' + language + '\\n' + (code.textContent || '').replace(/\\n$/, '') + '\\n```') + '\\n\\n';
        }
        if (tag === 'code') return '`' + (current.textContent || '') + '`';
        if (tag === 'strong' || tag === 'b') return '**' + children(current) + '**';
        if (tag === 'em' || tag === 'i') return '*' + children(current) + '*';
        if (tag === 'del' || tag === 's') return '~~' + children(current) + '~~';
        if (tag === 'a') return '[' + children(current) + '](' + (current.getAttribute('href') || '') + ')';
        if (tag === 'img') return '![' + (current.getAttribute('alt') || '') + '](' + (current.getAttribute('src') || '') + ')';
        if (/^h[1-6]$/.test(tag)) return '#'.repeat(Number(tag[1])) + ' ' + inline(current) + '\\n\\n';
        if (tag === 'p') return children(current).trim() + '\\n\\n';
        if (tag === 'blockquote') {
          return children(current).trim().split('\\n').map(line => '> ' + line).join('\\n') + '\\n\\n';
        }
        if (tag === 'ul' || tag === 'ol') {
          const items = [...current.children].filter(child => child.tagName.toLowerCase() === 'li');
          return items.map((item,index) => {
            const copy = item.cloneNode(true);
            const nested = [...copy.children].filter(child => ['ul','ol'].includes(child.tagName.toLowerCase()));
            nested.forEach(child => child.remove());
            const prefix = tag === 'ol' ? `${index + 1}. ` : '- ';
            const main = render(copy).trim().replace(/\\n+/g, ' ');
            const below = nested.map(render).join('').trim();
            return prefix + main + (below ? '\\n' + below.split('\\n').map(line => '  ' + line).join('\\n') : '');
          }).join('\\n') + '\\n\\n';
        }
        if (tag === 'table') {
          const rows = [...current.querySelectorAll('tr')].map(row =>
            [...row.querySelectorAll(':scope > th, :scope > td')].map(cell => inline(cell).replace(/\\|/g, '\\|'))
          ).filter(row => row.length);
          if (!rows.length) return '';
          const width = Math.max(...rows.map(row => row.length));
          const normalized = rows.map(row => [...row, ...Array(width - row.length).fill('')]);
          const header = normalized[0];
          return '| ' + header.join(' | ') + ' |\\n| ' + header.map(() => '---').join(' | ') + ' |\\n' +
            normalized.slice(1).map(row => '| ' + row.join(' | ') + ' |').join('\\n') + '\\n\\n';
        }
        if (tag === 'hr') return '---\\n\\n';
        return children(current);
      }
      let markdown = render(source)
        .replace(/[ \\t]+\\n/g, '\\n')
        .replace(/\\n{3,}/g, '\\n\\n')
        .trim();
      protectedBlocks.forEach((value,index) => {
        markdown = markdown.replace(`TERMINALPROTECTED${index}TOKEN`, value);
      });

      const turnButtons = [...(turn?.querySelectorAll('button') || [])];
      const copyButton = turnButtons.find(button => {
        const description = ((button.getAttribute('aria-label') || '') + ' ' +
          (button.getAttribute('title') || '') + ' ' +
          (button.getAttribute('data-testid') || '')).toLowerCase();
        return /copy|kopieren/.test(description);
      });
      if (complete) copyButton?.click();
      return {found:true, complete, clicked:complete && !!copyButton, markdown, html:richClone.innerHTML};
    })()
    """

    private static func attachmentPresenceScript(fileNames: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: fileNames),
              let json = String(data: data, encoding: .utf8) else { return "false" }
        return """
        (() => {
          const names = \(json).map(name => name.toLowerCase());
          const prompt = document.querySelector('#prompt-textarea') || document.querySelector('textarea') || document.querySelector('[contenteditable="true"]');
          const scope = prompt?.closest('form')?.parentElement || prompt?.parentElement?.parentElement || document;
          const text = (scope.innerText || scope.textContent || '').toLowerCase();
          if (names.some(name => text.includes(name))) return true;
          return scope.querySelectorAll?.('[data-testid*="attachment"], [class*="attachment"], [aria-label$=".pdf" i]').length > 0;
        })()
        """
    }

    private static func uploadAttachmentsScript(attachments: [PendingAttachment]) -> String {
        let payload = attachments.map { attachment in
            [
                "name": attachment.fileName,
                "type": attachment.mimeType,
                "base64": attachment.data.base64EncodedString()
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return "false" }
        return """
        (() => {
          const files = \(json);
          const inputs = [...document.querySelectorAll('input[type="file"]')];
          const input = inputs.find(i => /image|pdf|png|jpe?g|webp|heic/i.test(i.accept || '')) || inputs.at(-1);
          if (!input) return false;
          const transfer = new DataTransfer();
          for (const file of files) {
            const raw = atob(file.base64);
            const bytes = new Uint8Array(raw.length);
            for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
            transfer.items.add(new File([bytes], file.name, {type:file.type, lastModified:Date.now()}));
          }
          try {
            input.files = transfer.files;
            input.dispatchEvent(new Event('input', {bubbles:true}));
            input.dispatchEvent(new Event('change', {bubbles:true}));
            return true;
          } catch (_) {
            return false;
          }
        })()
        """
    }

    private static let openNativeUploadScript = """
    (() => {
      const inputs = [...document.querySelectorAll('input[type="file"]')];
      const documentInput = inputs.find(i => {
        const accept = (i.accept || '').toLowerCase();
        return accept.includes('pdf') || accept.includes('application/') || (!accept.includes('image') && accept !== '');
      });
      if (documentInput) { documentInput.click(); return 'input'; }
      const buttons = [...document.querySelectorAll('button')];
      const add = document.querySelector('[data-testid="composer-plus-btn"], #composer-plus-btn') || buttons.find(b => /dateien und mehr|datei hinzufügen|add files|attach files|attachments|anhängen/i.test(
        (b.getAttribute('aria-label') || '') + ' ' + (b.innerText || '') + ' ' + (b.getAttribute('data-testid') || '')
      ));
      if (!add) return 'none';
      add.click();
      return 'menu';
    })()
    """

    private static let clickNativeUploadMenuItemScript = """
    (() => {
      const visible = e => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
      const inputs = [...document.querySelectorAll('input[type="file"]')];
      const documentInput = inputs.find(i => {
        const accept = (i.accept || '').toLowerCase();
        return accept.includes('pdf') || accept.includes('application/') || (!accept.includes('image') && accept !== '');
      });
      if (documentInput) { documentInput.click(); return true; }
      const options = [...document.querySelectorAll('[role="menuitem"], [role="option"], [data-radix-menu-content] button')].filter(visible);
      const item = options.find(e => {
        const text = ((e.innerText || '') + ' ' + (e.getAttribute('aria-label') || '')).toLowerCase();
        return /datei|file|computer|upload/.test(text);
      });
      if (!item) return false;
      item.click();
      return true;
    })()
    """

    private static func prepareMessageScript(text: String) -> String {
        """
        (() => {
          const text = \(jsString(text));
          const p = document.querySelector('#prompt-textarea') || document.querySelector('textarea') || document.querySelector('[contenteditable="true"]');
          if (!p) return false;
          p.focus();
          if (text) {
            if (p.tagName === 'TEXTAREA') {
              const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set;
              setter ? setter.call(p, text) : (p.value = text);
              p.dispatchEvent(new Event('input', {bubbles:true}));
            } else {
              document.execCommand('selectAll', false, null);
              document.execCommand('insertText', false, text);
              p.dispatchEvent(new InputEvent('input', {bubbles:true, inputType:'insertText', data:text}));
            }
          }
          return true;
        })()
        """
    }

    private static let beginSubmissionMonitorScript = """
    (() => {
      window.__terminalSubmission = {
        baselineUsers: document.querySelectorAll('[data-message-author-role="user"]').length,
        baselineAssistants: document.querySelectorAll('[data-message-author-role="assistant"]').length,
        clicked: false,
        lastClick: 0
      };
      return true;
    })()
    """

    private static let submissionAttemptScript = """
    (() => {
      const state = window.__terminalSubmission;
      if (!state) return {state:'waiting'};
      const userCount = document.querySelectorAll('[data-message-author-role="user"]').length;
      const assistantCount = document.querySelectorAll('[data-message-author-role="assistant"]').length;
      if (assistantCount > state.baselineAssistants) return {state:'response'};
      if (userCount > state.baselineUsers) return {state:'accepted'};

      const prompt = document.querySelector('#prompt-textarea') || document.querySelector('textarea') || document.querySelector('[contenteditable="true"]');
      const scope = prompt?.closest('form')?.parentElement || prompt?.parentElement?.parentElement || document;
      const scopeText = (scope.innerText || scope.textContent || '').toLowerCase();
      const progress = scope.querySelector?.('[role="progressbar"], [aria-busy="true"], progress');
      const uploading = !!progress || /uploading|wird hochgeladen|lädt hoch|datei wird verarbeitet|processing file/.test(scopeText);
      if (uploading) return {state:'uploading'};

      const buttons = [...document.querySelectorAll('button')];
      const send = document.querySelector('[data-testid="send-button"]') ||
        buttons.find(b => /send|senden|submit/i.test((b.getAttribute('aria-label') || '') + ' ' + (b.getAttribute('data-testid') || '')));
      const promptText = prompt ? ((prompt.value || prompt.innerText || prompt.textContent || '').trim()) : '';
      if (state.clicked && !promptText && (!send || send.disabled)) return {state:'accepted'};
      if (!send || send.disabled || send.getAttribute('aria-disabled') === 'true') return {state:'waiting'};

      const now = Date.now();
      if (now - state.lastClick < 1100) return {state:'waiting'};
      send.click();
      state.clicked = true;
      state.lastClick = now;
      return {state:'clicked'};
    })()
    """

    private static let readinessScript = """
    (() => {
      if (window.__terminalReadyProbe) clearInterval(window.__terminalReadyProbe);
      window.__terminalReadyProbe = setInterval(() => {
        const p = document.querySelector('#prompt-textarea') || document.querySelector('textarea') || document.querySelector('[contenteditable="true"]');
        if (p) window.webkit.messageHandlers.terminalBridge.postMessage({type:'ready', url:location.href});
      }, 1500);
      return true;
    })()
    """

    private static func responseObserverScript(responseID: String) -> String {
    """
    (() => {
      const responseID = \(jsString(responseID));
      if (window.__terminalResponseObserver) window.__terminalResponseObserver.disconnect();
      const initialRoleNodes = [...document.querySelectorAll('[data-message-author-role="assistant"]')];
      const initialMarkdownNodes = [...document.querySelectorAll('article .markdown, article [class*="markdown"]')];
      const initialNodes = new Set([...initialRoleNodes, ...initialMarkdownNodes]);
      let lastHTML = '';
      let stableTicks = 0;
      let lastChangeAt = Date.now();
      let lastStreaming = true;
      let finalSentAt = 0;
      let observedTurn = null;
      const extract = (force = false) => {
        const roleNodes = [...document.querySelectorAll('[data-message-author-role="assistant"]')];
        const markdownNodes = [...document.querySelectorAll('article .markdown, article [class*="markdown"]')];
        const newRoleNodes = roleNodes.filter(node => !initialNodes.has(node));
        const newMarkdownNodes = markdownNodes.filter(node => !initialNodes.has(node));
        const node = newRoleNodes.at(-1) || newMarkdownNodes.at(-1);
        if (!node) return;
        const buttons = [...document.querySelectorAll('button')];
        const stop = document.querySelector('[data-testid="stop-button"], [data-testid*="stop" i], button[aria-label*="Stop" i], button[aria-label*="Stopp" i]') || buttons.find(button => {
          const label = ((button.getAttribute('aria-label') || '') + ' ' + (button.getAttribute('title') || '') + ' ' + (button.getAttribute('data-testid') || '')).toLowerCase();
          return /stop|stopp|abbrechen|cancel|generierung.*beenden|antwort.*(?:stoppen|abbrechen|beenden)/.test(label);
        });
        const content = node.querySelector('.markdown, [class*="markdown"]') || node;
        const clone = content.cloneNode(true);
        clone.querySelectorAll('script, style, button').forEach(n => n.remove());
        clone.querySelectorAll('*').forEach(n => {
          [...n.attributes].forEach(a => {
            if (/^on/i.test(a.name) || ['contenteditable','data-state'].includes(a.name)) n.removeAttribute(a.name);
          });
        });
        const html = clone.innerHTML;
        if (!html.trim()) return;
        const turn = node.closest('article') || node.closest('[data-testid^="conversation-turn-"]') || node;
        observedTurn = turn;
        const streamingMarker = turn.querySelector?.('[aria-busy="true"], [data-streaming="true"], [class*="streaming" i]');
        const activelyGenerating = !!stop || !!streamingMarker;
        const modelElement = turn.matches?.('[data-message-model-slug], [data-model-slug], [data-model]') ? turn :
          turn.querySelector?.('[data-message-model-slug], [data-model-slug], [data-model]');
        let model = modelElement?.getAttribute('data-message-model-slug') ||
          modelElement?.getAttribute('data-model-slug') || modelElement?.getAttribute('data-model') || '';
        if (!model) {
          const markup = turn.outerHTML || '';
          const match = markup.match(/data-(?:message-)?model(?:-slug)?=["']([^"']+)["']/i);
          if (match) model = match[1];
        }
        model = model.replace(/^gpt-(\\d+)-(\\d+)(?=-|$)/i, 'gpt-$1.$2');
        const changed = html !== lastHTML;
        if (changed) {
          stableTicks = 0;
          lastChangeAt = Date.now();
          finalSentAt = 0;
        } else {
          stableTicks += 1;
        }
        lastHTML = html;

        // Copy/rating controls are ChatGPT's most reliable indication that a
        // turn has completed. If their markup changes, a conservative quiet
        // period prevents pauses during reasoning from truncating the answer.
        const actionButtons = [...(turn.querySelectorAll?.('button') || [])];
        const hasCompletionControls = !!turn.querySelector?.('[data-testid*="copy" i], [data-testid*="feedback" i]') || actionButtons.some(button => {
          const label = ((button.getAttribute('aria-label') || '') + ' ' + (button.getAttribute('data-testid') || '')).toLowerCase();
          return /copy|kopieren|good response|bad response|gute antwort|schlechte antwort/.test(label);
        });
        const quietFor = Date.now() - lastChangeAt;
        const streaming = activelyGenerating || (hasCompletionControls ? quietFor < 1800 : quietFor < 12000);
        if (force || changed || streaming !== lastStreaming || (!streaming && !finalSentAt)) {
          window.webkit.messageHandlers.terminalBridge.postMessage({type:'assistant', id:responseID, html, streaming, generating:activelyGenerating, changed, model});
        }
        lastStreaming = streaming;
        if (!streaming && !finalSentAt) finalSentAt = Date.now();

        // Stop only the periodic polling after an apparent end. The lightweight
        // MutationObserver remains alive until the next prompt, so even a very
        // long thinking pause cannot truncate a later continuation.
        if (!streaming && finalSentAt && Date.now() - finalSentAt > 3000 && window.__terminalResponseTimer) {
          clearInterval(window.__terminalResponseTimer);
          window.__terminalResponseTimer = null;
        }
      };
      const scheduleMutationExtract = mutations => {
        // The hidden ChatGPT page changes constantly. Once the active answer
        // is known, ignore unrelated mutations so the grace period stays
        // passive and cannot pressure the visible terminal UI.
        if (observedTurn && observedTurn.isConnected) {
          const relevant = mutations.some(mutation =>
            observedTurn.contains(mutation.target) ||
            [...mutation.addedNodes].some(node => node === observedTurn || (node.nodeType === 1 && node.contains?.(observedTurn)))
          );
          if (!relevant) return;
        }
        if (window.__terminalResponseMutationTimer) return;
        window.__terminalResponseMutationTimer = setTimeout(() => {
          window.__terminalResponseMutationTimer = null;
          extract(false);
        }, 250);
      };
      window.__terminalResponseObserver = new MutationObserver(scheduleMutationExtract);
      window.__terminalResponseExtract = extract;
      window.__terminalResponseObserver.observe(document.body, {subtree:true, childList:true, characterData:true});
      if (window.__terminalResponseTimer) clearInterval(window.__terminalResponseTimer);
      window.__terminalResponseTimer = setInterval(extract, 700);
      extract();
      return true;
    })()
    """
    }

    private static let stopResponseObserverScript = """
    (() => {
      window.__terminalResponseObserver?.disconnect();
      window.__terminalResponseObserver = null;
      window.__terminalResponseExtract = null;
      if (window.__terminalResponseMutationTimer) clearTimeout(window.__terminalResponseMutationTimer);
      window.__terminalResponseMutationTimer = null;
      if (window.__terminalResponseTimer) clearInterval(window.__terminalResponseTimer);
      window.__terminalResponseTimer = null;
      return true;
    })()
    """

    private static let stopCurrentOperationScript = """
    (() => {
      window.__terminalSubmission = null;
      window.__terminalResponseObserver?.disconnect();
      window.__terminalResponseObserver = null;
      window.__terminalResponseExtract = null;
      if (window.__terminalResponseMutationTimer) clearTimeout(window.__terminalResponseMutationTimer);
      window.__terminalResponseMutationTimer = null;
      if (window.__terminalResponseTimer) clearInterval(window.__terminalResponseTimer);
      window.__terminalResponseTimer = null;

      const buttons = [...document.querySelectorAll('button')];
      const stop = document.querySelector('[data-testid="stop-button"]') || buttons.find(b =>
        /stop|stopp|generierung beenden/i.test((b.getAttribute('aria-label') || '') + ' ' + (b.getAttribute('data-testid') || ''))
      );
      stop?.click();

      const prompt = document.querySelector('#prompt-textarea') || document.querySelector('textarea') || document.querySelector('[contenteditable="true"]');
      const scope = prompt?.closest('form')?.parentElement || prompt?.parentElement?.parentElement;
      [...(scope?.querySelectorAll('button') || [])].forEach(button => {
        const label = ((button.getAttribute('aria-label') || '') + ' ' + (button.getAttribute('data-testid') || '')).toLowerCase();
        if (/(remove|entfernen).*(file|datei|attachment|anhang|upload)|(file|datei|attachment|anhang|upload).*(remove|entfernen)/.test(label)) button.click();
      });

      if (prompt) {
        if (prompt.tagName === 'TEXTAREA') prompt.value = '';
        else prompt.textContent = '';
        prompt.dispatchEvent(new Event('input', {bubbles:true}));
      }
      return true;
    })()
    """

    private static func modelSelectionScript(choice: String) -> String {
        """
        (() => {
          const wanted = \(jsString(choice)).toLowerCase();
          const visible = e => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
          const buttons = [...document.querySelectorAll('button')].filter(visible);
          const trigger = buttons.find(b => /model|modell|chatgpt|auto|instant|thinking|pro/i.test((b.innerText || '') + ' ' + (b.getAttribute('aria-label') || '')));
          if (!trigger) return false;
          trigger.click();
          setTimeout(() => {
            const options = [...document.querySelectorAll('[role="menuitem"], [role="option"], button')].filter(visible);
            const option = options.find(e => (e.innerText || '').toLowerCase().includes(wanted));
            if (option) option.click();
          }, 500);
          return true;
        })()
        """
    }

    private static let terminalHTML = """
    <!doctype html><html><head><meta charset="utf-8">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
    <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
    <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"></script>
    <style>
      :root { color-scheme: dark; }
      * { box-sizing: border-box; }
      html, body { margin:0; min-height:100%; background:#0e110f; color:#e8eadf; overflow-anchor:none; }
      body { padding:18px 20px 34px; font:14px/1.55 ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
      #empty { color:#758078; padding-top:4px; }
      .message { margin:0 0 22px; }
      .label { color:#b8eb60; font-weight:700; margin-bottom:5px; }
      .user { display:grid; grid-template-columns:max-content minmax(0,1fr); column-gap:10px; align-items:baseline; }
      .user .label { margin:0; }
      .user .body { min-width:0; }
      .assistant .label { color:#69d5d0; }
      .body { overflow-wrap:anywhere; }
      .assistant .body { font-family:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; font-size:14px; line-height:1.55; }
      .assistant .body :not(.katex):not(.katex *) { font-family:inherit; }
      .assistant .body code, .assistant .body pre { font-family:inherit; }
      p { margin:.45em 0 .85em; } h1,h2,h3 { color:#f0f3e8; margin:1.15em 0 .45em; line-height:1.25; }
      h1 { font-size:1.38em; } h2 { font-size:1.22em; } h3 { font-size:1.08em; }
      pre { background:#171c19; border:1px solid #303a33; border-radius:7px; padding:12px; overflow:auto; white-space:pre; }
      code { color:#eadf9b; background:#171c19; padding:.12em .3em; border-radius:4px; }
      pre code { color:#e8eadf; background:transparent; padding:0; }
      blockquote { margin:.8em 0; border-left:3px solid #7a9d45; padding:.2em 0 .2em 12px; color:#c5ccbf; }
      table { border-collapse:collapse; width:100%; margin:.8em 0; } th,td { border:1px solid #39423b; padding:7px 9px; text-align:left; }
      a { color:#79c8ff; } img { max-width:100%; border-radius:7px; }
      .image-badge { display:inline-block; color:#d2e99d; border:1px solid #627a3d; border-radius:5px; padding:2px 7px; margin-top:4px; }
      .transfer-status { color:#d9bd67; margin:-12px 0 20px; }
      .boot { margin:0 0 24px; color:#aeb7ad; }
      .boot-command { color:#e8eadf; }
      .boot-prompt { color:#b8eb60; font-weight:700; }
      .boot-step { color:#758078; }
      .boot-ok { color:#69d5d0; }
      .boot-model { color:#eadf9b; font-weight:700; }
      .katex-display { overflow-x:auto; overflow-y:hidden; padding:.35em 0; }
      mark.terminal-search-hit { color:inherit; background:#7c6d2b; border-radius:3px; padding:0 .08em; }
      mark.terminal-search-hit.current { background:#c4a83c; color:#11140f; outline:1px solid #eadf9b; }
      html[data-theme="blue"], html[data-theme="blue"] body { background:#0e110f; color:#e7ebf4; }
      html[data-theme="blue"] #empty, html[data-theme="blue"] .boot-step { color:#7582a3; }
      html[data-theme="blue"] .label, html[data-theme="blue"] .boot-prompt { color:#93afe5; }
      html[data-theme="blue"] .assistant .label, html[data-theme="blue"] .boot-ok { color:#8abfd2; }
      html[data-theme="blue"] h1, html[data-theme="blue"] h2, html[data-theme="blue"] h3 { color:#f0f3fa; }
      html[data-theme="blue"] pre, html[data-theme="blue"] code { background:#0b1838; }
      html[data-theme="blue"] pre { border-color:#25365f; }
      html[data-theme="blue"] pre code { background:transparent; color:#e7ebf4; }
      html[data-theme="blue"] code, html[data-theme="blue"] .boot-model { color:#b7c8e8; }
      html[data-theme="blue"] blockquote { border-left-color:#5877b7; color:#c4ccdd; }
      html[data-theme="blue"] th, html[data-theme="blue"] td { border-color:#2b3b65; }
      html[data-theme="blue"] a { color:#80b8e8; }
      html[data-theme="blue"] .image-badge { color:#c0cee8; border-color:#4b6191; }
      html[data-theme="blue"] .transfer-status { color:#b7c5df; }
      html[data-theme="blue"] mark.terminal-search-hit { background:#334b82; }
      html[data-theme="blue"] mark.terminal-search-hit.current { background:#86a8ea; color:#07102d; outline-color:#c9d8f5; }
    </style></head><body><div id="empty"></div><div id="log"></div>
    <script>
      const log = document.getElementById('log'), empty = document.getElementById('empty');
      let persistenceEnabled = false, snapshotTimer = null;
      const queueSnapshot = () => {
        if (!persistenceEnabled) return;
        if (snapshotTimer) clearTimeout(snapshotTimer);
        snapshotTimer = setTimeout(() => {
          snapshotTimer = null;
          const snapshot=log.cloneNode(true);
          snapshot.querySelectorAll('mark.terminal-search-hit').forEach(mark=>mark.replaceWith(document.createTextNode(mark.textContent || '')));
          snapshot.normalize();
          window.webkit.messageHandlers.terminalStateBridge.postMessage({
            html:snapshot.innerHTML,
            model:window.terminal?.currentModel || 'detecting …'
          });
        },350);
      };
      const nearBottom = () => document.documentElement.scrollHeight - window.innerHeight - window.scrollY <= 24;
      let followTail = true;
      window.addEventListener('scroll', () => { followTail = nearBottom(); }, {passive:true});
      const scrollBottom = (force=false) => {
        if (!force && !followTail) return;
        followTail = true;
        window.scrollTo({top:document.documentElement.scrollHeight, behavior:'auto'});
      };
      const preserveReadingPosition = update => {
        const wasFollowing = followTail;
        const previousY = window.scrollY;
        update();
        if (wasFollowing) scrollBottom(true);
        else {
          followTail = false;
          window.scrollTo({top:previousY, behavior:'auto'});
        }
      };
      const typesetMath = root => {
        if (typeof renderMathInElement !== 'function') return true;
        const slash=String.fromCharCode(92);
        try {
          renderMathInElement(root, {
            delimiters:[
              {left:'$$',right:'$$',display:true},
              {left:slash+'[',right:slash+']',display:true},
              {left:slash+'(',right:slash+')',display:false},
              {left:'$',right:'$',display:false}
            ],
            ignoredClasses:['katex','katex-display','katex-html','katex-mathml'],
            throwOnError:false,
            strict:'ignore'
          });
        } catch (_) { return false; }
        return !root.querySelector('.katex-error');
      };
      const searchState={query:'',marks:[],index:-1};
      const clearSearchHighlights=()=>{
        document.querySelectorAll('mark.terminal-search-hit').forEach(mark=>mark.replaceWith(document.createTextNode(mark.textContent || '')));
        log.normalize();
        searchState.marks=[];
        searchState.index=-1;
      };
      const searchPayload=()=>({count:searchState.marks.length,index:searchState.index});
      const selectSearchHit=index=>{
        if(!searchState.marks.length){ searchState.index=-1; return searchPayload(); }
        searchState.index=((index % searchState.marks.length)+searchState.marks.length)%searchState.marks.length;
        searchState.marks.forEach((mark,i)=>mark.classList.toggle('current',i===searchState.index));
        const target=searchState.marks[searchState.index];
        followTail=false;
        target.scrollIntoView({block:'center',inline:'nearest',behavior:'auto'});
        return searchPayload();
      };
      window.terminal = {
        currentModel:'detecting …',
        setTheme(theme){ document.documentElement.dataset.theme=theme === 'blue' ? 'blue' : 'dark'; },
        restore(html,model){
          this.currentModel=model || this.currentModel;
          log.innerHTML=html || '';
          empty.style.display=log.children.length ? 'none' : 'block';
          followTail=true;
          setTimeout(()=>scrollBottom(true),0);
        },
        enablePersistence(){ persistenceEnabled=true; queueSnapshot(); },
        clear(){ searchState.query=''; searchState.marks=[]; searchState.index=-1; followTail=true; log.innerHTML=''; empty.style.display='block'; window.scrollTo({top:0,behavior:'auto'}); },
        jumpToBottom(){ followTail=true; scrollBottom(true); },
        clearSearch(){ searchState.query=''; clearSearchHighlights(); return searchPayload(); },
        search(query){
          clearSearchHighlights();
          searchState.query=(query || '').trim();
          if(!searchState.query) return searchPayload();
          const needle=searchState.query.toLocaleLowerCase();
          const walker=document.createTreeWalker(log,NodeFilter.SHOW_TEXT,{acceptNode(node){
            const parent=node.parentElement;
            if(!parent || !node.nodeValue || !parent.closest('.body,.boot')) return NodeFilter.FILTER_REJECT;
            if(parent.closest('.label,.katex,script,style,mark.terminal-search-hit')) return NodeFilter.FILTER_REJECT;
            return node.nodeValue.toLocaleLowerCase().includes(needle) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
          }});
          const nodes=[];
          while(walker.nextNode()) nodes.push(walker.currentNode);
          nodes.forEach(node=>{
            const value=node.nodeValue || '';
            const lower=value.toLocaleLowerCase();
            let cursor=0,match=lower.indexOf(needle);
            if(match<0) return;
            const fragment=document.createDocumentFragment();
            while(match>=0){
              if(match>cursor) fragment.appendChild(document.createTextNode(value.slice(cursor,match)));
              const mark=document.createElement('mark');
              mark.className='terminal-search-hit';
              mark.textContent=value.slice(match,match+searchState.query.length);
              fragment.appendChild(mark);
              searchState.marks.push(mark);
              cursor=match+searchState.query.length;
              match=lower.indexOf(needle,cursor);
            }
            if(cursor<value.length) fragment.appendChild(document.createTextNode(value.slice(cursor)));
            node.replaceWith(fragment);
          });
          return searchState.marks.length ? selectSearchHit(0) : searchPayload();
        },
        searchStep(delta){ return selectSearchHit(searchState.index+(delta < 0 ? -1 : 1)); },
        boot(model){
          this.currentModel=model || this.currentModel;
          empty.style.display='none';
          const e=document.createElement('section'); e.className='boot'; e.dataset.boot='true';
          e.innerHTML='<div class="boot-command"><span class="boot-prompt">$</span> pip \(terminalAddress)</div><div class="boot-lines"></div>';
          log.appendChild(e); const lines=e.querySelector('.boot-lines'); scrollBottom();
          setTimeout(()=>{ lines.insertAdjacentHTML('beforeend','<div class="boot-step">[1/3] loading authenticated session …</div>'); scrollBottom(); },160);
          setTimeout(()=>{ lines.insertAdjacentHTML('beforeend','<div class="boot-step">[2/3] mounting multimodal transport …</div>'); scrollBottom(); },360);
          setTimeout(()=>{ lines.insertAdjacentHTML('beforeend','<div class="boot-ok">[3/3] terminal ready ✓</div>'); scrollBottom(); },590);
          setTimeout(()=>{ const row=document.createElement('div'); row.innerHTML='current model: <span class="boot-model"></span>'; row.querySelector('.boot-model').textContent=terminal.currentModel; lines.appendChild(row); scrollBottom(); },780);
        },
        setModel(model){ this.currentModel=model; const target=[...document.querySelectorAll('.boot-model')].at(-1); if(target) target.textContent=model; },
        addUser(html){ empty.style.display='none'; const e=document.createElement('section'); e.className='message user'; e.innerHTML='<div class="label">INPUT &gt;</div><div class="body">'+html+'</div>'; log.appendChild(e); scrollBottom(); },
        setTransferStatus(text){ let e=document.querySelector('.transfer-status'); if(!text){ e?.remove(); return; } if(!e){ e=document.createElement('div'); e.className='transfer-status'; log.appendChild(e); } e.textContent=text; scrollBottom(); },
        beginAssistant(id){ empty.style.display='none'; const e=document.createElement('section'); e.className='message assistant'; e.dataset.id=id; e.innerHTML='<div class="label">CHATGPT &gt;</div><div class="body"></div>'; log.appendChild(e); scrollBottom(); },
        beginThinking(id){ let e=[...document.querySelectorAll('.assistant')].find(x=>x.dataset.id===id); if(!e){ this.beginAssistant(id); e=[...document.querySelectorAll('.assistant')].at(-1); } preserveReadingPosition(()=>{ e.querySelector('.body').textContent='Denke nach …'; }); },
        updateAssistant(id,html,streaming){
          let e=[...document.querySelectorAll('.assistant')].find(x=>x.dataset.id===id);
          if(!e){ this.beginAssistant(id); e=[...document.querySelectorAll('.assistant')].at(-1); }
          const body=e.querySelector('.body');
          const staged=document.createElement('div');
          staged.innerHTML=html;
          if(!typesetMath(staged)) return false;
          preserveReadingPosition(()=>{
            body.replaceChildren(...staged.childNodes);
            body.dataset.renderStable='true';
          });
          return true;
        }
      };
      new MutationObserver(queueSnapshot).observe(log,{subtree:true,childList:true,characterData:true,attributes:true});
      terminal.boot('detecting …');
    </script></body></html>
    """
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: TerminalController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMainMenu()
        controller = TerminalController()
        configureStatusItem()
#if BETA_BUILD
        if ProcessInfo.processInfo.arguments.contains("--external-selection-self-test") {
            controller?.runExternalSelectionSelfTest()
        } else if ProcessInfo.processInfo.arguments.contains("--selection-self-test") {
            controller?.runSelectionSelfTest()
        } else {
            controller?.showWindow()
        }
#else
        controller?.showWindow()
#endif
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "ChatGPT Terminal ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "ChatGPT Terminal beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
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

@main
struct ChatGPTTerminalV3App {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
