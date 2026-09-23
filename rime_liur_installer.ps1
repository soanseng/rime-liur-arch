# RIME 蝦米輸入方案自動安裝工具 (Windows PowerShell)
# created by Ryan Chou
# https://github.com/ryanwuson/rime-liur

$ErrorActionPreference = "Stop"

# GitHub 相關設定
# 指向本 fork（soanseng/rime-liur-arch）：含 librime 1.16+/Lua 5.4+ 相容修正與
# 最新方案更新（liu_bpmf/liu_pinyin 等）。上游 ryanwuson/rime-liur 不一定有。
$GITHUB_REPO = "soanseng/rime-liur-arch"
$GITHUB_BRANCH = "main"
$GITHUB_API = "https://api.github.com/repos/$GITHUB_REPO/git/trees/$GITHUB_BRANCH`?recursive=1"
$GITHUB_RAW = "https://raw.githubusercontent.com/$GITHUB_REPO/$GITHUB_BRANCH"

# 設定路徑
$RIME_FOLDER = "$env:APPDATA\Rime"
$FONT_FOLDER = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"

# 排除清單（正則表達式）
$EXCLUDE_PATTERNS = @(
    "^docs/"
    "^README\.md$"
    "^LICENSE$"
    "^\.gitignore$"
    "^rime_liur_installer\.sh$"
    "^rime_liur_installer\.ps1$"
    "^rime_liur_installer_linux\.sh$"
)

# 進度條函數
function Show-Progress {
    param(
        [int]$Current,
        [int]$Total,
        [string]$FileName
    )
    
    $width = 20
    $percent = [math]::Floor($Current * 100 / $Total)
    $filled = [math]::Floor($Current * $width / $Total)
    $empty = $width - $filled
    
    $bar = "█" * $filled + "░" * $empty
    
    # 截斷過長的檔名（保留空間給 [skip]）
    if ($FileName.Length -gt 40) {
        $FileName = $FileName.Substring(0, 37) + "..."
    }
    
    $status = "  [$bar] $("{0,3}" -f $Current)/$Total  $($FileName.PadRight(45))"
    Write-Host "`r$status" -NoNewline
}

# ---- 以下 helper 移植自 rime-phah-taibun 的 install_windows.ps1 ----
# Windows PowerShell 5.1 預設把追加文字寫成 UTF-16、UTF8 旗標還會加 BOM，
# 兩者都會讓 default.custom.yaml 解析失敗，故一律走 .NET 的無 BOM UTF-8。
function Read-RimeText {
    param([string]$Path)
    $reader = New-Object System.IO.StreamReader($Path, $true)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Write-RimeText {
    param([string]$Path, [string]$Text)
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Add-RimeText {
    param([string]$Path, [string]$Text)
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $existing = ""
    if (Test-Path $Path) { $existing = Read-RimeText $Path }
    if ($existing.Length -gt 0 -and -not $existing.EndsWith("`n")) { $Text = "`n" + $Text }
    if (-not $Text.EndsWith("`n")) { $Text = $Text + "`n" }
    [System.IO.File]::AppendAllText($Path, $Text, $utf8)
}

function Get-RimeLines {
    param([string]$Path)
    $text = Read-RimeText $Path
    if ([string]::IsNullOrEmpty($text)) { return @() }
    return ($text -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd("`n").Split("`n")
}

# PowerShell 的降冪範圍會反向取值：$lines[4..3] 會回傳索引 4 與 3（把檔尾重複一次）。
function Get-RimeTail {
    param([string[]]$Lines, [int]$AfterIndex)
    if ($AfterIndex + 1 -le $Lines.Count - 1) { return $Lines[($AfterIndex + 1)..($Lines.Count - 1)] }
    return @()
}

# 列出 default.custom.yaml 內註冊的方案 id（- schema: 與 schema_list/@next 兩種形式，去重）。
function Get-RimeSchemaIds {
    param([string]$Path)
    $ids = @()
    $lines = @(Get-RimeLines $Path)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*- schema:\s*(\S+)\s*$') {
            if ($ids -notcontains $Matches[1]) { $ids += $Matches[1] }
        }
        elseif ($lines[$i] -match '^\s*schema_list/@next(\s+\d+)?:\s*$' -and
                $i + 1 -lt $lines.Count -and $lines[$i + 1] -match '^\s+schema:\s*(\S+)\s*$') {
            if ($ids -notcontains $Matches[1]) { $ids += $Matches[1] }
            $i++
        }
    }
    return $ids
}

# 追加單一方案到 default.custom.yaml（已存在就跳過），支援三種檔案格式：
# patch: 單一 map、__patch: 列表、schema_list/@next 形式。
function Add-SchemaEntry {
    param([string]$SchemaId)

    if (Select-String -Path $defaultCustom -Pattern ("schema: " + $SchemaId + "\s*$") -Quiet) {
        return
    }

    $content = Read-RimeText $defaultCustom
    if ($content -match '- schema:') {
        $lines = @(Get-RimeLines $defaultCustom)
        $lastIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*- schema:') { $lastIdx = $i }
        }
        if ($lastIdx -ge 0) {
            $indent = $lines[$lastIdx] -replace '- schema:.*', ''
            $newLines = @($lines[0..$lastIdx] + "${indent}- schema: $SchemaId" + (Get-RimeTail -Lines $lines -AfterIndex $lastIdx))
            Write-RimeText -Path $defaultCustom -Text (($newLines -join "`n") + "`n")
            return
        }
    }

    # 同一個 @next key 只能出現一次（librime 實測：重複 key 只留最後一筆），取未占用序號。
    $nextKey = "schema_list/@next"
    $nextIdx = 1
    while (Select-String -Path $defaultCustom -Pattern ("^\s*" + [regex]::Escape($nextKey) + "\s*:") -Quiet) {
        $nextKey = "schema_list/@next $nextIdx"
        $nextIdx++
    }

    if ((Get-RimeLines $defaultCustom | Select-Object -First 1) -match '^__patch:') {
        Add-RimeText -Path $defaultCustom -Text "  - patch/+:`n      ${nextKey}:`n        schema: $SchemaId"
    } else {
        Add-RimeText -Path $defaultCustom -Text "  ${nextKey}:`n    schema: $SchemaId"
    }
}

