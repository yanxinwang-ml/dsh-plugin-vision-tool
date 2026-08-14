# dsh-plugin-vision-tool

给纯文本 DeepSeek Harness 模型加识图能力的 Cordis 宿主插件：注册 `analyze_image` 工具，把图片识别路由到**独立的视觉模型**（默认智谱 GLM-4.6V-Flash），让 DeepSeek 等纯文本模型的会话也能"看图"。

> 核心思路：**视觉能力不一定长在模型上，也可以长在 harness 上。** 图片只在这个工具内部流向视觉模型，会话模型本身不需要声明支持图片输入。

## 功能

- 注册模型工具 `analyze_image(file_path, question?)`
- 从会话工作区读取 PNG / JPEG / WebP / GIF 图片
- 经 DSH 附件服务校验、内容寻址存储（与用户上传图片同一生命周期）
- 通过 Harness 自身的 `ctx.llm` 调用视觉模型，返回文字描述（**零外部依赖**，复用 DSH 的凭据/附件/沙箱）
- 会话模型**无需**支持图片：DeepSeek 文本模型会话直接可用
- 对瞬时限流（HTTP 429 / 智谱 1305"访问量过大"）自动退避重试（最多 4 次）
- provider / model 通过插件配置可换（默认 `zhipu` / `glm-4.6v-flash`）

## 工作原理

```
用户: 识别 xxx.png
  │
  ▼
DeepSeek 会话（文本模型，无需多模态）
  │ 调用 analyze_image 工具
  ▼
宿主插件: 读文件 → ctx.attachments 校验存储 → ctx.llm.stream({provider: zhipu, model: glm-4.6v-flash, 图片消息})
  │
  ▼
智谱 GLM-4.6V-Flash 视觉模型 → 文字描述 → 返回给 DeepSeek 会话
```

## 安装

### 方式一：安装脚本（推荐）

```powershell
# Windows
.\install.ps1 -ApiKey "你的智谱API Key"

# Linux / macOS / WSL
./install.sh --api-key "你的智谱API Key"
```

脚本会自动：把插件装入 profile 的 node_modules、注册 `cordis.patch.yml`、写入 `llm-pi-ai` 视觉路由配置、写入凭据。

### 方式二：dsh plugin 命令（需 npm registry 可达）

```sh
dsh plugin --profile web add dsh-plugin-vision-tool
```

然后手动完成下文的"依赖配置"。

### 方式三：手动放置

1. 把 `dsh-plugin-vision-tool` 包目录放入 `$DSH_HOME/profiles/node_modules/`；
2. 编辑 `$DSH_HOME/profiles/web/cordis.patch.yml`，加入：

```yaml
- insert:
    - id: vision-tool
      name: 'dsh-plugin-vision-tool'
      config:
        provider: zhipu
        model: glm-4.6v-flash
```

3. 完成下文的"依赖配置"，然后重启 Web 实例（`dsh --profile web`）。

## 依赖配置（settings.yaml + 凭据）

编辑 `$DSH_HOME/settings.yaml`（热加载，无需重启）：

```yaml
llm-pi-ai:
  providers:
    zhipu:
      displayName: 智谱 GLM-4.6V-Flash
      api: openai-completions
      baseURL: https://open.bigmodel.cn/api/paas/v4
      apiKeyEnv: ZHIPU_API_KEY
      models:
        - id: glm-4.6v-flash
          input: [text, image]   # 关键：声明 image 模态

agent-default-model:             # 默认文本模型保持 DeepSeek（可选）
  provider: deepseek-official
  model: deepseek-v4-flash
```

API key 存入 `$DSH_HOME/.credentials.yaml`（由凭据服务热加载）：

```yaml
ZHIPU_API_KEY: <your key>
```

完整的可参考配置见 [examples/](examples/)。

## 使用

任何会话（包括 DeepSeek 文本模型）中，把图片放进工作区后对 agent 说：

> 识别这个文件 xxx.png
> （或）用 analyze_image 分析 xxx.png，这张图的图表数据是什么？

agent 会自动调用 `analyze_image` 工具。也可以直接要求"识别 github.png"这类指令。

## 配置项（cordis.patch.yml 中该行的 config）

| 字段 | 默认 | 说明 |
|---|---|---|
| `provider` | `zhipu` | `llm-pi-ai` 里配置的 provider 路由名 |
| `model` | `glm-4.6v-flash` | 视觉模型 id（如 `glm-4.5v`、`glm-4v-plus`） |

## 常见问题

- **`429 {"code":"1305","message":"该模型当前访问量过大"}`**：免费视觉模型高峰限流。插件已自动重试 4 次，仍失败请稍后再试，或把 `config.model` 换成付费模型（如 `glm-4.5v`）。
- **`Stored attachment metadata does not match its reference`**：请使用本包自带的 index.js（曾有过只传部分附件元数据的旧版本，已修复）。
- **修改代码后不生效**：HMR 忽略 node_modules。需重启实例，或按加载器规则改动 `cordis.patch.yml` 中该行的 `name` 触发重新导入。
- **`read_image` 工具报"模型不支持图片"**：这是 DSH 内置工具，要求会话模型本身支持图片；纯文本模型会话请使用 `analyze_image`。

## 兼容性

- 依赖 DSH 运行时内部接口（`@deepseek-ai/dsh-tools` 的 `defineTool`、`ctx.llm`、`ctx.attachments`、`ctx.fs`），跨 DSH 版本可能变动，升级 DSH 后请回归验证。
- 已在 DeepSeek-V4-Flash 会话中端到端验证（图片问答、OCR 式描述）。

## License

MIT
