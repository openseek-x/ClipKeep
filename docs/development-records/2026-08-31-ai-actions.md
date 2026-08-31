# ClipKeep 可选 AI 文本与图片动作 —— 开发记录

- 日期：2026-08-31
- 分支：`codex/ai-actions`
- 风险级别：L2（外部 AI 依赖、敏感剪贴板数据、凭据管理）

## 1. 任务概述、范围与实施方案

### 目标

为 ClipKeep 增加用户明确触发的 AI 文本与图片处理能力。文本支持总结、翻译、润色、
解释和提取待办；图片支持 OCR、描述、总结、翻译可见文字和提取关键信息，同时保留
应用默认本地、零授权、轻量的产品定位。

### 范围

- 单条文本或图片记录的 AI 操作。
- OpenAI Responses API 与 OpenAI-compatible Chat Completions 两种 Provider。
- 流式结果预览、复制结果、用户确认后保存到历史。
- 图片在本地生成最长边 2048px、最大 2MB 的无附加元数据 PNG 上传副本。
- 图片上传前使用 macOS Vision 本地 OCR 扫描可见敏感文字，并逐次确认。
- API Key 的 macOS Keychain 存储。
- 本地敏感信息扫描、输入输出与网络边界。
- AI 设置窗口、配置持久化、README 与自动化测试。

### 非目标

- 不自动分析或上传剪贴板历史。
- 不处理多选记录、语义搜索、图片生成、图片编辑或自动 OCR 索引。
- 不建设托管后端、账号、计费或跨设备同步。
- 不向模型开放工具调用、命令执行、文件或网络访问。
- 不集成 Apple Foundation Models 或随应用分发本地模型。

### 实施方案

新增 `AIProvider` 抽象，由 `OpenAIResponsesProvider` 和
`LocalCompatibleProvider` 实现。文本直接作为请求输入；图片使用 Base64 data URL，
由 `ImageCodec` 生成受限副本，`ImageTextScanner` 在本地执行 OCR 安全扫描。
`AIActionViewModel` 负责用户动作、安全检查、逐次确认、取消、流式状态与结果操作；
`AISettingsWindowController` 管理非敏感设置和 Keychain 凭据。

OpenAI 请求使用 `store=false`、`stream=true`、`max_output_tokens` 和
`tool_choice=none`。兼容 Provider 使用流式 Chat Completions。Swift 端直接使用
`URLSession`，没有新增第三方依赖。

## 2. 实际实施与验证

### 实施步骤

1. 按工程规则从本地 `master` 创建 `codex/ai-actions`；仓库原先只有 `main`，因此先让
   本地 `master` 指向当前 `main` 提交，没有修改远端分支。
2. 新增 AI 配置、动作、请求、错误、结果状态与 Provider 接口。
3. 新增 OpenAI Responses 与本地/远程兼容 Provider，实施 HTTPS/回环 HTTP 限制、
   同源重定向、临时 URLSession 与 512KB 流式响应硬上限。
4. 新增 Keychain 凭据存储和本地敏感信息扫描。
5. 在历史右键菜单接入 AI 动作，在面板中接入确认、流式结果、复制与保存。
6. 新增 AI 设置窗口和菜单入口；旧配置缺少 `ai` 字段时保持兼容且默认关闭。
7. 修复 `SettingsStore.save` 首次保存可能只留下临时文件的问题，并加入回归测试。
8. 新增 `test-ai.sh` 并最终扩展至 67 项断言；更新 README 隐私与配置说明。
9. 扩展图片输入：新增专用图片动作、ImageIO 缩略解码、Vision OCR 安全扫描、逐次上传
   确认和两种 Provider 的多模态 Base64 请求格式。
10. 安全复核后将 Keychain 凭据按 origin 隔离，补充实际目的主机展示、OCR 多语言、图片
    任务取消传播、本地网络 ATS/权限声明和设置窗口焦点恢复。
11. 根据实际界面反馈增加行尾操作区：选中或悬停行显示 AI 菜单、收藏和删除图标；把
    正文点击区域与按钮区分离，避免点击操作按钮时误触复制并关闭面板；隐藏按钮同时
    从辅助功能焦点树移除，操作未选中行时先同步选中状态。