# 把 default.custom.yaml 整理成乾淨排版並加上說明註解；使用者自己的設定原樣保留。
# 傳回 $true＝已重寫；$false＝維持原樣（__patch: 複合格式或非 patch: 檔）。對自己的輸出冪等。
function Convert-RimeDefaultCustom {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    $lines = @(Get-RimeLines $Path)
    if ($lines.Count -eq 0) { return $false }

    $bodyStart = 0
    while ($bodyStart -lt $lines.Count -and $lines[$bodyStart] -match '^\s*(#|$)') { $bodyStart++ }
    if ($bodyStart -ge $lines.Count -or $lines[$bodyStart] -notmatch '^patch:\s*$') { return $false }

    $schemaIds = @(Get-RimeSchemaIds -Path $Path)
    $hasSaveOptions = $false
    $isDashList = $false
    foreach ($line in $lines) {
        if ($line -match 'switcher/save_options') { $hasSaveOptions = $true }
        if ($line -match '^\s*- schema:') { $isDashList = $true }
    }

    $out = New-Object System.Collections.Generic.List[string]
    $out.Add("# default.custom.yaml — 嘸蝦米（rime-liur-arch）設定")
    $out.Add("#")
    $out.Add("# 安裝工具只會「追加」方案，不會覆蓋你的其他設定；")
    $out.Add("# 原始內容在每次安裝前都會備份成 default.custom.yaml.backup-<時間戳>。")
    $out.Add("#")
    $out.Add("# schema_list：可用的輸入方案，順序＝F4 選單順序。")
    if ($hasSaveOptions) {
        $out.Add("# switcher/save_options：記住 F4 選過的模式，重新部署或重開機不用重選。")
    }
    $out.Add("")
    $out.Add("patch:")

    if ($hasSaveOptions) {
        $out.Add("  # 記住 F4 的模式選擇")
        $out.Add("  switcher/save_options/@before 0: poj_mode")
        $out.Add("  switcher/save_options/@next: full_romanization")
    }

    if ($schemaIds.Count -gt 0) {
        if ($isDashList) {
            $out.Add("  # 輸入方案清單（明確列表：以此為準，小狼毫內建方案不會出現在 F4）；要增刪方案就增減下面幾行。")
            $out.Add("  schema_list:")
            foreach ($id in $schemaIds) { $out.Add("    - schema: $id") }
        } else {
            $out.Add("  # 以下方案以 @next 附加在小狼毫內建清單之後（內建注音、倉頡等仍可用）；新增方案建議重跑安裝工具。")
            $out.Add("  schema_list/@next:")
            $out.Add("    schema: " + $schemaIds[0])
            for ($i = 1; $i -lt $schemaIds.Count; $i++) {
                $out.Add(("  schema_list/@next {0}:" -f $i))
                $out.Add("    schema: " + $schemaIds[$i])
            }
        }
    }

    # 正規化自己輸出的區塊註解：重跑時要跳過，否則會在尾段累積（破壞冪等）
    $managedComments = @(
        "  # 記住 F4 的模式選擇",
        "  # 輸入方案清單（明確列表",
        "  # 以下方案以 @next"
    )

    # 原檔中非安裝工具管理的行（menu、key_binder、自訂註解…）原樣接在後面
    $seenPatch = $false
    $leading = $true
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($leading) {
            if ($line -match '^\s*(#|$)') { continue }
            $leading = $false
        }
        if (-not $seenPatch) {
            if ($line -match '^patch:\s*$') { $seenPatch = $true }
            continue
        }
        $isManagedComment = $false
        foreach ($mc in $managedComments) {
            if ($line.StartsWith($mc)) { $isManagedComment = $true; break }
        }
        if ($isManagedComment) { continue }
        if ($line -match '^\s*- schema:\s*(\S+)\s*$') { continue }
        if ($isDashList -and $line -match '^\s*schema_list:\s*$') { continue }
        if ($line -match '^\s*schema_list/@next(\s+\d+)?:\s*$') {
            if ($i + 1 -lt $lines.Count -and $lines[$i + 1] -match '^\s+schema:\s*(\S+)\s*$') { $i++ }
            continue
        }
        if ($line -match 'switcher/save_options') { continue }
        $out.Add($line)
    }

    Write-RimeText -Path $Path -Text (($out -join "`n") + "`n")
    return $true
}
# ---- helper 移植結束 ----

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "  RIME 蝦米輸入方案 自動安裝工具" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "本工具將執行以下作業："
Write-Host "1. 選擇輸入方案版本"
Write-Host "2. 下載蝦米輸入方案檔案到 Rime 資料夾"
Write-Host "3. 安裝所需字體"
Write-Host ""
Write-Host "※ 若有自訂設定尚未備份，請按 Ctrl+C 終止" -ForegroundColor Yellow
Write-Host ""

