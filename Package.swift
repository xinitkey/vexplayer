// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VexPlayer",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "VexPlayer", targets: ["VexPlayer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.4"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.11.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.5.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.39.0"),
    ],
    targets: [
        // Generated from the emulator's own .proto files (scripts/gen-proto.sh).
        .target(
            name: "EmulatorAPI",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/EmulatorAPI"
        ),
        .executableTarget(
            name: "VexPlayer",
            dependencies: [
                "EmulatorAPI",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ],
            path: "Sources/VexPlayer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VexPlayerTests",
            dependencies: ["VexPlayer"],
            path: "Tests/VexPlayerTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
