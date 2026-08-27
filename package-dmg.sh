#!/bin/bash
# 打包 ClipKeep.dmg
#
# 产出一个带 Applications 快捷方式的拖拽安装 DMG。
# 全部使用 macOS 自带工具（hdiutil / osascript / SetFile），无第三方依赖。
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ClipKeep"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD_DIR="build"
APP="${BUILD_DIR}/${APP_NAME}.app"
VOL_NAME="${APP_NAME} ${VERSION}"
DMG_FINAL="${BUILD_DIR}/${APP_NAME}-${VERSION}.dmg"
DMG_TMP="${BUILD_DIR}/.${APP_NAME}-tmp.dmg"
STAGE="${BUILD_DIR}/.dmg-stage"
# 实际挂载点由 hdiutil attach 输出解析得到（见下），此处仅声明
MOUNT_DIR=""

# app 不存在时先构建，避免打出空包
if [[ ! -d "${APP}" ]]; then
    echo "==> 未找到 ${APP}，先执行构建"
    ./build.sh
fi

echo "==> 校验 app 签名"
codesign --verify --deep --strict "${APP}" || {
    echo "错误：签名校验失败，DMG 未生成" >&2
    exit 1
}

# 清理上一次可能残留的挂载与临时文件
cleanup() {
    if [[ -n "${MOUNT_DIR}" && -d "${MOUNT_DIR}" ]]; then
        hdiutil detach "${MOUNT_DIR}" -force >/dev/null 2>&1 || true
    fi
    rm -rf "${STAGE}" "${DMG_TMP}"
}
trap cleanup EXIT
rm -rf "${STAGE}" "${DMG_TMP}"

echo "==> 准备内容"
mkdir -p "${STAGE}"
cp -R "${APP}" "${STAGE}/"
# 拖拽安装用的 Applications 快捷方式
ln -s /Applications "${STAGE}/Applications"

# 附上说明，解释 Gatekeeper 首次打开的处理方式（本 app 为 ad-hoc 签名，未公证）
cat > "${STAGE}/首次打开请先读我.txt" <<'TXT'
ClipKeep 安装说明
==================

1. 把左边的 ClipKeep 拖到右边的 Applications 文件夹

2. 首次打开必须右键点击（不要双击）：
      在「应用程序」中找到 ClipKeep
      → 右键 → 打开
      → 在弹出的对话框中再点「打开」

   之后就可以正常双击打开了。

   为什么需要这一步：本 app 未经 Apple 公证（需付费开发者账号），
   macOS 会默认拦截。这一步是告诉系统你信任它。

   也可以用命令行跳过：
      xattr -d com.apple.quarantine /Applications/ClipKeep.app

3. 打开后菜单栏会出现剪贴板图标，此时已开始自动记录复制内容。
   按 Cmd+Shift+V 调出历史记录。

不需要任何系统授权，装完即用。

详细说明见项目 README。
TXT

echo "==> 生成可写镜像"
# 预留 60% 余量给文件系统开销与 .DS_Store，避免容量不足导致布局写入失败
SIZE_KB=$(du -sk "${STAGE}" | awk '{print $1}')
SIZE_MB=$(( SIZE_KB * 160 / 100 / 1024 + 12 ))
hdiutil create \
    -srcfolder "${STAGE}" \
    -volname "${VOL_NAME}" \
    -fs HFS+ \
    -format UDRW \
    -size "${SIZE_MB}m" \
    -quiet \
    "${DMG_TMP}"

echo "==> 挂载并设置窗口布局"
# 不加 -nobrowse：Finder 需要能看到该卷才能按名称寻址并设置布局。
# 挂载到 /Volumes 下的默认位置，由 hdiutil 输出解析实际挂载点
# （同名卷已存在时系统会自动追加后缀，不能假定路径）。
MOUNT_DIR="$(hdiutil attach "${DMG_TMP}" -noautoopen | \
    grep -oE '/Volumes/.*$' | tail -1)"
if [[ -z "${MOUNT_DIR}" || ! -d "${MOUNT_DIR}" ]]; then
    echo "错误：挂载失败" >&2
    exit 1
fi
# Finder 按卷名寻址，取实际挂载后的名称
MOUNTED_NAME="$(basename "${MOUNT_DIR}")"
echo "    挂载于 ${MOUNT_DIR}"

# 用 Finder 设置图标位置与窗口尺寸。失败不阻断打包 —— 布局只影响观感，
# 拖拽安装本身不依赖它（无 GUI 会话或 Finder 无权限时会失败）。
LAYOUT_OK=1
if ! osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Finder"
    tell disk "${MOUNTED_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {320, 160, 940, 560}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 104
        set text size of opts to 12
        set position of item "${APP_NAME}.app" of container window to {150, 190}
        set position of item "Applications" of container window to {460, 190}
        set position of item "首次打开请先读我.txt" of container window to {305, 330}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
then
    LAYOUT_OK=0
    echo "    提示：Finder 布局设置未生效（不影响安装）"
fi

# 让 .DS_Store 落盘
sync
sync

# 移除挂载过程中系统自动生成的元数据目录，避免它们进入最终镜像
rm -rf "${MOUNT_DIR}/.fseventsd" "${MOUNT_DIR}/.Trashes" \
       "${MOUNT_DIR}/.TemporaryItems" "${MOUNT_DIR}/.Spotlight-V100" 2>/dev/null || true
sync

echo "==> 卸载"
hdiutil detach "${MOUNT_DIR}" -quiet || hdiutil detach "${MOUNT_DIR}" -force -quiet

echo "==> 压缩为最终镜像 (ULFO/lzfse)"
rm -f "${DMG_FINAL}"
hdiutil convert "${DMG_TMP}" -format ULFO -o "${DMG_FINAL}" -quiet

echo "==> 签名镜像"
codesign --force --sign - "${DMG_FINAL}"

echo "==> 校验"
hdiutil verify "${DMG_FINAL}" >/dev/null 2>&1 && echo "    镜像校验通过"
codesign --verify "${DMG_FINAL}" && echo "    签名校验通过"

rm -rf "${STAGE}" "${DMG_TMP}"
trap - EXIT

echo ""
echo "打包完成: ${DMG_FINAL}  ($(du -h "${DMG_FINAL}" | awk '{print $1}'))"
echo ""
echo "校验和 (SHA-256):"
shasum -a 256 "${DMG_FINAL}" | awk '{print "    " $1}'
