# ClipKeep

macOS 剪贴板历史工具。复制即自动记录，快捷键唤出，一键取回。

[![下载](https://img.shields.io/github/v/release/openseek-x/ClipKeep?label=%E4%B8%8B%E8%BD%BD&style=flat-square)](https://github.com/openseek-x/ClipKeep/releases/latest)
[![许可](https://img.shields.io/github/license/openseek-x/ClipKeep?label=%E8%AE%B8%E5%8F%AF&style=flat-square)](LICENSE)
![平台](https://img.shields.io/badge/macOS-13.0%2B%20(arm64)-lightgrey?style=flat-square)

**[⬇ 下载最新版本 (.dmg)](https://github.com/openseek-x/ClipKeep/releases/latest)** — 约 1MB，核心功能装完即用，无需任何系统授权。

## 特点

- **核心零授权**：剪贴板记录、搜索和快捷键不需要辅助功能、输入监听或通知权限。
- **无感记录**：复制任何内容自动入库，无提示、无弹窗、不打断工作。
- **不抢焦点**：面板浮在最上层但不激活自身，取回内容后可直接在原位置 `Cmd+V`。
- **密码不入库**：识别密码管理器的敏感标记与来源，自动跳过。
- **可选 AI 动作**：仅在你右键选择后处理单条文本或图片，默认关闭，不自动上传历史。
- **自动更新**：内置 Sparkle，更新包经 EdDSA 签名校验，由你确认后才安装。

## 安装

### 方式一：下载 DMG（推荐）

从 [Releases](https://github.com/openseek-x/ClipKeep/releases/latest) 下载 `.dmg`，
打开后把 ClipKeep 拖到「应用程序」文件夹。

### 方式二：自行构建

```bash
git clone https://github.com/openseek-x/ClipKeep.git
cd ClipKeep
./fetch-sparkle.sh                  # 下载 Sparkle 框架（校验官方包 SHA-256）
./build.sh                          # 产出 build/ClipKeep.app
cp -R build/ClipKeep.app /Applications/

# 或连 DMG 一起打包
./package-dmg.sh                    # 产出 build/ClipKeep-1.0.0.dmg
```

构建只需 Command Line Tools（`xcode-select --install`），不需要完整 Xcode。

### 首次打开（两种方式都需要）

首次打开时 Gatekeeper 会拦截（本 app 为 ad-hoc 签名，未经 Apple 公证，
`spctl` 评估结果为 `rejected`）。两种方式之一即可：

- 在 Finder 中**右键点击** ClipKeep.app → **打开** → 在弹出对话框中再点「打开」
- 或执行 `xattr -d com.apple.quarantine /Applications/ClipKeep.app`

之后就能正常双击打开。DMG 内附有同样内容的说明文件。

## 使用

| 操作 | 方式 |
|---|---|
| 记录 | 自动。正常 `Cmd+C` 即可，无需任何额外动作 |
| 唤出面板 | `Cmd+Shift+V` |
| 选择 | `↑` `↓` |
| 取回到剪贴板 | `Enter`（然后回原位置按 `Cmd+V` 粘贴） |
| 关闭面板 | `Esc` |
| 搜索 | 面板打开后直接输入 |
| 收藏 / 删除单条 | 选中或悬停记录 → 行尾星标 / 删除按钮，也可右键 |
| AI 总结 / 翻译 / 图片理解等 | 选中或悬停记录 → 行尾 AI 按钮，也可右键「AI 处理」 |

每行尾部为固定操作区：选中行始终显示 AI、收藏、删除，其他行悬停时显示；已收藏条目的
星标保持可见。菜单栏图标下可切换「记录图片」「开机自动启动」，以及清空历史。

## 默认行为

| 项 | 默认值 |
|---|---|
| 唤出快捷键 | `Cmd+Shift+V` |
| 文本保留 | 200 条 / 7 天，先到者生效 |
| 图片保留 | 50 条 / 7 天，与文本独立计数 |
| 收藏记录 | 永不自动清理，仅可手动删除 |
| 单条文本上限 | 200,000 字符，超出截断 |
| 单张图片上限 | 2MB（PNG 重编码，超限自动降分辨率） |

## 自动更新

内置 [Sparkle](https://sparkle-project.org)，默认每 24 小时检查一次。发现新版本会弹出更新面板，
**由你确认后才下载安装** —— 不静默替换本机可执行代码。

菜单栏可随时「检查更新…」，也可关闭「自动检查更新」。

更新包用 **EdDSA (Ed25519) 签名**，公钥硬编码在 app 的 `Info.plist` 中，
私钥仅存于维护者本机。即使本仓库或 GitHub 账号被攻破，攻击者没有私钥
也无法让已安装的 ClipKeep 接受其构造的更新包。

不发送任何系统信息或使用统计（`SUSendProfileInfo` 为 false）。

## AI 功能（可选）

AI 默认关闭。通过菜单栏「AI 设置…」选择服务、模型并启用后，可在记录的右键菜单中
处理文本或图片。文本支持总结、翻译、润色、解释和提取待办；图片支持 OCR、描述、
总结、翻译可见文字、提取关键信息和自定义指令。

- **按需发送**：只发送你当次明确选择的文本或图片；不会后台分析或上传全部历史。
- **两种服务**：支持 OpenAI Responses API，也支持本机或远程的
  OpenAI-compatible Chat Completions 服务（例如本机 Ollama）。处理图片时配置的模型
  必须支持视觉输入；本机默认建议为 `qwen3-vl:4b`（需先在 Ollama 中下载）。
- **密钥保护**：API Key 存在 macOS 钥匙串，并按 `scheme://host:port` 隔离；更换服务
  主机后必须使用该主机自己的 Key，不写入 `settings.json`、SQLite 或日志。
- **传输限制**：远程服务必须使用 HTTPS；HTTP 只允许 `localhost`、`127.0.0.1`
  或 `::1`，跨域重定向会被拒绝。
- **本地网络权限**：本机回环服务不需要额外配置；若连接另一台局域网设备上的模型，
  macOS 15+ 会请求“本地网络”权限，拒绝后仅该服务不可用。
- **图片上传限制**：图片先在本地重新编码为最长边不超过 2048px、最大 2MB 的 PNG
  副本，不上传数据库中的原始字节；每张图片每次发送前都显示服务、模型和副本大小，
  必须再次确认。
- **敏感信息拦截**：私钥、API Token、JWT 等高风险内容直接拒绝发送；图片先用 macOS
  Vision 在本地 OCR，再扫描可见文字。OCR 与正则都可能漏检，只能降低误传风险，
  不能保证识别全部敏感信息。
- **结果可控**：结果先在本地预览；「复制结果」不会自动写入历史，只有点击
  「保存到历史」才会入库。

OpenAI 请求使用 `store=false`，但这不等于服务端零留存：默认仍可能按服务方政策
保留安全日志，图片输入也可能接受服务方的内容安全扫描。详见
[OpenAI 数据控制说明](https://developers.openai.com/api/docs/guides/your-data)和
[图片输入说明](https://developers.openai.com/api/docs/guides/images-vision)。
OpenAI API 也受[支持国家和地区](https://developers.openai.com/api/docs/supported-countries)
限制；不适用时请使用合法可用的兼容服务或本机模型。

## 维护者：发布新版本

```bash
./release.sh 1.0.1 "本次更新说明"
```

脚本会依次完成：同步版本号 → 构建 → 打包 DMG → EdDSA 签名 → 自检验签 →
打标签推送 → 创建 GitHub Release → 生成并发布 appcast 到 `gh-pages`。

工作区不干净时会拒绝发布，确保发出的包能对应到确定的提交。

首次发布前需生成签名密钥：

```bash
./generate-signing-key.sh     # 私钥写入 ~/.clipkeep/signing.key（权限 0600）
# 按输出提示把公钥写入 Resources/Info.plist 的 SUPublicEDKey
```

私钥存文件而非钥匙串：`sign_update` 每次访问钥匙串都可能弹授权对话框，
后台脚本无法应答会导致发布流程无限挂死（已实测）。文件方式经
`--ed-key-file -` 从 stdin 读取，全程无交互。私钥在仓库之外，
权限必须为 600，`release.sh` 会检查。

**丢失私钥意味着无法再为已安装用户推送更新** —— 他们内嵌的公钥无法匹配
新密钥。请离线备份。同理，轮换密钥后旧版本用户只能手动下载新版。

## 配置

配置文件：`~/Library/Application Support/ClipKeep/settings.json`（权限 0600）

```json
{
  "maxTextItems": 200,
  "maxImageItems": 50,
  "maxAgeDays": 7,
  "captureImages": true,
  "hotKeyCode": 9,
  "hotKeyModifiers": 768,
  "blockedSourcePrefixes": [],
  "launchAtLogin": false,
  "ai": {
    "enabled": false,
    "provider": "openAI",
    "baseURL": "https://api.openai.com/v1",
    "model": "gpt-5.6-luna",
    "maxInputCharacters": 12000,
    "maxOutputTokens": 800,
    "requestTimeoutSeconds": 45,
    "customInstruction": ""
  }
}
```

`blockedSourcePrefixes` 可追加自定义的来源黑名单（bundle id 前缀），
例如 `["com.mycompany.internal"]` 会让该 app 复制的内容不被记录。

改完配置需重启 ClipKeep 生效。数值会被夹取到安全区间，写入极端值不会导致失控。

## 隐私说明

**历史记录以明文存储在本地 SQLite 数据库中**（`~/Library/Application Support/ClipKeep/history.sqlite`，权限 0600，仅当前用户可读）。这是剪贴板管理器的固有特性，不是本工具的疏漏 —— 要能把内容还给你，就必须能读出它。本工具**不加密**该数据库，请知悉这一点。

**剪贴板数据默认完全留在本机，不上传、不同步。** 默认网络活动只有自动更新：
向 `openseek-x.github.io` 请求 appcast、向 GitHub Releases 下载更新包；该请求不携带
任何剪贴板内容，也不发送系统信息或使用统计（`SUSendProfileInfo` 为 false）。
只有在你主动启用 AI、选择某条记录并确认相应操作时，该条文本或图片副本才会发送到
你配置的服务；图片会额外逐次确认。
关闭 AI 与「自动检查更新」后，应用不会主动联网。

**密码过滤**采用三层独立判据，任一命中即跳过记录：

1. 剪贴板 `org.nspasteboard.ConcealedType` / `AutoGeneratedType` 标记（密码管理器通用约定）
2. `org.nspasteboard.TransientType` 临时内容标记
3. 来源 app bundle id 黑名单：1Password、Bitwarden、KeePassXC、钥匙串访问、Enpass、Dashlane、LastPass、Keeper 等

第 1 层依赖密码管理器自身正确设置标记。若你使用的密码工具不遵循该约定且不在黑名单内，请把它的 bundle id 加入 `blockedSourcePrefixes`。查看 bundle id：

```bash
osascript -e 'id of app "你的密码管理器名称"'
```

## 已知限制

- **轮询间隔 0.3 秒**：连续复制间隔快于 0.3 秒时，中间的内容可能漏记。macOS 不提供剪贴板变更通知 API，轮询是唯一途径。
- **不自动粘贴**：取回只写入剪贴板，需你自己按 `Cmd+V`。自动粘贴需要辅助功能授权（等同模拟键盘输入），与零授权设计相悖。
- **不保留富文本样式**：只存纯文本与图片，粘贴后样式随目标应用。
- **不记录文件路径**：复制的文件不会被记录。
- **仅 Apple Silicon**：`build.sh` 目标为 arm64。Intel 机器需改 `-target x86_64-apple-macosx13.0`。
- **未经公证**：无付费开发者账号，只能 ad-hoc 签名，故有上述 Gatekeeper 步骤。
- **AI 需自行配置服务**：OpenAI 模式需要用户自己的 API Key；本地兼容模式需要另行
  安装并启动模型服务。图片处理要求模型支持视觉输入；不同兼容服务对 Base64 图片和
  `detail` 参数的支持可能不同。AI 服务不可用、限流或超时时不会影响剪贴板记录与搜索。
- **自动更新未端到端验证**：签名与验签链路已实测（篡改包被正确拒绝），但本次任务
  尚未用已安装的 1.0.1 完成一次发现并安装 1.1.0 的真实升级；发布后仍需人工验收。

## 卸载

```bash
pkill -f ClipKeep
rm -rf /Applications/ClipKeep.app
rm -rf ~/Library/Application\ Support/ClipKeep    # 删除全部历史记录
```

若开启过开机自启，先在菜单栏中关闭，或到「系统设置 → 通用 → 登录项」中移除。

## 环境要求

- macOS 13.0+（开发验证于 macOS 15.7.7 / arm64）
- 构建需 Swift 6.1+（Command Line Tools 即可，无需完整 Xcode）
