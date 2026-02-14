// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Whisp",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "WhispCore", targets: ["WhispCore"]),
        .executable(name: "whisp", targets: ["whisp"]),
        .executable(name: "WhispApp", targets: ["WhispApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "WhispCore"),
        .executableTarget(
            name: "whisp",
            dependencies: [
                "WhispCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "WhispApp",
            dependencies: ["WhispCore"]
        ),
        .testTarget(
            name: "WhispCoreTests",
            dependencies: ["WhispCore"]
        ),
        .testTarget(
            name: "WhispAppTests",
            dependencies: ["WhispApp", "WhispCore"]
        ),
        .testTarget(
            name: "WhispCLITests",
            dependencies: ["whisp", "WhispCore"]
        ),
    ]
)
