# ChatGPT Terminal

Native macOS-Terminaloberfläche für eine bestehende, angemeldete ChatGPT-Websitzung. Die Oberfläche ist mit AppKit gebaut; Chatverlauf und ChatGPT-Sitzung laufen in getrennten `WKWebView`-Instanzen.

Autor: Luca Prior

## Aktueller Stand

- Hauptversion: 3.3.3, Build 34
- Beta-Variante im Quellcode: 3.3.2, Build 33
- Mindestversion: macOS 14
- Hauptdatei: `main.swift`

Die installierte Hauptversion unter `/Applications/ChatGPT Terminal.app` ist nicht Teil des Entwicklungsablaufs. Entwicklung und manuelle Tests erfolgen mit der separat gebauten Beta-App.

## In VS Code öffnen

Öffne `ChatGPT Terminal.code-workspace`. Empfohlene Erweiterungen werden von VS Code angeboten:

- Swift
- CodeLLDB

Über **Terminal → Run Task** stehen Builds, Typecheck und Beta-Start bereit. Der Standard-Build ist **Build: Beta (Debug)**.

## Befehle

```sh
./scripts/build.sh debug beta
./scripts/run-beta.sh
./scripts/typecheck.sh
swift build
```

Ein Main-Build kann erzeugt werden, wird aber nicht installiert:

```sh
./scripts/build.sh debug main
```

Die Apps landen unter `build/beta-debug` beziehungsweise `build/main-debug`.

## Signierung und macOS-Rechte

Entwicklungs-Builds werden standardmäßig ad hoc signiert. Nach einem neuen Build kann macOS deshalb Bedienungshilfen- oder Bildschirmaufnahme-Rechte erneut verlangen.

Falls der lokale Signaturschlüssel bereits im Schlüsselbund entsperrt ist, kann stabil signiert werden:

```sh
SIGN_MODE=local ./scripts/build.sh release beta
```

Im Repository werden weder Schlüsselbund-Passwort noch private Zertifikatsdaten gespeichert. Bei einer Passwortabfrage den Schlüsselbund über die Schlüsselbundverwaltung entsperren.

## Varianten

Der Compiler-Schalter `BETA_BUILD` trennt Beta und Main. Die Beta besitzt eine eigene Bundle-ID und einen eigenen globalen Shortcut für die Textübernahme. `Info.plist` gehört zur Hauptversion, `Info.Beta.plist` zur Beta.

## Architekturhinweise

- AppKit steuert Fenster, Eingabe, Anhänge, Shortcuts und Verlauf.
- WebKit hält die angemeldete ChatGPT-Sitzung und rendert den Terminal-Verlauf.
- Text, Bilder und PDFs werden über die ChatGPT-Weboberfläche übergeben.
- Antworten und Kopierformatierung werden aus dem DOM der Hintergrundsitzung gelesen.
- Die DOM-Automation ist absichtlich gekapselt, bleibt aber von Änderungen der ChatGPT-Weboberfläche abhängig.
- Globale Shortcuts und die Übernahme einer Auswahl aus anderen Apps benötigen Bedienungshilfen-Rechte.
- Die Screenshot-Funktion benötigt die macOS-Bildschirmaufnahme-Berechtigung.

## Auswahl-Testhelfer

Der kleine Testhelfer stellt außerhalb des Terminals markierten Text bereit:

```sh
./scripts/build-selection-probe.sh
```

Er wird nach `/private/tmp/ChatGPT Selection Probe` gebaut und verändert weder Haupt- noch Beta-App.
