// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TVPairCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "TVPairCore", targets: ["TVPairCore"])],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", exact: "5.7.0"),
        .package(url: "https://github.com/krzyzanowskim/OpenSSL-Package.git", exact: "3.6.5000")
    ],
    targets: [
        .target(name: "TVPairTLS", dependencies: [.product(name: "OpenSSL", package: "OpenSSL-Package")]),
        .target(name: "TVPairCore", dependencies: ["BigInt", "TVPairTLS"]),
        .testTarget(name: "TVPairCoreTests", dependencies: ["TVPairCore", "BigInt"], resources: [.copy("Fixtures")])
    ]
)
