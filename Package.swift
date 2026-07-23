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
