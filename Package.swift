// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ReTerm",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
    ],
    targets: [
        .executableTarget(
            name: "ReTerm",
            dependencies: ["SwiftTerm"],
            path: "Sources/ReTerm",
            swiftSettings: [.unsafeFlags(["-Ounchecked"])]
        ),
    ]
)