12. 修复 AI 设置文本框不能使用 `Cmd+V`：安装标准 AppKit 应用/编辑主菜单，让撤销、
    剪切、复制、粘贴、全选通过 responder chain 作用于当前输入控件。

### 验证命令和结果

- `./test-ai.sh`
  - 结果：通过，67/67 断言。
  - 覆盖：配置夹取、旧配置兼容、首次/覆盖保存、0600 权限、URL 策略、同源重定向、
    敏感信息识别、动作媒体类型、图片缩放与字节上限、两种文本/图片请求体、
    `store=false`、禁用工具、两种流事件和错误事件，以及图片准备、逐次确认、OCR
    高/中风险、OCR 失败、缺失原图、取消竞态状态机，以及标准编辑菜单与 `Cmd+V`
    responder 绑定。
- `CLANG_MODULE_CACHE_PATH=/tmp/clipkeep-clang-cache SWIFT_MODULE_CACHE_PATH=/tmp/clipkeep-swift-cache ./build.sh`
  - 结果：通过，arm64/macOS 13 优化构建完成；Sparkle 内部组件、framework 与外层 app
    均完成 ad-hoc 重签；`codesign --verify --deep --strict` 通过。
- `bash -n build.sh fetch-sparkle.sh generate-signing-key.sh package-dmg.sh release.sh test-ai.sh`
  - 结果：通过。
- `plutil -lint Resources/Info.plist`
  - 结果：通过。
- `git diff --check`
  - 结果：通过。

### 未执行验证

- 未调用真实 OpenAI API：环境未提供用户 API Key，且不能虚构外部验证。
- 未调用真实本地多模态模型服务：环境没有已配置的 OpenAI-compatible 视觉模型。
- 未写入真实用户 Keychain：避免在验证阶段留下凭据或测试项；已编译并审查 Security
  framework 调用，仍需在真实签名/更新链路中验证访问连续性。
- 尝试通过 Computer Use 启动并读取本地构建的菜单栏 app，但自动化服务以
  `timeoutReached` 结束，未取得可访问性状态。因此不能宣称 GUI 已验证；图片确认、
  右键菜单、设置窗口焦点和流式布局仍需真实运行中手工验收。随后用完整 build 可执行
  路径尝试清理可能启动的进程，但受控环境无法读取进程表（`sysmond service not found`）；
  未使用会误伤 `/Applications` 安装版的宽泛 `killall`。

## 3. 问题、根因与处理