# 版本選擇
Write-Host "請選擇輸入方案版本：" -ForegroundColor Yellow
Write-Host ""
Write-Host "1. 完整版（中打含英文詞庫版）（推薦）"
Write-Host "   - 完整功能，中文輸入搭配英文詞庫輔助"
Write-Host "   - 英文詞庫支援，大小寫轉換"
Write-Host "   - 適合日常使用、程式開發"
Write-Host ""
Write-Host "2. 基礎版（中打不含英文詞庫）"
Write-Host "   - 專注中文輸入，不含英文詞庫"
Write-Host "   - 減少英文候選干擾"
Write-Host "   - 適合純中文寫作"
Write-Host ""

do {
    $choice = Read-Host "請輸入選項 (1 或 2)"
} while ($choice -ne "1" -and $choice -ne "2")

if ($choice -eq "1") {
    $SCHEMA_VERSION = "mixed"
    Write-Host "已選擇：完整版（中打含英文詞庫版）" -ForegroundColor Green
} else {
    $SCHEMA_VERSION = "chinese-only"
    Write-Host "已選擇：基礎版（中打不含英文詞庫）" -ForegroundColor Green
}

Write-Host ""

# 自定義設定檔選項
Write-Host "是否覆蓋自定義設定檔？" -ForegroundColor Yellow
Write-Host ""
Write-Host "以下檔案用於儲存您的個人設定與詞彙："
Write-Host "• openxiami_CustomWord.dict.yaml（自定義詞庫）"
Write-Host "• default.custom.yaml（全域設定）"
Write-Host "• weasel.custom.yaml（小狼毫外觀設定）"
Write-Host ""
Write-Host "若您已有自訂設定，建議選擇「保留」以避免遺失。"
Write-Host ""
Write-Host "1. 保留（推薦）- 保留現有的自定義設定檔"
Write-Host "2. 覆蓋 - 下載預設設定檔（會清除您的自訂設定）"
Write-Host ""

