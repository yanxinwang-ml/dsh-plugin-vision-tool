#!/usr/bin/env bash
# Install dsh-plugin-vision-tool into a DeepSeek Harness profile (Linux/macOS/WSL).
# Idempotent: safe to run multiple times.
#
# Usage:
#   ./install.sh --api-key "abc.def" [--profile web] [--vision-model glm-4.6v-flash] [--set-text-default]

set -euo pipefail

PROFILE="web"
API_KEY=""
VISION_PROVIDER="zhipu"
VISION_MODEL="glm-4.6v-flash"
BASE_URL="https://open.bigmodel.cn/api/paas/v4"
API_KEY_ENV="ZHIPU_API_KEY"
SET_TEXT_DEFAULT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --api-key) API_KEY="$2"; shift 2 ;;
    --vision-provider) VISION_PROVIDER="$2"; shift 2 ;;
    --vision-model) VISION_MODEL="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --api-key-env) API_KEY_ENV="$2"; shift 2 ;;
    --set-text-default) SET_TEXT_DEFAULT=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$DSH_HOME/profiles/$PROFILE"
PROFILE_NM="$DSH_HOME/profiles/node_modules"
PKG_NAME="dsh-plugin-vision-tool"
PKG_TARGET="$PROFILE_NM/$PKG_NAME"

if [[ ! -d "$PROFILE_DIR" ]]; then
  echo "ERROR: profile directory not found: $PROFILE_DIR" >&2
  exit 1
fi

echo "==> Installing $PKG_NAME into profile '$PROFILE' (DSH home: $DSH_HOME)"

# 1) copy plugin package
mkdir -p "$PROFILE_NM" "$PKG_TARGET"
cp "$SCRIPT_DIR/index.js" "$PKG_TARGET/index.js"
if [[ ! -f "$PKG_TARGET/package.json" ]]; then
  cp "$SCRIPT_DIR/package.json" "$PKG_TARGET/package.json"
fi
echo "    copied plugin to $PKG_TARGET"

# 2) register row in cordis.patch.yml
# The patch file is parsed by js-yaml as ONE document, so appending a second
# YAML document after the empty template '[]' would break it. Strategy:
#   - already registered            -> skip
#   - empty template ('[]')         -> replace the file with a single document
#   - customized list               -> append a new list item
PATCH_PATH="$PROFILE_DIR/cordis.patch.yml"
PATCH_BLOCK="
# dsh-plugin-vision-tool registration (added by install.sh)
- insert:
    - id: vision-tool
      name: '$PKG_NAME'
      config:
        provider: $VISION_PROVIDER
        model: $VISION_MODEL
"
if [[ -f "$PATCH_PATH" ]]; then
  if grep -q 'id:[[:space:]]*vision-tool' "$PATCH_PATH"; then
    echo "    cordis.patch.yml already registers vision-tool, skipping"
  else
    NO_COMMENTS="$(grep -v '^[[:space:]]*#' "$PATCH_PATH" | grep -v '^[[:space:]]*$' | tr -d '[:space:]')"
    if [[ "$NO_COMMENTS" == "[]" ]]; then
      printf '%s\n' "$PATCH_BLOCK" > "$PATCH_PATH"
      echo "    replaced empty template in $PATCH_PATH"
    else
      printf '\n%s\n' "$PATCH_BLOCK" >> "$PATCH_PATH"
      echo "    appended vision-tool row to $PATCH_PATH"
    fi
  fi
else
  printf '%s\n' "$PATCH_BLOCK" > "$PATCH_PATH"
  echo "    created $PATCH_PATH"
fi

# 3) merge llm-pi-ai vision route into settings.yaml
SETTINGS_PATH="$DSH_HOME/settings.yaml"
SETTINGS_BLOCK="
# dsh-plugin-vision-tool vision route (added by install.sh)
llm-pi-ai:
  providers:
    $VISION_PROVIDER:
      displayName: 智谱 $VISION_MODEL
      api: openai-completions
      baseURL: $BASE_URL
      apiKeyEnv: $API_KEY_ENV
      models:
        - id: $VISION_MODEL
          input: [text, image]
"
if [[ -f "$SETTINGS_PATH" ]]; then
  if grep -q 'llm-pi-ai:' "$SETTINGS_PATH"; then
    echo "    settings.yaml already has llm-pi-ai; please merge provider '$VISION_PROVIDER' manually (see examples/settings.yaml)"
  else
    printf '\n%s\n' "$SETTINGS_BLOCK" >> "$SETTINGS_PATH"
    echo "    added llm-pi-ai vision route to $SETTINGS_PATH"
  fi
else
  printf '%s\n' "$SETTINGS_BLOCK" > "$SETTINGS_PATH"
  echo "    created $SETTINGS_PATH"
fi

# 4) optional: agent-default-model stays DeepSeek
if [[ "$SET_TEXT_DEFAULT" == "1" ]]; then
  DEFAULT_BLOCK="
# dsh-plugin-vision-tool: keep the default text model on DeepSeek (added by install.sh)
agent-default-model:
  provider: deepseek-official
  model: deepseek-v4-flash
"
  if [[ -f "$SETTINGS_PATH" ]]; then
    if ! grep -q 'agent-default-model:' "$SETTINGS_PATH"; then
      printf '\n%s\n' "$DEFAULT_BLOCK" >> "$SETTINGS_PATH"
      echo "    set agent-default-model to DeepSeek"
    else
      echo "    agent-default-model already present, skipping"
    fi
  else
    printf '%s\n' "$DEFAULT_BLOCK" > "$SETTINGS_PATH"
    echo "    set agent-default-model to DeepSeek"
  fi
fi

# 5) store API key
CRED_PATH="$DSH_HOME/.credentials.yaml"
STORED=0
if [[ -f "$CRED_PATH" ]] && grep -q "^$API_KEY_ENV:" "$CRED_PATH"; then
  STORED=1
fi
if [[ -z "$API_KEY" ]]; then
  if [[ "$STORED" == "1" ]]; then
    echo "    credential '$API_KEY_ENV' already stored, skipping"
    API_KEY="stored"
  fi
fi
if [[ -n "$API_KEY" && "$API_KEY" != "stored" ]]; then
  if [[ "$STORED" == "1" ]]; then
    echo "    credential '$API_KEY_ENV' already exists, not overwriting"
  else
    touch "$CRED_PATH"
    chmod 600 "$CRED_PATH"
    printf '%s: %s\n' "$API_KEY_ENV" "$API_KEY" >> "$CRED_PATH"
    echo "    stored credential '$API_KEY_ENV'"
  fi
fi

echo ""
echo "==> Done. Next steps:"
echo "    1) Restart the DSH instance (stop and start 'dsh --profile $PROFILE')"
echo "    2) In any session (DeepSeek text model is fine), put an image in the workspace and say:"
echo "        识别这个文件 xxx.png"
