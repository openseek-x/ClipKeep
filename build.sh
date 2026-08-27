#!/bin/bash
# 构建 ClipKeep.app
#
# 本机只有 Command Line Tools（无完整 Xcode），因此不用 xcodebuild，
# 直接 swiftc 编译后手工组装 .app bundle 并 ad-hoc 签名。
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ClipKeep"
BUILD_DIR="build"
APP="${BUILD_DIR}/${APP_NAME}.app"
MACOS_DIR="${APP}/Contents/MacOS"
RES_DIR="${APP}/Contents/Resources"

echo "==> 清理"
rm -rf "${APP}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"

echo "==> 编译 (arm64, -O)"
swiftc \
  -parse-as-library \
  -O \
  -target arm64-apple-macosx13.0 \
  Sources/ClipKeep/Models.swift \
  Sources/ClipKeep/Preview.swift \
  Sources/ClipKeep/PrivacyFilter.swift \
  Sources/ClipKeep/ImageCodec.swift \
  Sources/ClipKeep/ClipStore.swift \
  Sources/ClipKeep/ClipboardMonitor.swift \
  Sources/ClipKeep/HotKeyManager.swift \
  Sources/ClipKeep/Settings.swift \
  Sources/ClipKeep/HistoryView.swift \
  Sources/ClipKeep/HistoryPanelController.swift \
  Sources/ClipKeep/AppDelegate.swift \
  -o "${MACOS_DIR}/${APP_NAME}"

echo "==> 写入 Info.plist"
cp Resources/Info.plist "${APP}/Contents/Info.plist"

echo "==> ad-hoc 签名"
# 无付费开发者账号，只能 ad-hoc 签名。Gatekeeper 首次打开会拦，
# 需右键→打开，或执行 xattr -d com.apple.quarantine。
codesign --force --sign - --timestamp=none "${APP}"
codesign --verify --verbose=1 "${APP}" 2>&1 | sed 's/^/    /'

echo ""
echo "构建完成: ${APP}"
echo ""
echo "安装：cp -R ${APP} /Applications/"
echo "运行：open ${APP}"