do {
    $customChoice = Read-Host "請輸入選項 (1 或 2)"
} while ($customChoice -ne "1" -and $customChoice -ne "2")

if ($customChoice -eq "1") {
    $KEEP_CUSTOM_FILES = $true
    Write-Host "已選擇：保留自定義設定檔" -ForegroundColor Green
} else {
    $KEEP_CUSTOM_FILES = $false
    Write-Host "已選擇：覆蓋自定義設定檔" -ForegroundColor Green
}

Write-Host ""

for ($i = 3; $i -ge 1; $i--) {
    Write-Host "`r將在 $i 秒後開始..." -NoNewline
    Start-Sleep -Seconds 1
}
Write-Host ""  # 換行

Write-Host ""
Write-Host "正在從 GitHub 取得檔案清單..."
try {
    $response = Invoke-RestMethod -Uri $GITHUB_API -Method Get
} catch {
    Write-Host "[錯誤] GitHub API 連線失敗" -ForegroundColor Red
    Write-Host "       請檢查網路連線，或稍後再試"
    Write-Host "       若持續失敗，請至 GitHub 手動下載："
    Write-Host "       https://github.com/$GITHUB_REPO"
    exit 1
}

if (-not $response.tree) {
    Write-Host "[錯誤] 無法解析檔案清單" -ForegroundColor Red
    Write-Host "       請稍後再試，或至 GitHub 手動下載："
    Write-Host "       https://github.com/$GITHUB_REPO"
    exit 1
}

# 過濾檔案函數
function Test-ShouldExclude {
    param([string]$FilePath)
    foreach ($pattern in $EXCLUDE_PATTERNS) {
        if ($FilePath -match $pattern) {
            return $true
        }
    }
    return $false
}

# 分類檔案
$ROOT_FILES = @()
$LUA_FILES = @()
$LUA_LUNAR_FILES = @()
$OPENCC_FILES = @()
$CONFIGS_FILES = @()
$FONT_FILES = @()
$FONT_FILES_WIN = @()
# 遠端檔案大小：本地已存在且大小相同就跳過（以大小判斷），重灌不再全部重抓。
$fileSizes = @{}

foreach ($item in $response.tree) {
    # 只處理檔案（blob），跳過資料夾（tree）
    if ($item.type -ne "blob") { continue }
    
    $filePath = $item.path
    
    # 檢查是否要排除
    if (Test-ShouldExclude $filePath) { continue }

    $fileSizes[$filePath] = [long]$item.size

    # 根據路徑分類
    if ($filePath -match "^lua/lunar_calendar/") {
        $LUA_LUNAR_FILES += $filePath
    } elseif ($filePath -match "^lua/") {
        $LUA_FILES += $filePath
    } elseif ($filePath -match "^opencc/") {
        $OPENCC_FILES += $filePath
    } elseif ($filePath -match "^configs/") {
        $CONFIGS_FILES += $filePath
    } elseif ($filePath -match "^fonts/Windows Only/") {
        $FONT_FILES_WIN += $filePath
    } elseif ($filePath -match "^fonts/") {
        $FONT_FILES += $filePath
    } elseif ($filePath -notmatch "/") {
        # 根目錄檔案（不含子資料夾）
        $ROOT_FILES += $filePath
    }
}

# 計算總檔案數
$TOTAL_FILES = $ROOT_FILES.Count + $LUA_FILES.Count + $LUA_LUNAR_FILES.Count + $OPENCC_FILES.Count + $CONFIGS_FILES.Count
$TOTAL_FONTS = $FONT_FILES.Count + $FONT_FILES_WIN.Count
Write-Host "找到 $TOTAL_FILES 個方案檔案、$TOTAL_FONTS 個字體"

Write-Host ""
Write-Host "[ Step 1: 下載蝦米輸入方案檔案 ]" -ForegroundColor Green

