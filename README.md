# dsh-plugin-vision-tool

Give text-only DeepSeek Harness models image recognition: a Cordis host plugin that registers the `analyze_image` tool, routing image recognition to a **dedicated vision model** (default Zhipu GLM-4.6V-Flash), so sessions on text-only models like DeepSeek can "see" images too.

[English](README.md) | [中文](README.zh.md)

> Core idea: **vision capability doesn't have to live on the model — it can live on the harness.** Images only ever travel to the vision model inside this tool; the conversation model itself never needs to declare image input.

## Features

- Registers the model tool `analyze_image(file_path, question?)`
- Reads PNG / JPEG / WebP / GIF images from the session workspace
- Validates and durably stores bytes through the DSH attachment service (same lifecycle as user-uploaded images)
- Calls the vision model through the harness's own `ctx.llm` seam (**zero external dependencies**; reuses DSH credentials/attachments/sandbox)
- The conversation model does **not** need image support: works directly in DeepSeek text-model sessions
- Automatic backoff retry on transient rate limits (HTTP 429 / Zhipu code 1305 "model too busy", up to 4 attempts)
- `provider` / `model` are configurable via the plugin row's `config` (default `zhipu` / `glm-4.6v-flash`)

## How it works

```
User: 识别 xxx.png
  │
  ▼
DeepSeek session (text-only model, no multimodal required)
  │ calls the analyze_image tool
  ▼
Host plugin: read file → ctx.attachments validate+store → ctx.llm.stream({provider: zhipu, model: glm-4.6v-flash, image message})
  │
  ▼
Zhipu GLM-4.6V-Flash vision model → text description → back to the DeepSeek session
```

## Installation

### Option 1: installer script (recommended)

```powershell
# Windows
.\install.ps1 -ApiKey "your-zhipu-api-key"

# Linux / macOS / WSL
./install.sh --api-key "your-zhipu-api-key"
```

The script copies the plugin into the profile's `node_modules`, registers the row in `cordis.patch.yml`, writes the `llm-pi-ai` vision route into `settings.yaml`, and stores the credential.

### Option 2: dsh plugin command (needs npm registry access)

```sh
dsh plugin --profile web add dsh-plugin-vision-tool
```

Then complete the "Configuration" section below.

### Option 3: manual

1. Put the `dsh-plugin-vision-tool` package directory into `$DSH_HOME/profiles/node_modules/`;
2. Edit `$DSH_HOME/profiles/web/cordis.patch.yml`:

```yaml
- insert:
    - id: vision-tool
      name: 'dsh-plugin-vision-tool'
      config:
        provider: zhipu
        model: glm-4.6v-flash
```

3. Complete the "Configuration" section, then restart the instance (`dsh --profile web`).

## Configuration (settings.yaml + credentials)

Edit `$DSH_HOME/settings.yaml` (hot-reloaded, no restart needed):

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
          input: [text, image]   # key: declare the image modality

agent-default-model:             # optional: keep the default text model on DeepSeek
  provider: deepseek-official
  model: deepseek-v4-flash
```

Store the API key in `$DSH_HOME/.credentials.yaml` (hot-reloaded by the credentials service):

```yaml
ZHIPU_API_KEY: <your key>
```

See [examples/](examples/) for complete reference configs.

## Usage

In any session (DeepSeek text model included), put an image in the workspace and tell the agent:

> 识别这个文件 xxx.png
> (or) Use analyze_image on xxx.png — what does the chart say?

The agent calls `analyze_image` automatically.

## Config options (the plugin row's `config`)

| Field | Default | Description |
|---|---|---|
| `provider` | `zhipu` | provider route name configured under `llm-pi-ai` |
| `model` | `glm-4.6v-flash` | vision model id (e.g. `glm-4.5v`, `glm-4v-plus`) |

## Troubleshooting

- **`429 {"code":"1305","message":"该模型当前访问量过大"}`**: rate limit on the free vision model. The plugin already retries 4 times; wait a while and retry, or switch `config.model` to a paid model (e.g. `glm-4.5v`).
- **`Stored attachment metadata does not match its reference`**: use the `index.js` shipped with this package (an old version passed only partial attachment metadata; fixed).
- **Code changes don't take effect**: HMR ignores `node_modules`. Restart the instance, or change the row's `name` in `cordis.patch.yml` to force a loader re-import.
- **`read_image` reports "model does not support images"**: that is DSH's built-in tool, which requires the session model itself to support images; text-only sessions should use `analyze_image`.

## Compatibility

- Depends on DSH runtime internals (`defineTool` from `@deepseek-ai/dsh-tools`, `ctx.llm`, `ctx.attachments`, `ctx.fs`); may change across DSH releases — re-verify after upgrading DSH.
- End-to-end verified in a DeepSeek-V4-Flash session (image Q&A, OCR-style description).

## License

MIT
