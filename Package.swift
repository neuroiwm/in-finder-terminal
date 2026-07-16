// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FinderTerm",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "FinderTerm",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/FinderTerm"
        ),
        .testTarget(
            name: "FinderTermTests",
            dependencies: ["FinderTerm"],
            path: "Tests/FinderTermTests"
        )
    ]
)
