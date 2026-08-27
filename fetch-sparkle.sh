#!/bin/bash
# 获取 Sparkle 框架与发布工具
#
# 不把 3MB 的框架二进制提交进仓库：无来源可查的二进制 blob 对使用者不透明，
# 也无法验证是否被篡改。改为从官方 Release 下载并校验 SHA-256。
set -euo pipefail

cd "$(dirname "$0")"

# 固定版本与校验和。升级时同时更新这两个值，并在提交信息中说明。
SPARKLE_VERSION="2.9.6"
SPARKLE_SHA256="52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"
URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"

if [[ -d "Frameworks/Sparkle.framework" && -x "Tools/sign_update" ]]; then
    echo "Sparkle 已就位（Frameworks/Sparkle.framework）"
    echo "如需重新获取，先删除 Frameworks/Sparkle.framework 与 Tools/ 下的工具。"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

echo "==> 下载 Sparkle ${SPARKLE_VERSION}"
curl -fsSL -o "${TMP}/sparkle.tar.xz" "${URL}"

echo "==> 校验 SHA-256"
ACTUAL=$(shasum -a 256 "${TMP}/sparkle.tar.xz" | awk '{print $1}')
if [[ "${ACTUAL}" != "${SPARKLE_SHA256}" ]]; then
    echo "错误：校验和不匹配，拒绝使用该文件。" >&2
    echo "  期望: ${SPARKLE_SHA256}" >&2
    echo "  实际: ${ACTUAL}" >&2
    exit 1
fi
echo "    校验通过"

echo "==> 解压"
tar -xJf "${TMP}/sparkle.tar.xz" -C "${TMP}"

echo "==> 安装框架与工具"
mkdir -p Frameworks Tools
rm -rf Frameworks/Sparkle.framework
cp -R "${TMP}/Sparkle.framework" Frameworks/
for t in generate_keys sign_update generate_appcast; do
    cp "${TMP}/bin/${t}" "Tools/${t}"
    chmod +x "Tools/${t}"
done

echo ""
echo "完成。框架 $(du -sh Frameworks/Sparkle.framework | awk '{print $1}')，工具 $(du -sh Tools | awk '{print $1}')"
echo ""
echo "首次发布前需生成签名密钥（私钥存入钥匙串，公钥写进 Info.plist）："
echo "  Tools/generate_keys"
echo ""
echo "然后导出私钥供 release.sh 无交互使用（会弹钥匙串对话框，点「始终允许」）："
echo "  mkdir -p ~/.clipkeep && chmod 700 ~/.clipkeep"
echo "  Tools/generate_keys -x ~/.clipkeep/signing.key"
echo "  chmod 600 ~/.clipkeep/signing.key"
