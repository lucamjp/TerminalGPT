# Contributing

## Setup

```sh
git clone https://github.com/lucamjp/TerminalV3.git
cd TerminalV3
swift build
```

## Before a pull request

```sh
./scripts/typecheck.sh
./scripts/build.sh debug main
./scripts/build.sh debug beta
```

Keep pull requests focused. Do not mix UI changes with DOM selector changes.

ChatGPT page integration belongs in `TerminalController+WebScripts.swift`. Native window and message flow code belongs in `TerminalController.swift`.

Do not commit credentials, cookies, signing certificates, or local keychain details.
