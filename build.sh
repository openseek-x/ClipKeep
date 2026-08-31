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
FW_DIR="${APP}/Contents/Frameworks"
SPARKLE="Frameworks/Sparkle.framework"

if [[ ! -d "${SPARKLE}" ]]; then
    echo "错误：未找到 ${SPARKLE}" >&2
    echo "请先运行 ./fetch-sparkle.sh 获取 Sparkle 框架（会校验官方包的 SHA-256）。" >&2
    exit 1
fi

echo "==> 清理"
rm -rf "${APP}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}" "${FW_DIR}"

echo "==> 嵌入 Sparkle.framework"
# -R 保留符号链接结构；framework 内含 XPCServices 与 Updater.app，必须整体复制
cp -R "${SPARKLE}" "${FW_DIR}/"

echo "==> 编译 (arm64, -O)"
swiftc \
  -parse-as-library \
  -O \
  -target arm64-apple-macosx13.0 \
  -F Frameworks \
  -framework Sparkle \
  -framework Security \
  -framework ImageIO \
  -framework Vision \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  Sources/ClipKeep/Models.swift \
  Sources/ClipKeep/AIModels.swift \
  Sources/ClipKeep/Preview.swift \
  Sources/ClipKeep/SensitiveDataScanner.swift \
  Sources/ClipKeep/SecretStore.swift \
  Sources/ClipKeep/AIProvider.swift \
  Sources/ClipKeep/OpenAIResponsesProvider.swift \
  Sources/ClipKeep/LocalCompatibleProvider.swift \
  Sources/ClipKeep/PrivacyFilter.swift \
  Sources/ClipKeep/ImageCodec.swift \
  Sources/ClipKeep/ImageTextScanner.swift \
  Sources/ClipKeep/ClipStore.swift \
  Sources/ClipKeep/ClipboardMonitor.swift \
  Sources/ClipKeep/HotKeyManager.swift \
  Sources/ClipKeep/Settings.swift \
  Sources/ClipKeep/AIActionViewModel.swift \
  Sources/ClipKeep/AISettingsWindowController.swift \
  Sources/ClipKeep/AppMenu.swift \
  Sources/ClipKeep/UpdateController.swift \
  Sources/ClipKeep/HistoryView.swift \
  Sources/ClipKeep/HistoryPanelController.swift \
  Sources/ClipKeep/AppDelegate.swift \
  -o "${MACOS_DIR}/${APP_NAME}"

echo "==> 写入 Info.plist"
cp Resources/Info.plist "${APP}/Contents/Info.plist"

echo "==> ad-hoc 签名"
# 无付费开发者账号，只能 ad-hoc 签名。Gatekeeper 首次打开会拦，
# 需右键→打开，或执行 xattr -d com.apple.quarantine。
#
# 签名顺序至关重要：必须自内向外。先签 framework 内的 XPC 服务与辅助 app，
# 再签 framework 本身，最后签外层 app —— 否则外层签名会因内部内容变动而失效。
for xpc in "${FW_DIR}/Sparkle.framework/XPCServices/"*.xpc; do
    [[ -e "$xpc" ]] && codesign --force --sign - --timestamp=none "$xpc"
done
if [[ -d "${FW_DIR}/Sparkle.framework/Updater.app" ]]; then
    codesign --force --sign - --timestamp=none "${FW_DIR}/Sparkle.framework/Updater.app"
fi
if [[ -e "${FW_DIR}/Sparkle.framework/Autoupdate" ]]; then
    codesign --force --sign - --timestamp=none "${FW_DIR}/Sparkle.framework/Autoupdate"
fi
codesign --force --sign - --timestamp=none "${FW_DIR}/Sparkle.framework"
codesign --force --sign - --timestamp=none "${APP}"

codesign --verify --deep --strict --verbose=1 "${APP}" 2>&1 | sed 's/^/    /'

echo ""
echo "构建完成: ${APP}"
echo ""
echo "安装：cp -R ${APP} /Applications/"
echo "运行：open ${APP}"
