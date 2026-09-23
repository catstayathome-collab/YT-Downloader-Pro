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
    dependencies: [
        .package(
            url: "https://github.com/supabase/supabase-swift.git",
            exact: "2.55.2"
        )
    ],
    targets: [
        .executableTarget(
            name: "YTDownloaderPro2",
            dependencies: [
                .product(name: "Auth", package: "supabase-swift")
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "YTDownloaderPro2Tests",
            dependencies: ["YTDownloaderPro2"],
            resources: [.process("Fixtures")]
        )
    ]
)