# 建立資料夾
New-Item -ItemType Directory -Force -Path $RIME_FOLDER | Out-Null
New-Item -ItemType Directory -Force -Path "$RIME_FOLDER\lua" | Out-Null
New-Item -ItemType Directory -Force -Path "$RIME_FOLDER\lua\lunar_calendar" | Out-Null
New-Item -ItemType Directory -Force -Path "$RIME_FOLDER\lua\data" | Out-Null
New-Item -ItemType Directory -Force -Path "$RIME_FOLDER\opencc" | Out-Null
New-Item -ItemType Directory -Force -Path "$RIME_FOLDER\configs" | Out-Null

$current = 0

# 需要保留的自定義設定檔清單
$CUSTOM_FILES = @("openxiami_CustomWord.dict.yaml", "default.custom.yaml", "weasel.custom.yaml")

# 下載主要檔案
foreach ($file in $ROOT_FILES) {
    $current++
    # 檢查是否為自定義設定檔且選擇保留
    if ($CUSTOM_FILES -contains $file -and $KEEP_CUSTOM_FILES -and (Test-Path "$RIME_FOLDER\$file")) {
        Show-Progress -Current $current -Total $TOTAL_FILES -FileName "$file [保留]"
    } elseif ((Test-Path "$RIME_FOLDER\$file") -and $fileSizes.ContainsKey($file) -and
            (Get-Item "$RIME_FOLDER\$file").Length -eq $fileSizes[$file]) {
        Show-Progress -Current $current -Total $TOTAL_FILES -FileName "$file [已安裝]"
    } else {
        Show-Progress -Current $current -Total $TOTAL_FILES -FileName $file
        Invoke-WebRequest -Uri "$GITHUB_RAW/$file" -OutFile "$RIME_FOLDER\$file" | Out-Null
    }
}

# 下載 Lua 檔案（保留 lua/ 子目錄，例如 lua/data/emoji.txt）
foreach ($file in $LUA_FILES) {
    $current++
    $rel = $file -replace '^lua/', ''
    $dest = Join-Path $RIME_FOLDER "lua\$rel"
    $destDir = Split-Path $dest -Parent
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    if ((Test-Path $dest) -and $fileSizes.ContainsKey($file) -and
            (Get-Item $dest).Length -eq $fileSizes[$file]) {
        Show-Progress -Current $current -Total $TOTAL_FILES -FileName "$file [已安裝]"
    } else {
        Show-Progress -Current $current -Total $TOTAL_FILES -FileName $file
        Invoke-WebRequest -Uri "$GITHUB_RAW/$file" -OutFile $dest | Out-Null
    }
}

# 下載 Lua lunar_calendar 檔案
foreach ($file in $LUA_LUNAR_FILES) {
    $current++
    $filename = Split-Path $file -Leaf
    if ((Test-Path "$RIME_FOLDER\lua\lunar_calendar\$filename") -and $fileSizes.ContainsKey($file) -and
            (Get-Item "$RIME_FOLDER\lua\lunar_calendar\$filename").Length -eq $fileSizes[$file]) {
        Show-Progress -Current $current -Total $TOTAL_FILES -FileName "$filename [已安裝]"
    } else {
        Show-Progress -Current $current -Total $TOTAL_FILES -FileName $filename
        Invoke-WebRequest -Uri "$GITHUB_RAW/$file" -OutFile "$RIME_FOLDER\lua\lunar_calendar\$filename" | Out-Null
    }
}

# 下載 OpenCC 檔案
foreach ($file in $OPENCC_FILES) {
    $current++
    $filename = Split-Path $file -Leaf
    if ((Test-Path "$RIME_FOLDER\opencc\$filename") -and $fileSizes.ContainsKey($file) -and
            (Get-Item "$RIME_FOLDER\opencc\$filename").Length -eq $fileSizes[$file]) {
        Show-Progress -Current $current -Total $TOTAL_FILES -FileName "$filename [已安裝]"
    } else {
        Show-Progress -Current $current -Total $TOTAL_FILES -FileName $filename
        Invoke-WebRequest -Uri "$GITHUB_RAW/$file" -OutFile "$RIME_FOLDER\opencc\$filename" | Out-Null
    }
}

# 下載 Configs 檔案
foreach ($file in $CONFIGS_FILES) {
    $current++
    $filename = Split-Path $file -Leaf
    Show-Progress -Current $current -Total $TOTAL_FILES -FileName $filename
    Invoke-WebRequest -Uri "$GITHUB_RAW/$file" -OutFile "$RIME_FOLDER\configs\$filename" | Out-Null
}

Write-Host ""  # 換行

