<#
.SYNOPSIS
    Install dsh-plugin-vision-tool into a DeepSeek Harness profile.

.DESCRIPTION
    Copies the plugin into the profile's node_modules, registers the
    vision-tool row in cordis.patch.yml, merges the llm-pi-ai vision route
    into settings.yaml, and stores the ZHIPU API key in .credentials.yaml.
    Idempotent: safe to run multiple times.

.PARAMETER Profile
    Profile name to install into (default: web).

.PARAMETER ApiKey
    Zhipu (BigModel) API key. If omitted and no key is stored, you are prompted.

.PARAMETER VisionProvider
    Provider route name for the vision model (default: zhipu).

.PARAMETER VisionModel
    Vision model id (default: glm-4.6v-flash).

.PARAMETER BaseURL
    OpenAI-compatible base URL of the vision provider (default: https://open.bigmodel.cn/api/paas/v4).

.PARAMETER ApiKeyEnv
    Credential reference name stored in .credentials.yaml (default: ZHIPU_API_KEY).

.PARAMETER SetTextDefault
    Also set agent-default-model to deepseek-official / deepseek-v4-flash.

.EXAMPLE
    .\install.ps1 -ApiKey "abc.def"
.EXAMPLE
    .\install.ps1 -ApiKey "abc.def" -VisionModel "glm-4.5v" -SetTextDefault
#>
[CmdletBinding()]
param(
    [string]$Profile = "web",
    [string]$ApiKey = "",
    [string]$VisionProvider = "zhipu",
    [string]$VisionModel = "glm-4.6v-flash",
    [string]$BaseURL = "https://open.bigmodel.cn/api/paas/v4",
    [string]$ApiKeyEnv = "ZHIPU_API_KEY",
    [switch]$SetTextDefault
)

$ErrorActionPreference = "Stop"

# UTF-8 (no BOM) writer/reader that behaves identically on Windows PowerShell
# 5.1 and PowerShell 7.
function Read-Utf8Text([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    return [System.IO.File]::ReadAllText($Path)
}
function Write-Utf8Text([string]$Path, [string]$Content) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Resolve-DshHome {
    if ($env:DSH_HOME -and (Test-Path $env:DSH_HOME)) { return $env:DSH_HOME }
    $home = Join-Path $HOME ".dsh"
    if (-not (Test-Path $home)) {
        Write-Warning "DSH home not found at $home; set DSH_HOME to the harness home of the target instance."
    }
    return $home
}

$dshHome = Resolve-DshHome
$profileDir = Join-Path $dshHome "profiles\$Profile"
if (-not (Test-Path $profileDir)) {
    throw "Profile directory not found: $profileDir (does '$Profile' exist? run 'dsh plugin --profile $Profile --version' to initialize it first)"
}
$profileNodeModules = Join-Path $dshHome "profiles\node_modules"
$pkgName = "dsh-plugin-vision-tool"
$pkgTarget = Join-Path $profileNodeModules $pkgName

Write-Host "==> Installing $pkgName into profile '$Profile' (DSH home: $dshHome)"

# 1) copy plugin package
New-Item -ItemType Directory -Path $profileNodeModules -Force | Out-Null
if (Test-Path $pkgTarget) {
    Write-Host "    plugin package already present, refreshing files..."
    Copy-Item "$PSScriptRoot\index.js" (Join-Path $pkgTarget "index.js") -Force
} else {
    New-Item -ItemType Directory -Path $pkgTarget -Force | Out-Null
    Copy-Item "$PSScriptRoot\index.js" (Join-Path $pkgTarget "index.js") -Force
    Copy-Item "$PSScriptRoot\package.json" (Join-Path $pkgTarget "package.json") -Force
    Write-Host "    copied plugin to $pkgTarget"
}

# 2) register row in cordis.patch.yml
# The patch file is parsed by js-yaml as ONE document, so appending a second
# YAML document after the empty template '[]' would break it. Strategy:
#   - already registered            -> skip
#   - empty template ('[]')         -> replace the file with a single document
#   - customized list               -> append a new list item
$patchPath = Join-Path $profileDir "cordis.patch.yml"
$patchBlock = @"
# dsh-plugin-vision-tool registration (added by install.ps1)
- insert:
    - id: vision-tool
      name: '$pkgName'
      config:
        provider: $VisionProvider
        model: $VisionModel
"@
$existing = Read-Utf8Text $patchPath
if ($existing -eq $null) {
    Write-Utf8Text $patchPath $patchBlock
    Write-Host "    created $patchPath"
} elseif ($existing -match 'id:\s*vision-tool') {
    Write-Host "    cordis.patch.yml already registers vision-tool, skipping (edit it manually to change config)"
} else {
    $noComments = ($existing -split "`r?`n" | Where-Object { $_.Trim() -notmatch '^#' -and $_.Trim() -ne '' }) -join "`n"
    if ($noComments.Trim() -eq '[]') {
        Write-Utf8Text $patchPath ($patchBlock + "`n")
        Write-Host "    replaced empty template in $patchPath"
    } else {
        $sep = if ($existing.TrimEnd().EndsWith("`n")) { "" } else { "`n" }
        Write-Utf8Text $patchPath ($existing.TrimEnd() + $sep + "`n" + $patchBlock + "`n")
        Write-Host "    appended vision-tool row to $patchPath"
    }
}

# 3) merge llm-pi-ai vision route into settings.yaml
$settingsPath = Join-Path $dshHome "settings.yaml"
$settingsBlock = @"

# dsh-plugin-vision-tool vision route (added by install.ps1)
llm-pi-ai:
  providers:
    ${VisionProvider}:
      displayName: 智谱 $VisionModel
      api: openai-completions
      baseURL: $BaseURL
      apiKeyEnv: $ApiKeyEnv
      models:
        - id: $VisionModel
          input: [text, image]
"@
$settingsExisting = Read-Utf8Text $settingsPath
if ($settingsExisting -eq $null) {
    Write-Utf8Text $settingsPath $settingsBlock
    Write-Host "    created $settingsPath"
} elseif ($settingsExisting -match 'llm-pi-ai:') {
    Write-Host "    settings.yaml already has llm-pi-ai; please merge the provider '$VisionProvider' manually (see examples/settings.yaml)"
} else {
    Write-Utf8Text $settingsPath ($settingsExisting.TrimEnd() + "`n" + $settingsBlock)
    Write-Host "    added llm-pi-ai vision route to $settingsPath"
}

# 4) optional: agent-default-model stays DeepSeek
if ($SetTextDefault) {
    $defaultBlock = @"

# dsh-plugin-vision-tool: keep the default text model on DeepSeek (added by install.ps1)
agent-default-model:
  provider: deepseek-official
  model: deepseek-v4-flash
"@
    $cur = Read-Utf8Text $settingsPath
    if ($cur -ne $null -and $cur -notmatch 'agent-default-model:') {
        Write-Utf8Text $settingsPath ($cur.TrimEnd() + "`n" + $defaultBlock)
        Write-Host "    set agent-default-model to DeepSeek"
    } elseif ($cur -eq $null) {
        Write-Utf8Text $settingsPath $defaultBlock
        Write-Host "    set agent-default-model to DeepSeek"
    } else {
        Write-Host "    agent-default-model already present, skipping"
    }
}

# 5) store API key
$credPath = Join-Path $dshHome ".credentials.yaml"
$credExisting = Read-Utf8Text $credPath
$stored = ($credExisting -ne $null) -and ($credExisting -match "(?m)^$([regex]::Escape($ApiKeyEnv))\s*:")
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    if ($stored) {
        Write-Host "    credential '$ApiKeyEnv' already stored, skipping"
        $ApiKey = "stored"
    } else {
        $secure = Read-Host "Enter your Zhipu API key (or press Enter to skip)"
        $ApiKey = $secure
    }
}
if (-not [string]::IsNullOrWhiteSpace($ApiKey) -and $ApiKey -ne "stored") {
    if ($stored) {
        Write-Host "    credential '$ApiKeyEnv' already exists, not overwriting"
    } else {
        $line = "$ApiKeyEnv`: $ApiKey"
        if ($credExisting -eq $null) { Write-Utf8Text $credPath ($line + "`n") }
        else { Write-Utf8Text $credPath ($credExisting.TrimEnd() + "`n" + $line + "`n") }
        Write-Host "    stored credential '$ApiKeyEnv'"
    }
}

Write-Host ""
Write-Host "==> Done. Next steps:"
Write-Host "    1) Restart the DSH instance (stop and start 'dsh --profile $Profile')"
Write-Host "    2) In any session (DeepSeek text model is fine), put an image in the workspace and say:"
Write-Host "        识别这个文件 xxx.png"
