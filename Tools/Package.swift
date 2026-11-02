// swift-tools-version: 6.0
// Code generation tools only (protoc + Swift plugins). Not part of the app build.
import PackageDescription

let package = Package(
    name: "VexTools",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.5.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.39.0"),
    ],
    targets: [
        .executableTarget(
            name: "vex-tools-anchor",
            dependencies: [
                .product(name: "protoc", package: "swift-protobuf"),
                .product(name: "protoc-gen-swift", package: "swift-protobuf"),
                .product(name: "protoc-gen-grpc-swift-2", package: "grpc-swift-protobuf"),
            ],
            path: "Anchor"
        ),
    ]
)
