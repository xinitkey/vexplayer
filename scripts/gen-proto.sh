#!/bin/bash
# Regenerates Sources/EmulatorAPI from Protos/*.proto.
# The .proto files ship inside the Android Emulator package (emulator/lib/*.proto).
set -euo pipefail
cd "$(dirname "$0")/.."

TOOLS=Tools
swift build -c release --package-path "$TOOLS" --product protoc
swift build -c release --package-path "$TOOLS" --product protoc-gen-swift
swift build -c release --package-path "$TOOLS" --product protoc-gen-grpc-swift-2
BIN="$(swift build -c release --package-path "$TOOLS" --show-bin-path)"
WKT="$TOOLS/.build/checkouts/swift-protobuf/Sources/protobuf/include"

OUT=Sources/EmulatorAPI
rm -f "$OUT"/*.pb.swift "$OUT"/*.grpc.swift

"$BIN/protoc" \
  --plugin=protoc-gen-swift="$BIN/protoc-gen-swift" \
  --plugin=protoc-gen-grpc-swift="$BIN/protoc-gen-grpc-swift-2" \
  -I Protos -I "$WKT" \
  --swift_out="$OUT" --swift_opt=Visibility=Public \
  --grpc-swift_out="$OUT" --grpc-swift_opt=Visibility=Public,Server=false \
  Protos/emulator_controller.proto

echo "Generated:"; ls -1 "$OUT"
