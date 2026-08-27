#!/bin/bash
# 发布新版本：构建 → 打包 → 签名 → 生成 appcast → 上传 Release → 发布 appcast
#
# 用法: ./release.sh 1.0.1 "本次更新说明"
#
# 前置条件：
#   1. 已用 Tools/generate_keys 生成签名密钥（私钥在你的钥匙串中，绝不进仓库）
#   2. gh 已认证且有 openseek-x/ClipKeep 的写权限
#   3. 工作区干净且已推送
set -euo pipefail

cd "$(dirname "$0")"

VERSION="${1:-}"
NOTES="${2:-}"
if [[ -z "${VERSION}" ]]; then
    echo "用法: ./release.sh <版本号> [更新说明]" >&2
    echo "例如: ./release.sh 1.0.1 \"修复面板在多显示器下的定位问题\"" >&2
    exit 1
fi
# 版本号必须是 x.y.z，Sparkle 依赖它做版本比较
if ! [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "错误：版本号必须为 x.y.z 格式，收到 '${VERSION}'" >&2
    exit 1
fi

REPO="openseek-x/ClipKeep"
APP_NAME="ClipKeep"
BUILD_DIR="build"
DMG="${BUILD_DIR}/${APP_NAME}-${VERSION}.dmg"
APPCAST_DIR="${BUILD_DIR}/appcast"
SIGN_TOOL="Tools/sign_update"
# 签名超时（秒）。超时通常意味着钥匙串授权对话框无人应答。
SIGN_TIMEOUT=30
# 私钥文件。存于仓库之外，权限 0600，绝不进版本控制。
#
# 为何用文件而非直接读钥匙串：sign_update 每次访问钥匙串都可能弹出授权对话框，
# 该对话框无法在非交互环境应答，会导致脚本无限阻塞（实测确认）。
# 通过 `--ed-key-file -` 从 stdin 传入密钥可完全绕开钥匙串交互。
KEY_FILE="${CLIPKEEP_SIGNING_KEY:-$HOME/.clipkeep/signing.key}"

for t in "${SIGN_TOOL}"; do
    [[ -x "$t" ]] || { echo "错误：缺少 $t" >&2; exit 1; }
done

# 拒绝在脏工作区发布：发出去的包必须能对应到一个确定的提交
if [[ -n "$(git status --porcelain)" ]]; then
    echo "错误：工作区有未提交的变更，请先提交或暂存" >&2
    git status --short >&2
    exit 1
fi

echo "==> 校验私钥可用"
if [[ ! -f "${KEY_FILE}" ]]; then
    echo "错误：未找到私钥 ${KEY_FILE}" >&2
    echo "" >&2
    echo "首次发布请运行： ./generate-signing-key.sh" >&2
    exit 1
fi
# 私钥文件权限必须严格：组或其他用户可读即视为已泄露风险
PERM=$(stat -f "%OLp" "${KEY_FILE}")
if [[ "${PERM}" != "600" && "${PERM}" != "400" ]]; then
    echo "错误：私钥权限为 ${PERM}，应为 600。" >&2
    echo "  chmod 600 ${KEY_FILE}" >&2
    exit 1
fi

# 从文件读私钥经 stdin 传给 sign_update，完全绕开钥匙串交互。
# 加超时兜底：即使走 stdin 路径也不让脚本有挂死可能。
sign_with_timeout() {
    local file="$1" out rc
    out=$(mktemp)
    ( "${SIGN_TOOL}" --ed-key-file - -p "$file" < "${KEY_FILE}" > "$out" 2>&1 ) &
    local pid=$!
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if (( waited >= SIGN_TIMEOUT )); then
            kill -9 "$pid" 2>/dev/null
            rm -f "$out"
            return 124
        fi
        sleep 1
        (( waited++ ))
    done
    wait "$pid" 2>/dev/null; rc=$?
    cat "$out"
    rm -f "$out"
    return $rc
}

echo "test" > /tmp/.sign-probe
if ! PROBE_SIG=$(sign_with_timeout /tmp/.sign-probe) || [[ -z "${PROBE_SIG}" ]]; then
    rc=$?
    rm -f /tmp/.sign-probe
    if (( rc == 124 )); then
        echo "错误：签名超时 ${SIGN_TIMEOUT}s，脚本已中止而非挂死。" >&2
    else
        echo "错误：无法用 ${KEY_FILE} 签名。请确认该文件是 generate_keys -x 导出的私钥。" >&2
    fi
    exit 1
fi
rm -f /tmp/.sign-probe
echo "    私钥可用（${KEY_FILE}）"

echo "==> 同步 Info.plist 版本号至 ${VERSION}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" Resources/Info.plist
# CFBundleVersion 用递增整数，Sparkle 以它判断新旧
BUILD_NUM=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)
BUILD_NUM=$((BUILD_NUM + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUM}" Resources/Info.plist
echo "    CFBundleShortVersionString=${VERSION} CFBundleVersion=${BUILD_NUM}"

echo "==> 构建与打包"
./build.sh >/dev/null
./package-dmg.sh >/dev/null
[[ -f "${DMG}" ]] || { echo "错误：未产出 ${DMG}" >&2; exit 1; }
DMG_SIZE=$(stat -f%z "${DMG}")
echo "    ${DMG} (${DMG_SIZE} 字节)"

echo "==> EdDSA 签名"
SIGNATURE=$(sign_with_timeout "${DMG}") || {
    echo "错误：签名失败或超时" >&2
    exit 1
}
[[ -n "${SIGNATURE}" ]] || { echo "错误：签名为空" >&2; exit 1; }
echo "    签名已生成 (${#SIGNATURE} 字符)"

echo "==> 自检：用 Info.plist 中的公钥验签，必须通过"
# 不用 sign_update --verify：它从钥匙串读密钥，会弹授权对话框导致挂死。
# 改为直接用内嵌公钥验证，这也更贴近客户端的真实验签路径 ——
# 确认发出的签名确实能被 app 内的公钥接受。
PUBKEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist)
VERIFY_BIN="${BUILD_DIR}/.verify-sig"
cat > "${BUILD_DIR}/.verify-sig.swift" <<'SWIFT'
import Foundation
import CryptoKit
@main struct V {
    static func main() {
        let a = CommandLine.arguments
        guard a.count == 4,
              let data = try? Data(contentsOf: URL(fileURLWithPath: a[1])),
              let sig = Data(base64Encoded: a[2]),
              let pubRaw = Data(base64Encoded: a[3]),
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: pubRaw)
        else { print("INVALID_INPUT"); exit(2) }
        if pub.isValidSignature(sig, for: data) { print("VALID") } else { print("INVALID"); exit(1) }
    }
}
SWIFT
swiftc -parse-as-library -O "${BUILD_DIR}/.verify-sig.swift" -o "${VERIFY_BIN}" 2>/dev/null
RESULT=$("${VERIFY_BIN}" "${DMG}" "${SIGNATURE}" "${PUBKEY}" 2>&1) || {
    echo "错误：自检验签失败（${RESULT}）。" >&2
    echo "签名与 Info.plist 中的 SUPublicEDKey 不匹配 —— 发出去用户也无法安装。" >&2
    echo "请确认 ${KEY_FILE} 与该公钥是同一对密钥。" >&2
    rm -f "${VERIFY_BIN}" "${BUILD_DIR}/.verify-sig.swift"
    exit 1
}
rm -f "${VERIFY_BIN}" "${BUILD_DIR}/.verify-sig.swift"
echo "    验签通过（公钥 ${PUBKEY:0:16}…）"

