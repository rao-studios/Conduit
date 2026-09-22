// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Conduit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Conduit", targets: ["Conduit"]),
        // The shared ~/.rao contract every Rao app and both servers agree on:
        // where things live, whose secret is whose, the /health proof, the
        // shared provider keys and how Sewn and a Thread are launched.
        // Foundation + swift-crypto only, so Sewn and Thread build it on Linux.
        .library(name: "RaoStack", targets: ["RaoStack"]),
        // macOS apps only: installing Sewn into ~/.rao, adopting or spawning
        // it and an app's Thread, and the leases that say who still needs Sewn.
        .library(name: "RaoStackLauncher", targets: ["RaoStackLauncher"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "1.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.2.0"),
    ],
    targets: [
        .target(
            name: "Conduit",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "RaoStack",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "RaoStackLauncher",
            dependencies: ["RaoStack"]
        ),
        .testTarget(
            name: "RaoStackTests",
            dependencies: ["RaoStack", "Conduit"],
            path: "Tests/RaoStackTests"
        ),
        .testTarget(
            name: "RaoStackLauncherTests",
            dependencies: ["RaoStackLauncher", "RaoStack"],
            path: "Tests/RaoStackLauncherTests"
        ),
        .testTarget(
            name: "ConduitTests",
            dependencies: [
                "Conduit",
                .product(name: "GRPCInProcessTransport", package: "grpc-swift"),
            ],
            path: "Tests/ConduitTests"
        ),
    ]
)