| 问题 | 根因 | 处理 |
|---|---|---|
| 初次类型检查无法写 `~/.cache/clang` | 受控环境禁止写默认模块缓存 | 将 Clang/Swift 模块缓存显式指向 `/tmp`；后续类型检查和构建通过 |
| 工程规则要求从 `master` 建分支，但仓库只有 `main` | 分支命名约定与仓库现状不一致 | 本地创建指向当前 `main` 的 `master`，再建立任务分支；未推送或改动远端 |
| `SettingsStore.save` 首次写入可能不生成目标文件 | `replaceItemAt` 只适用于目标已存在，且原实现忽略错误 | 首次保存走 `moveItem`，已有文件走原子替换；增加首次/覆盖保存回归测试 |
| 连续触发或关闭面板时旧任务可能覆盖新状态 | 取消为协作式，旧 Task 可能在取消后再写状态 | 为每轮生成增加 UUID，只有当前 generation 才能更新或清理状态 |
| SSE 按行读取可能先缓冲无界超长行 | 系统 `AsyncLineSequence` 需要看到换行才交付数据 | 改为逐字节累计，累计网络数据达到 512KB 立即终止 |
| 低熵超大图压缩字节小但完整解码内存大 | 仅按 PNG 字节限制不能约束像素网格 | AI 上传路径改用 ImageIO 缩略解码，源图超过 1 亿像素拒绝，输出限制为 2048px/2MB |
| 图片正则无法直接扫描 | 密钥和密码可能出现在截图像素中 | 上传前用 Vision 本地 OCR 后复用敏感扫描；由于 OCR 会漏检，所有图片仍逐次确认 |
| API Key 可能随自定义 Base URL 发往错误主机 | 初版 Keychain 条目只按 Provider 区分 | Keychain account 改为 Provider + 规范化 origin；主机、协议或端口变化时清空并重新读取对应凭据；确认文案显示实际 origin |
| macOS 14+ 默认可能阻止本地 IP 的 HTTP | ATS 不再默认允许 IP 地址明文连接 | `NSAllowsLocalNetworking=true`，但代码仍只允许回环 HTTP，不开启任意加载 |
| macOS 15 局域网服务需要用户授权 | Local Network Privacy 覆盖直接单播连接 | 加入 `NSLocalNetworkUsageDescription`；仅用户配置并访问 LAN 模型时触发，拒绝不影响核心功能 |
| OCR 默认偏向英文且可能纠正 Token | Vision 默认不开语言自动检测，语言纠错会改变随机字符串 | 开启 `automaticallyDetectsLanguage`，关闭语言纠错；仍不把 OCR 当成完整安全边界 |
| 设置窗口关闭后面板失焦抑制仍持续 | 初版使用固定 300 秒保护窗口 | 设置窗口关闭时立即恢复面板的正常失焦关闭行为 |
| 原生 UI 自动化无法取得状态 | Computer Use 服务启动菜单栏 app 时超时 | 不把构建成功等同 UI 成功；记录为未验证并保留人工验收项 |
| AI 入口只有右键菜单，用户无法发现 | 列表行没有可见操作 affordance | 增加固定宽度行尾操作区；选中/悬停时显示 AI、收藏、删除，收藏星标持续可见，保留右键兼容路径 |
| 透明隐藏按钮仍可能被 VoiceOver 聚焦 | `opacity(0)` 不会自动移出辅助功能树 | 隐藏时同步禁用并设置 `accessibilityHidden`；收藏星标可见时保持可访问 |
| 设置窗口文本框不能可靠使用 `Cmd+V` | 程序完全手工启动 `NSApplication`，没有标准 Edit 主菜单向 first responder 路由 `paste:` | 增加原生应用/编辑菜单，所有编辑命令 target 为 nil，交由 AppKit responder chain 处理 |
| OpenAI 不适合成为唯一 Provider | API 地区、数据政策、网络可用性和成本存在差异 | Provider 抽象 + 兼容服务；模型、地址均配置化；默认不开启 |

## 4. 决策、困难与偏差

- 选择 BYOK 而不是在客户端内嵌维护者密钥。客户端内嵌密钥无法保密，也无法可靠限制滥用。
- 选择 `URLSession` 而不是社区 Swift SDK。OpenAI 官方没有 Swift SDK，当前功能只需两个
  稳定 HTTP 接口，引入第三方依赖的供应链与版本成本高于收益。
- 选择用户右键显式触发，而不是自动分类或向量化全部历史。剪贴板含密码、Token、客户资料
  等高敏感信息，默认后台上传与现有隐私承诺不兼容。
- 图片不直接上传数据库字节：使用 ImageIO 生成受限 PNG 副本，既约束内存、带宽和 token，
  也移除可能的附加元数据。为避免把 OCR 当成可靠安全边界，每次图片上传仍要求确认。
- 行尾按钮采用固定 76pt 操作区，显隐不改变摘要宽度；AI 使用菜单而非直接执行默认动作，
  避免用户误触后立即发送内容。
- 文本编辑快捷键使用 AppKit 标准主菜单和 responder chain，不添加键盘事件监听，也不直接
  读取剪贴板；因此 Base URL、模型和 SecureField 的行为与普通 macOS 输入框一致。
- Apple Foundation Models 未纳入本次范围，因为需要 macOS 26/Xcode 26和兼容设备，
  会破坏项目当前 macOS 13 + Command Line Tools 的兼容目标。
- 原提案提到结构化输出，但 MVP 动作为纯文本转换，没有必须解析的结构，因此不引入 JSON
  Schema；若后续实现结构化待办或标签，再按具体数据模型使用 Structured Outputs。

## 5. 配置变更

### `settings.json`

新增可选 `ai` 对象；旧文件缺少该键时正常解码，默认 AI 关闭：

| 键 | 默认值 | 行为与环境影响 |
|---|---:|---|
| `enabled` | `false` | 只有启用后右键动作才可发送请求 |
| `provider` | `openAI` | `openAI` 或 `localCompatible` |
| `baseURL` | `https://api.openai.com/v1` | 远程必须 HTTPS；HTTP 只允许回环地址 |
| `model` | `gpt-5.6-luna` | 请求模型；可按 Provider 自定义 |
| `maxInputCharacters` | `12000` | 夹取到 500–50000 |
| `maxOutputTokens` | `800` | 夹取到 64–4096 |
| `requestTimeoutSeconds` | `45` | 夹取到 5–120 秒 |
| `customInstruction` | `""` | 最多 2000 字符；空值时自定义动作不可执行 |

