// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TVPairCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "TVPairCore", targets: ["TVPairCore"])],
    dependencies: [.package(url: "https://github.com/attaswift/BigInt.git", exact: "5.7.0")],
    targets: [
        .target(name: "TVPairCore", dependencies: ["BigInt"]),
        .testTarget(name: "TVPairCoreTests", dependencies: ["TVPairCore", "BigInt"], resources: [.copy("Fixtures")])
    ]
)
