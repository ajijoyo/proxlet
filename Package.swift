// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Proxlet",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.105.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.6"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.37.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.21.1"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.7.4"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
    ],
    targets: [
        .target(
            name: "ProxletCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(name: "Proxlet", dependencies: ["ProxletCore"]),
        .executableTarget(
            name: "proxlet-mcp",
            dependencies: ["ProxletCore", .product(name: "MCP", package: "swift-sdk")]
        ),
        .testTarget(
            name: "ProxletCoreTests",
            dependencies: [
                "ProxletCore",
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ]
        ),
        .testTarget(name: "ProxletTests", dependencies: ["Proxlet", "ProxletCore"]),
    ],
    swiftLanguageModes: [.v5]
)
