#!/bin/bash
# 生成 Sparkle 更新签名用的 Ed25519 密钥对
#
# 与 Sparkle 自带的 generate_keys 的区别：后者把私钥存入钥匙串，而钥匙串
# 每次访问都可能弹出授权对话框；该对话框无法在非交互环境（CI、后台脚本）
# 应答，会导致发布流程无限挂死（实测确认）。
#
# 本脚本直接把私钥写入仓库之外的文件（权限 0600），发布时经
# `sign_update --ed-key-file -` 从 stdin 读取，全程无需钥匙串交互。
#
# 私钥格式为 32 字节种子的 base64，与 Sparkle 的新格式兼容。
set -euo pipefail

cd "$(dirname "$0")"

KEY_FILE="${CLIPKEEP_SIGNING_KEY:-$HOME/.clipkeep/signing.key}"
KEY_DIR="$(dirname "${KEY_FILE}")"

if [[ -f "${KEY_FILE}" ]]; then
    echo "错误：${KEY_FILE} 已存在。" >&2
    echo "" >&2
    echo "覆盖现有私钥会使所有已发布版本无法再收到更新 —— 旧版本内嵌的公钥" >&2
    echo "与新私钥不匹配，验签必然失败。如确认要轮换密钥，请先手动备份并删除：" >&2
    echo "  mv ${KEY_FILE} ${KEY_FILE}.old" >&2
    echo "" >&2
    echo "轮换后必须把新公钥写入 Resources/Info.plist 的 SUPublicEDKey，" >&2
    echo "且已安装旧版本的用户只能手动下载新版，无法自动更新过去。" >&2
    exit 1
fi

command -v swiftc >/dev/null || { echo "错误：需要 swiftc" >&2; exit 1; }

mkdir -p "${KEY_DIR}"
chmod 700 "${KEY_DIR}"

TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

cat > "${TMP}/genkey.swift" <<'SWIFT'
import Foundation
import CryptoKit

@main struct G {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 2 else {
            FileHandle.standardError.write(Data("用法: genkey <私钥输出路径>\n".utf8))
            exit(1)
        }
        let priv = Curve25519.Signing.PrivateKey()
        let seedB64 = priv.rawRepresentation.base64EncodedString()
        let pubB64 = priv.publicKey.rawRepresentation.base64EncodedString()
        do {
            // 先以 0600 创建空文件再写入，避免出现短暂的宽权限窗口
            let fm = FileManager.default
            fm.createFile(atPath: args[1], contents: Data(),
                          attributes: [.posixPermissions: 0o600])
            try seedB64.write(to: URL(fileURLWithPath: args[1]),
                              atomically: false, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: args[1])
        } catch {
            FileHandle.standardError.write(Data("写入失败: \(error)\n".utf8))
            exit(1)
        }
        // 只输出公钥。私钥绝不写 stdout —— 会落入终端历史，
        // 而 ClipKeep 自身正在记录剪贴板。
        print(pubB64)
    }
}
SWIFT

swiftc -parse-as-library -O "${TMP}/genkey.swift" -o "${TMP}/genkey" 2>/dev/null

PUBKEY=$("${TMP}/genkey" "${KEY_FILE}")
PERM=$(stat -f%Sp "${KEY_FILE}")

echo "密钥已生成。"
echo ""
echo "  私钥: ${KEY_FILE}  (权限 ${PERM}，请勿提交、勿分享、建议离线备份)"
echo "  公钥: ${PUBKEY}"
echo ""
echo "下一步：把公钥写入 Resources/Info.plist"
echo ""
echo "  /usr/libexec/PlistBuddy -c 'Set :SUPublicEDKey ${PUBKEY}' Resources/Info.plist"
echo ""
echo "注意：丢失私钥意味着无法再为已安装的用户发布更新（他们内嵌的公钥"
echo "无法匹配新密钥）。请备份到安全的离线位置。"
