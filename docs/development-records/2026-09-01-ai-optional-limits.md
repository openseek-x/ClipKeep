# AI 输入输出可选限制开发记录

- 日期：2026-09-01
- 分支：`codex/ai-optional-limits`
- 风险级别：L2（外部 AI 请求参数、成本与配置兼容性）

## 1. 任务概述与技术方案

### 目标与范围

将 AI 设置中的输入/输出限制改为可选，并允许直接键入数值：

- 新配置默认不设置客户端输入字符限制。
- 新配置默认不向 Provider 发送输出 token 上限。
- 用户启用限制后可在数字文本框中输入任意正整数。
- OpenAI Responses 与 OpenAI-compatible Provider 采用相同语义。
- 旧 `settings.json` 中已有的正数限制原样保留。

### 明确非目标

- “不限制”不代表模型或进程资源真正无限。
- 不移除剪贴板单条文本 200,000 字符入库上限。
- 不移除 120 秒请求超时、512KB 流式响应硬上限或图片 2048px/2MB 限制。
- 不改变 API Key、Base URL、Provider、数据库或历史记录。

### 推荐方案

保留原有两个整数字段，以 `0` 表示关闭限制，正数表示启用限制：

- `maxInputCharacters = 0`：不执行客户端字符数 guard。
- `maxOutputTokens = 0`：请求 JSON 完全省略 `max_output_tokens` / `max_tokens`。
- 正数不再夹取到旧的 50,000 / 4,096 上限。
- 负数属于非法手工配置，回退到 12,000 / 800 建议值，避免意外放宽。

界面使用两个 Toggle。关闭时显示“不限制”；开启时展示支持键入和粘贴的正整数 TextField。
开关在当前窗口内记住最近输入值，关闭后重新开启不会丢失。

### 备选方案与取舍

- **使用极大哨兵值**：不同 Provider 可能直接拒绝，不采用。
- **改为 Optional JSON 字段**：需要额外 Codable 兼容处理，且现有字段已可用 `0` 表达，不采用。
- **完全移除资源硬边界**：可能造成成本和内存失控，不符合常驻工具的安全要求，不采用。

## 2. 实际实施与验证

### 实施步骤

1. 将 `AISettings` 两个限制默认值改为 `0`，新增 optional 计算属性。
2. 文本动作仅在正输入限制存在且超限时本地拒绝。
3. `AIRequest.maxOutputTokens` 改为可选。
4. 两种 Provider 仅在 optional 非空时写入输出限制参数。
5. 把有界 Stepper 替换为 Toggle + NumberFormatter TextField。
6. 保留旧正数配置，关闭/重新开启时恢复当前窗口最近输入值。
7. 更新 README 配置示例和实际硬边界说明。
8. 扩展自动化测试至 82 项断言。

### 修改文件

- `Sources/ClipKeep/AIModels.swift`
- `Sources/ClipKeep/AIActionViewModel.swift`
- `Sources/ClipKeep/AISettingsWindowController.swift`
- `Sources/ClipKeep/OpenAIResponsesProvider.swift`
- `Sources/ClipKeep/LocalCompatibleProvider.swift`
- `Tests/AIUnitTests.swift`
- `README.md`

### 验证命令与结果

- `./test-ai.sh`
  - 结果：82/82 断言通过。
  - 覆盖默认 0、负数回退、超大正数保留、旧数值配置兼容、settings round trip、
    两种 Provider 参数存在/省略、输入限制开/关状态和既有 AI 安全回归。
- `CLANG_MODULE_CACHE_PATH=/tmp/clipkeep-clang-cache SWIFT_MODULE_CACHE_PATH=/tmp/clipkeep-swift-cache ./build.sh`
  - 结果：arm64 / macOS 13 构建成功，无编译警告。
- `codesign --verify --deep --strict build/ClipKeep.app`
  - 结果：通过。
- `git diff --check`
  - 结果：通过。

### 未执行验证

- 未使用真实 Provider 验证省略输出参数后的具体默认输出长度；该行为由服务决定。
- 未通过原生 UI 自动化验证数字框的键入、粘贴、空串、小数、负数、超 Int 和失焦提交。
- 未执行发布、安装或 Sparkle 升级。

## 3. 问题与处理

| 问题 | 根因 | 处理 |
|---|---|---|
| Stepper 只能逐步调整且存在固定上限 | UI 将输入和约束绑定在同一个有界控件 | 改为显式限制开关和可键入的正整数 TextField |
| “不限制”容易被理解为真正无限 | 模型、Provider 和本地资源仍有物理边界 | README 与 UI 明确为“不设置客户端业务限制”，保留硬安全边界 |
| 负数若直接夹到 0 会意外放宽 | `0` 被定义为不限哨兵 | 负数回退到建议正数，不把非法值解释成不限 |
| 旧用户可能已主动配置 12,000 / 800 | 无法区分旧默认值和用户意图 | 所有旧正数原样保留，由用户显式关闭开关 |
| 关闭开关可能丢失刚输入值 | 字段以 0 表示关闭 | ViewModel 在窗口生命周期内保存最近正数，重新开启时恢复 |

## 4. 技术决策与偏差

- 实现与技术提案一致，没有引入新依赖或 Provider 分支。
- 输出不限制通过“省略字段”表达，而不是发送 `0` 或 JSON `null`，兼容 API 可选参数语义。
- 正整数不设置客户端最大值；过大的 Provider 参数可能返回 4xx，该错误走既有错误展示路径。
- NumberFormatter 仅接受正整数并使用分组符号；不限状态通过 Toggle 表达，不要求用户输入 0。

## 5. 配置变更与环境影响

`settings.json` 沿用既有键和整数类型，没有 Schema 迁移：

| 键 | 新配置默认值 | 语义 |
|---|---:|---|
| `ai.maxInputCharacters` | `0` | 0 为不设置客户端字符限制，正数为限制值 |
| `ai.maxOutputTokens` | `0` | 0 为省略 Provider 输出上限，正数写入请求 |

兼容性：

- 旧文件中的正数不变。
- 缺少整个 `ai` 对象的旧文件仍回退到新默认值。
- 负数手工配置会回退到建议正数。
- 不涉及 secrets、Keychain、ATS、环境变量或构建配置变化。

## 6. SQL、Schema 与数据迁移

本次没有 SQL、数据库 Schema 变更、数据迁移或回滚语句。

剪贴板历史数据库完全不变；设置文件键名与类型也不变，因此不需要配置迁移脚本。

## 7. 剩余风险、后续与回滚

### 剩余风险

- Provider 省略输出上限后的默认值各不相同，仍可能受账户、模型或网关策略限制。
- 输入超过模型上下文时，Provider 可能返回 4xx；ClipKeep 不在客户端自动截断。
- 数字 TextField 的极端输入体验仍需手工验证。
- 旧用户保存的正数限制不会自动关闭，需要在设置中手动关闭对应 Toggle。

### 回滚

- 用户侧可重新启用限制并输入原值 12,000 / 800，无需降级应用。
- 代码回滚可恢复旧默认值、Stepper 和必填请求参数；配置中的 `0` 在旧代码中会被旧
  `validated()` 夹取到 500 / 64，因此不会导致解码失败，但会恢复为有限模式。
- 无数据库回滚或数据恢复步骤。
