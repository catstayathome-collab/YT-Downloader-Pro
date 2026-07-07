// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "YTDownloaderPro2",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "YTDownloaderPro2", targets: ["YTDownloaderPro2"])
    ],
    targets: [
        .executableTarget(name: "YTDownloaderPro2")
    ]
)