echo "==> 提交版本号变更并打标签"
git add Resources/Info.plist
git commit -q -m "chore: 发布 v${VERSION}"
git tag -a "v${VERSION}" -m "v${VERSION}"
git push -q origin main
git push -q origin "v${VERSION}"

echo "==> 创建 GitHub Release"
REL_NOTES="${NOTES:-发布 v${VERSION}}"
gh release create "v${VERSION}" "${DMG}" \
    --repo "${REPO}" \
    --title "${APP_NAME} ${VERSION}" \
    --notes "${REL_NOTES}"

DMG_URL="https://github.com/${REPO}/releases/download/v${VERSION}/${APP_NAME}-${VERSION}.dmg"

echo "==> 生成 appcast.xml"
mkdir -p "${APPCAST_DIR}"
PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
# 转义更新说明中的 XML 特殊字符，避免破坏 feed 结构
ESCAPED_NOTES=$(printf '%s' "${REL_NOTES}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
cat > "${APPCAST_DIR}/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>ClipKeep 更新</title>
        <link>https://openseek-x.github.io/ClipKeep/appcast.xml</link>
        <description>ClipKeep 自动更新源</description>
        <language>zh-CN</language>
        <item>
            <title>${VERSION}</title>
            <pubDate>${PUBDATE}</pubDate>
            <sparkle:version>${BUILD_NUM}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <description><![CDATA[${REL_NOTES}]]></description>
            <enclosure
                url="${DMG_URL}"
                sparkle:edSignature="${SIGNATURE}"
                length="${DMG_SIZE}"
                type="application/octet-stream" />
        </item>
    </channel>
</rss>
XML
echo "    ${APPCAST_DIR}/appcast.xml"

echo "==> 发布 appcast 到 gh-pages"
TMP_PAGES=$(mktemp -d)
if git ls-remote --exit-code --heads origin gh-pages >/dev/null 2>&1; then
    git clone -q --branch gh-pages --single-branch \
        "https://github.com/${REPO}.git" "${TMP_PAGES}"
else
    # 首次发布：建立空的 gh-pages 分支
    git clone -q "https://github.com/${REPO}.git" "${TMP_PAGES}"
    git -C "${TMP_PAGES}" checkout -q --orphan gh-pages
    git -C "${TMP_PAGES}" rm -rqf . 2>/dev/null || true
fi
cp "${APPCAST_DIR}/appcast.xml" "${TMP_PAGES}/appcast.xml"
git -C "${TMP_PAGES}" config user.name "openseek-x"
git -C "${TMP_PAGES}" config user.email "271316821+openseek-x@users.noreply.github.com"
git -C "${TMP_PAGES}" add appcast.xml
git -C "${TMP_PAGES}" commit -q -m "chore: appcast 更新至 v${VERSION}"
git -C "${TMP_PAGES}" push -q origin gh-pages
rm -rf "${TMP_PAGES}"

echo ""
echo "发布完成 v${VERSION}"
echo "  Release:  https://github.com/${REPO}/releases/tag/v${VERSION}"
echo "  appcast:  https://openseek-x.github.io/ClipKeep/appcast.xml"
echo "  SHA-256:  $(shasum -a 256 "${DMG}" | awk '{print $1}')"
echo ""
echo "提示：GitHub Pages 首次启用需在仓库 Settings → Pages 选择 gh-pages 分支。"