切换到本地兼容 Provider 时界面默认模型为 `qwen3-vl:4b`，该模型同时支持文本与图片；
用户已保存的自定义模型名不被自动改写。

API Key 不进入配置文件，存于 Keychain service `com.clipkeep.app.ai`，account 为
`Provider|scheme://host[:port]`，路径变化可复用，同一 Provider 更换 origin 不会复用。
accessible 属性为 `AfterFirstUnlockThisDeviceOnly`。当前开发版遗留的 Provider-only 条目
不会自动读取或迁移，因为无法证明它属于哪个 origin；用户重新保存 Key 时会清理该旧条目。

### 构建配置

- `build.sh` 新增 `Security.framework`、`ImageIO.framework`、`Vision.framework` 链接及新增
  Swift 源文件。
- `Info.plist` 新增 `NSAppTransportSecurity.NSAllowsLocalNetworking=true`，允许项目默认的
  回环 HTTP 模型地址；未启用 `NSAllowsArbitraryLoads`，远程仍要求 HTTPS。
- `Info.plist` 新增 `NSLocalNetworkUsageDescription`。macOS 15+ 只有用户实际连接另一台
  局域网设备的模型服务时才可能弹出权限；默认关闭 AI，不影响剪贴板核心功能。
- 未修改 entitlements 或 Sparkle 配置。

## 6. SQL、Schema 与数据迁移

本次无 SQL、Schema 或数据迁移，数据库表结构不变。

用户点击“保存到历史”时复用既有 `ClipStore.upsert`：正文按 SHA-256 去重，来源标记为
`com.clipkeep.app.ai`。复制结果只写剪贴板并通知监听器跳过自触发，不自动入库。

## 7. 剩余风险、后续与回滚

### 剩余风险

- 正则扫描只能降低误传风险，无法识别全部秘密或个人信息；UI 已明确提示。
- Vision OCR 可能漏掉小字、手写内容或复杂背景中的敏感信息，图片确认是必要的第二道防线。
- OpenAI `store=false` 不等于零留存，仍受服务方安全日志和账户数据控制政策约束。
- OpenAI-compatible 服务对视觉模型、Base64 data URL、`detail` 和 SSE 的兼容程度不完全
  一致；当前实现覆盖 OpenAI 标准格式，非兼容实现会返回服务错误但不影响历史功能。
- 兼容服务若忽略 `maxOutputTokens`，客户端会在累计流数据达到 512KB 时主动终止。
- ad-hoc 签名更新后 Keychain ACL 的实际体验尚未端到端验证。
- macOS 15 的 Local Network Privacy 用代码签名跟踪应用身份；本项目使用 ad-hoc 签名，
  局域网权限在不同构建间的连续性需真实发布环境验证。
- 当前默认模型是配置默认值，服务方模型生命周期变化后可能需要用户调整或版本更新。

### 后续工作

- 真实运行验收设置窗口、右键菜单、取消、复制和保存。
- 用测试项目 Key 和本机模型分别跑一次端到端流式请求。
- 在 macOS 14/15 分别验证 `127.0.0.1`、`localhost`、`::1`，并在 macOS 15 验证 LAN
  模型的权限允许、拒绝和重新打开流程。
- 发布下一个签名版本后验证升级前后 Keychain 凭据可读。
- 有真实需求后再评估多选、语义搜索和 Apple Foundation Models 条件集成。

### 回滚

- 代码回滚：移除新增 AI 文件和界面入口，恢复 `Settings`、`AppDelegate`、历史视图与
  `build.sh` 的相关改动即可；数据库不需要回滚。
- 用户侧降级：在 AI 设置中关闭 `enabled` 即恢复默认离线行为。
- 凭据清理：在 AI 设置中清空对应 API Key 并保存，或从 macOS“钥匙串访问”删除
  service 为 `com.clipkeep.app.ai` 的项目。
- 配置中的未知 `ai` 字段不会影响旧版本 JSON 解码，因为 Swift `Codable` 默认忽略未知键。
