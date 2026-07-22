// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ChatGPTTerminal",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ChatGPTTerminal", targets: ["ChatGPTTerminal"])
    ],
    targets: [
        .executableTarget(
            name: "ChatGPTTerminal",
            path: ".",
            exclude: [
                ".vscode",
                ".build",
                "build",
                "Tests",
                "scripts",
                "Info.plist",
                "Info.Beta.plist",
                "README.md",
                "ChatGPT Terminal.code-workspace"
            ],
            sources: ["main.swift"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("PDFKit"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("WebKit")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
