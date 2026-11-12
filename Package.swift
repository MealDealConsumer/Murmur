// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
        .executableTarget(
            name: "Murmur",
            dependencies: ["whisper"],
            path: "Sources/Murmur",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
    ]
)
