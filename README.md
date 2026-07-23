# ChatGPT floating client without API for macOS>14

A small fully-LLM-produced floating ChatGPT client for macOS with a terminal-style interface. uses signed-in ChatGPT web session (login stays in macOS WebKit data store). No API. There are some features like search (cmd F), two color themes, file input, screenshot shortcut, text "copy paste" shortcut, conversation history, command line "\new" for new chat, command line "\cd last" for last found chat", command line "\clear” for fresh terminal. MacOS will ask for permission that the client can use the shortcut stuff.

Current version: **3.3.3 (Build 34)**

If current `chatgpt.com` UI changes then it will probably break in some features. You can just ask LLM to update it.

[![Build](https://github.com/lucamjp/TerminalV3/actions/workflows/build.yml/badge.svg)](https://github.com/lucamjp/TerminalV3/actions/workflows/build.yml)

```sh
git clone https://github.com/lucamjp/TerminalV3.git
cd TerminalV3
./scripts/build.sh release main
```

.app file is the build thing.


Useful:

```sh
swift build
./scripts/typecheck.sh
./scripts/build.sh debug beta
./scripts/run-beta.sh
```


## Some shortcuts

| `⌥ Space` | Show or hide |
| `⌥⇧4` | Capture a screenshot |
| `⌘ Return` | Send |
| `⌥⇧C` | Copy the latest answer |
| `⌘⇧C` | Insert selected text from another app |
| `⌘F` | Search the transcript |
| `⌘↓` | Jump to the latest output |
| `Esc` | Hide the window |

## Some commands

| Command | Action |
| --- | --- |
| `\clear` | Clear the terminal view |
| `\new` | Start a new chat |
| `\cd last` | Open the previous chat |
| `\stop` | Stop the current request or upload |