// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CoachCore",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "CoachCore", targets: ["CoachCore"])
    ],
    targets: [
        .target(name: "CoachCore"),
        .testTarget(name: "CoachCoreTests", dependencies: ["CoachCore"])
    ]
)
