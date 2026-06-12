#!/usr/bin/env bash
# Regenerates Sources/Conduit/Generated from Protos/totem.proto.
#
# The gRPC plugin is built from the package's resolved grpc-swift-protobuf
# checkout so the generated code always matches the runtime the package links
# against (a Homebrew-installed plugin can be a different version and produce
# code that doesn't compile). Requires protoc and protoc-gen-swift on PATH
# (brew install protobuf swift-protobuf) and a prior `swift package resolve`.
set -euo pipefail
cd "$(dirname "$0")/.."

PLUGIN=.build/plugin-build/release/protoc-gen-grpc-swift
if [[ ! -x "$PLUGIN" ]]; then
  swift package resolve
  swift build --package-path .build/checkouts/grpc-swift-protobuf \
    --product protoc-gen-grpc-swift -c release --scratch-path .build/plugin-build
fi

OUT=Sources/Conduit/Generated
mkdir -p "$OUT"
protoc --proto_path=Protos \
  --swift_out="$OUT" --swift_opt=Visibility=Public \
  --plugin=protoc-gen-grpc-swift="$PLUGIN" \
  --grpc-swift_out="$OUT" \
  --grpc-swift_opt=Visibility=Public \
  --grpc-swift_opt=Server=true --grpc-swift_opt=Client=true \
  Protos/totem.proto
echo "Generated $(ls "$OUT")"
