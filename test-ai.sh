#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

mkdir -p build/tests

CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/clipkeep-clang-cache" \
SWIFT_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/clipkeep-swift-cache" \
swiftc \
  -parse-as-library \
  -target arm64-apple-macosx13.0 \
  -framework AppKit \
  -framework Carbon \
  -framework ImageIO \
  -framework Security \
  -framework Vision \
  Sources/ClipKeep/Models.swift \
  Sources/ClipKeep/AIModels.swift \
  Sources/ClipKeep/SensitiveDataScanner.swift \
  Sources/ClipKeep/AIProvider.swift \
  Sources/ClipKeep/OpenAIResponsesProvider.swift \
  Sources/ClipKeep/LocalCompatibleProvider.swift \
  Sources/ClipKeep/ImageCodec.swift \
  Sources/ClipKeep/ImageTextScanner.swift \
  Sources/ClipKeep/SecretStore.swift \
  Sources/ClipKeep/AIActionViewModel.swift \
  Sources/ClipKeep/AppMenu.swift \
  Sources/ClipKeep/HotKeyManager.swift \
  Sources/ClipKeep/Settings.swift \
  Tests/AIUnitTests.swift \
  -o build/tests/AIUnitTests

build/tests/AIUnitTests
