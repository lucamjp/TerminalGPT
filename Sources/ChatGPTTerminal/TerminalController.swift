import AppKit
import ApplicationServices
import Carbon
import UniformTypeIdentifiers
import WebKit

final class TerminalController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NSTextViewDelegate, NSSearchFieldDelegate {
    // MARK: Windows and views

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

    // MARK: Keyboard shortcuts

    private var hotKeyRef: EventHotKeyRef?
    private var screenshotHotKeyRef: EventHotKeyRef?
    private var copyHotKeyRef: EventHotKeyRef?
    private var sendHotKeyRef: EventHotKeyRef?
    private var captureSelectionHotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var keyMonitor: Any?

    // MARK: Conversation state

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

    // MARK: Local state

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

    // MARK: Lifecycle

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

    // MARK: Window layout

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

    // MARK: Theme

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

    // MARK: ChatGPT session

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

    // MARK: Keyboard shortcuts

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
        RegisterEventHotKey(
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

    // MARK: Session loading

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

    // MARK: Window actions

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

    // MARK: Transcript search

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

    // MARK: Text capture and clipboard

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


    // Copies ChatGPT's source text instead of the rendered terminal output.
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

    // MARK: Conversation navigation

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

    // MARK: Attachments

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

    // MARK: Message submission

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

    // MARK: Uploads

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

    // MARK: ChatGPT bridge

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

    // MARK: Terminal rendering

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

    // MARK: WebKit delegates

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

    // MARK: System events

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

}
