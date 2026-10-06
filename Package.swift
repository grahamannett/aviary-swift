// swift-tools-version: 6.1
import PackageDescription

#if os(macOS)
// Use the macOS SDK's SQLite, rather than a build machine's Homebrew library.
let sqlitePkgConfig: String? = nil
#else
let sqlitePkgConfig: String? = "sqlite3"
#endif

let package = Package(
    name: "Aviary",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "aviary", targets: ["Aviary"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
        .package(url: "https://github.com/apple/swift-crypto", exact: "3.15.1"),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: sqlitePkgConfig,
            providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite"])]
        ),
        .target(
            name: "Cookies",
            dependencies: [
                "CSQLite",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
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
        .testTarget(name: "CookiesTests", dependencies: ["Cookies", "CSQLite", .product(name: "Crypto", package: "swift-crypto"), .product(name: "_CryptoExtras", package: "swift-crypto")]),
        .testTarget(name: "XClientTests", dependencies: ["XClient", "Cookies"], resources: [.copy("Fixtures")]),
        .testTarget(name: "AviaryCLITests", dependencies: ["AviaryCLI", "XClient", "Cookies"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
