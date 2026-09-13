// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Vox",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Vox", targets: ["Vox"])
    ],
    targets: [
        .executableTarget(
            name: "Vox",
            path: "Sources/Vox"
        )
    ],
    swiftLanguageVersions: [.v5]
)
