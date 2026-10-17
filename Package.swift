// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ContactWiz",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ContactWiz", targets: ["ContactWiz"]),
        .executable(name: "contactwiz-cli", targets: ["contactwiz-cli"]),
    ],
    targets: [
        .target(name: "ContactWizCore"),
        .executableTarget(name: "ContactWiz", dependencies: ["ContactWizCore"]),
        .executableTarget(name: "contactwiz-cli", dependencies: ["ContactWizCore"]),
        .executableTarget(name: "contactwiz-checks", dependencies: ["ContactWizCore"]),
    ],
    swiftLanguageModes: [.v5]
)
