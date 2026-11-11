// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "anyfsd",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "anyfsd",
            path: "Sources/anyfsd"
        ),
        .executableTarget(
            name: "anyfsctl",
            path: "Sources/anyfsctl"
        )
    ]
)
