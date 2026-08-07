// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIQuota",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AIQuota", targets: ["AIQuota"])
    ],
    targets: [
        .executableTarget(
            name: "AIQuota",
            path: "Sources"
        )
    ]
)
