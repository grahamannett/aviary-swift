// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Aviary",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "aviary", targets: ["Aviary"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "Cookies",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .target(
            name: "XClient",
            dependencies: ["Cookies"],
            resources: [
                .copy("Resources/query-ids.json"),
                .copy("Resources/features.json"),
            ]
        ),
        .target(
            name: "AviaryCLI",
            dependencies: [
                "Cookies",
                "XClient",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "Aviary",
            dependencies: ["AviaryCLI"]
        ),
        .executableTarget(
            name: "AviarySelfTest",
            dependencies: ["Cookies", "XClient", "AviaryCLI"]
        ),
    ]
)