Write-Host ""
Write-Host "[ Step 2: 配置輸入方案版本 ]" -ForegroundColor Green

# 根據選擇配置對應版本
if ($SCHEMA_VERSION -eq "mixed") {
    Write-Host "正在配置完整版（中打含英文詞庫版）..."
    Copy-Item "$RIME_FOLDER\configs\liur.schema.yaml" "$RIME_FOLDER\liur.schema.yaml" -Force
    Write-Host "已配置為完整版（中打含英文詞庫版）" -ForegroundColor Green
} else {
    Write-Host "正在配置基礎版（中打不含英文詞庫）..."
    Copy-Item "$RIME_FOLDER\configs\liur.chinese-only.schema.yaml" "$RIME_FOLDER\liur.schema.yaml" -Force
    Write-Host "已配置為基礎版（中打不含英文詞庫）" -ForegroundColor Green
}

# 清理 configs 資料夾
Remove-Item -Recurse -Force "$RIME_FOLDER\configs" -ErrorAction SilentlyContinue

# 註冊方案（只追加，不動既有清單）並整理 default.custom.yaml：
# 既有檔案先做時間戳備份；liur（與完整版的 easy_en）不存在才補上；
# patch: 格式重寫成乾淨排版＋註解（冪等），__patch: 複合格式保持原樣。
$defaultCustom = "$RIME_FOLDER\default.custom.yaml"
if (Test-Path $defaultCustom) {
    $backupStamp = Get-Date -Format "yyyyMMdd-HHmmss"
    Copy-Item -Force $defaultCustom "$RIME_FOLDER\default.custom.yaml.backup-$backupStamp"
    Write-Host "  已備份原設定：default.custom.yaml.backup-$backupStamp" -ForegroundColor Green
}
Add-SchemaEntry -SchemaId "liur"
if ($SCHEMA_VERSION -eq "mixed") { Add-SchemaEntry -SchemaId "easy_en" }
$normalized = Convert-RimeDefaultCustom -Path $defaultCustom
if ($normalized) {
    Write-Host "  已整理 default.custom.yaml（乾淨排版＋註解）" -ForegroundColor Green
} else {
    Write-Host "  default.custom.yaml 保留原格式（__patch: 複合格式不動，方案已補齊）" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "[ Step 3: 安裝字體 ]" -ForegroundColor Green

New-Item -ItemType Directory -Force -Path $FONT_FOLDER | Out-Null

$fontCurrent = 0

# 下載共用字體
foreach ($file in $FONT_FILES) {
    $fontCurrent++
    $filename = Split-Path $file -Leaf
    if (Test-Path "$FONT_FOLDER\$filename") {
        Show-Progress -Current $fontCurrent -Total $TOTAL_FONTS -FileName "$filename [skip]"
    } else {
        Show-Progress -Current $fontCurrent -Total $TOTAL_FONTS -FileName $filename
        Invoke-WebRequest -Uri "$GITHUB_RAW/$file" -OutFile "$FONT_FOLDER\$filename" | Out-Null
    }
}

# Windows 額外字體
foreach ($file in $FONT_FILES_WIN) {
    $fontCurrent++
    $filename = Split-Path $file -Leaf
    if (Test-Path "$FONT_FOLDER\$filename") {
        Show-Progress -Current $fontCurrent -Total $TOTAL_FONTS -FileName "$filename [skip]"
    } else {
        $encodedPath = $file -replace " ", "%20"
        Show-Progress -Current $fontCurrent -Total $TOTAL_FONTS -FileName $filename
        Invoke-WebRequest -Uri "$GITHUB_RAW/$encodedPath" -OutFile "$FONT_FOLDER\$filename" | Out-Null
    }
}

Write-Host ""  # 換行

Write-Host ""
Write-Host "[ Step 4: 部署 RIME ]" -ForegroundColor Green
Write-Host ""
Write-Host "請手動重新部署小狼毫（右鍵點擊系統匣圖示 → 重新部署）" -ForegroundColor Yellow
Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "  蝦米輸入方案 安裝完成 可開始使用 ✨" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Rime 資料夾：$RIME_FOLDER"
Write-Host "字體資料夾：$FONT_FOLDER"
Write-Host ""
Write-Host "更多資訊請參考：https://ryanwuson.github.io/rime-liur/"
