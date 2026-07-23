import Carbon

let hotKeySignature: OSType = 0x54525633 // TRV3

#if BETA_BUILD
let terminalPanelTitle = "ChatGPT Terminal Beta 3.3.2 (Build 33)"
let terminalAddress = "chatgpt://terminal/v3-beta"
let selectionShortcutLabel = "⌃⌥⇧C"
#else
let terminalPanelTitle = "ChatGPT Terminal 3.3.3 (Build 34)"
let terminalAddress = "chatgpt://terminal/v3"
let selectionShortcutLabel = "⌘⇧C"
#endif

enum HotKeyID: UInt32 {
    case window = 1
    case screenshot = 2
    case copyLatest = 3
    case send = 4
    case captureSelection = 5
}
