# Architecture

## Code map

| Path | Purpose |
| --- | --- |
| `AppConfiguration.swift` | Version labels and hotkey IDs |
| `AppDelegate.swift` | App lifecycle, menu bar item, app menu |
| `TerminalController.swift` | Native UI, shortcuts, uploads, and message flow |
| `TerminalController+WebScripts.swift` | ChatGPT DOM bridge and terminal HTML |
| `TerminalInputView.swift` | Text input, history keys, paste, and drag-and-drop |
| `PendingAttachment.swift` | Image and PDF attachment conversion |
| `ChatGPTTerminalApp.swift` | Process entry point |

## Runtime

`TerminalController` owns two `WKWebView` instances:

1. `sessionView` loads the signed-in ChatGPT page.
2. `transcriptView` renders the terminal UI.

The native controller submits text and attachments to `sessionView`. JavaScript observers send response updates back through `WKScriptMessageHandler`. The controller forwards stable HTML to `transcriptView`.

The session uses `WKWebsiteDataStore.default()`, so login state survives app restarts.

## Build variants

`BETA_BUILD` changes the bundle identity, title, address label, and selected-text shortcut. Both variants share the same source files.

## Fragile boundary

Selectors in `TerminalController+WebScripts.swift` depend on the ChatGPT page structure. Keep selector changes isolated and small.
