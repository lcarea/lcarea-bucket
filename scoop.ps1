#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ==================================================
# 辅助函数
# ==================================================

function Write-Step {
    param([string]$m)
    Write-Host ""
    Write-Host "=== $m ===" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$m)
    Write-Host "[OK] $m" -ForegroundColor Green
}

function Write-Failure {
    param([string]$m)
    Write-Host "[NG] $m" -ForegroundColor Red
}

function Write-Info {
    param([string]$m)
    Write-Host "[..] $m" -ForegroundColor Yellow
}

function Write-Skip {
    param([string]$m)
    Write-Host "[>>] $m" -ForegroundColor DarkGray
}

function Refresh-EnvPath {
    $mp    = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $up    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $paths = @($mp, $up) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd(';') }
    $env:Path = $paths -join ';'
}

function Invoke-External {
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [string[]]$Arguments = @(),

        [switch]$PassThru,
        [switch]$Silent
    )

    # ✅ StrictMode 下 $LASTEXITCODE 可能从未被赋值，提前声明默认值
    $exitCode = 0

    if ($Silent) {
        $output   = & $Command @Arguments 2>&1
        $exitCode = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    }
    elseif ($PassThru) {
        $output   = & $Command @Arguments 2>&1
        $exitCode = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    }
    else {
        & $Command @Arguments
        $exitCode = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        return $exitCode
    }

    if ($PassThru) {
        return [PSCustomObject]@{
            ExitCode = $exitCode
            Output   = $output
        }
    }

    return $exitCode
}

function Test-NetworkAccess {
    param(
        [string]$Url,
        [int]$TimeoutSec = 8,
        [int]$Retry      = 2
    )

    for ($i = 0; $i -lt $Retry; $i++) {
        try {
            $response = Invoke-WebRequest `
                -Uri             $Url `
                -UseBasicParsing `
                -TimeoutSec      $TimeoutSec `
                -Method          Head `
                -ErrorAction     Stop

            if ($response.StatusCode -lt 400) {
                return $true
            }
        }
        catch {
            Start-Sleep -Seconds 1
        }
    }

    return $false
}

function Invoke-SecureDownload {
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [Parameter(Mandatory)] [string]$OutFile,
        [string]$ExpectedHash = ''
    )

    Write-Info "下载: $Uri"

    try {
        Invoke-RestMethod -Uri $Uri -OutFile $OutFile -ErrorAction Stop
    }
    catch {
        throw "下载失败 [$Uri]: $_"
    }

    if (-not (Test-Path $OutFile)) {
        throw "下载后文件不存在: $OutFile"
    }

    if ([string]::IsNullOrEmpty($ExpectedHash)) {
        Write-Info "未提供期望哈希，跳过完整性校验"
        return
    }

    Write-Info "校验文件完整性 (SHA256)..."
    $actualHash = (Get-FileHash -Path $OutFile -Algorithm SHA256).Hash

    if ($actualHash -ne $ExpectedHash.ToUpper()) {
        Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
        throw "哈希校验失败!`n  期望: $($ExpectedHash.ToUpper())`n  实际: $actualHash"
    }

    Write-Success "哈希校验通过"
}

function Get-ScoopBucketNames {
    $result = Invoke-External -Command 'scoop' -Arguments @('bucket', 'list') -PassThru

    if ($result.ExitCode -ne 0 -or -not $result.Output) {
        return [string[]]@()
    }

    [string[]]$names = @(
        $result.Output | ForEach-Object {
            $line = $_.ToString().Trim()
            if ($line -and $line -notmatch '^(Name|--|-+)$') {
                ($line -split '\s+')[0]
            }
        } | Where-Object { $_ }
    )

    return $names
}

# ==================================================
# Step 1: 环境检测
# ==================================================
Write-Step "Step 1: 环境检测"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Failure "需要 PowerShell 5.1+，当前版本: $($PSVersionTable.PSVersion)"
    exit 1
}
Write-Success "PowerShell 版本: $($PSVersionTable.PSVersion)"

$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
$isAdmin     = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Info "管理员身份: $isAdmin"

$scoopInstalled = [bool](Get-Command scoop -ErrorAction SilentlyContinue)
if ($scoopInstalled) {
    Write-Info "Scoop 已安装"
}
else {
    Write-Info "Scoop 未安装，稍后将安装"
}

# ==================================================
# Step 2: 网络连通性检测
# ==================================================
Write-Step "Step 2: 网络连通性检测"

$networkTargets = @(
    [PSCustomObject]@{ Label = "Scoop 官网"; Url = "https://get.scoop.sh"              }
    [PSCustomObject]@{ Label = "GitHub";     Url = "https://github.com"                }
    [PSCustomObject]@{ Label = "GitHub Raw"; Url = "https://raw.githubusercontent.com" }
)

$networkFailed = [System.Collections.Generic.List[string]]::new()

foreach ($target in $networkTargets) {
    Write-Info "检测 $($target.Label) ($($target.Url))..."

    if (Test-NetworkAccess -Url $target.Url) {
        Write-Success "$($target.Label) 可达"
    }
    else {
        Write-Failure "$($target.Label) 不可达"
        $networkFailed.Add($target.Label)
    }
}

if ($networkFailed.Count -gt 0) {
    Write-Host ""
    Write-Failure "以下网络目标无法访问，可能导致安装失败:"
    foreach ($f in $networkFailed) {
        Write-Host "  - $f" -ForegroundColor Red
    }
    Write-Host ""
    $choice = Read-Host "是否仍然继续? (y/N)"
    if ($choice -notmatch '^[yY]$') {
        Write-Info "用户取消，退出"
        exit 0
    }
}
else {
    Write-Success "所有网络目标均可达"
}

# ==================================================
# Step 3: 配置执行策略
# ==================================================
Write-Step "Step 3: 配置执行策略"

try {
    $currentPolicy = Get-ExecutionPolicy -Scope CurrentUser
    if ($currentPolicy -in @('RemoteSigned', 'Unrestricted', 'Bypass')) {
        Write-Skip "执行策略已为 $currentPolicy，跳过"
    }
    else {
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        Write-Success "执行策略已设置为 RemoteSigned（当前用户）"
    }
}
catch {
    Write-Failure "执行策略设置失败: $_"
    exit 1
}

# ==================================================
# Step 4: 安装 Scoop
# ==================================================
Write-Step "Step 4: 安装 Scoop"

if ($scoopInstalled) {
    Write-Skip "Scoop 已存在，跳过安装"
}
else {
    $scoopDir       = 'D:\Scoop\Base'
    $scoopGlobalDir = 'D:\Scoop\Global'

    foreach ($dir in @($scoopDir, $scoopGlobalDir)) {
        if (-not (Test-Path $dir)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            Write-Success "目录已创建: $dir"
        }
        else {
            Write-Skip "目录已存在: $dir"
        }
    }

    $env:SCOOP        = $scoopDir
    $env:SCOOP_GLOBAL = $scoopGlobalDir
    [System.Environment]::SetEnvironmentVariable('SCOOP',        $scoopDir,       'User')
    [System.Environment]::SetEnvironmentVariable('SCOOP_GLOBAL', $scoopGlobalDir, 'User')
    Write-Success "环境变量 SCOOP / SCOOP_GLOBAL 已设置"

    $ts            = Get-Date -Format 'yyyyMMddHHmmss'
    $installScript = Join-Path $env:TEMP "scoop_install_$ts.ps1"

    try {
        Invoke-SecureDownload `
            -Uri          'https://get.scoop.sh' `
            -OutFile      $installScript `
            -ExpectedHash ''

        Write-Success "安装脚本下载成功"

        if ($isAdmin) {
            & $installScript -RunAsAdmin
        }
        else {
            & $installScript
        }

        Refresh-EnvPath

        # ✅ scoop 本身是 PS 脚本，$LASTEXITCODE 不可靠，改用命令存在性检测
        if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
            throw "安装完成后仍无法找到 scoop 命令，请检查安装日志"
        }

        Write-Success "Scoop 安装成功"
    }
    catch {
        Write-Failure "Scoop 安装失败: $_"
        exit 1
    }
    finally {
        if (Test-Path $installScript) {
            Remove-Item $installScript -Force -ErrorAction SilentlyContinue
            Write-Info "临时安装脚本已清理"
        }
    }
}

# ==================================================
# Step 5: 配置 Git
# ==================================================
Write-Step "Step 5: 配置 Git"

Refresh-EnvPath

if (Get-Command git -ErrorAction SilentlyContinue) {
    $gitVer = git --version
    Write-Skip "Git 已安装: $gitVer"
}
else {
    Write-Info "安装 Git..."

    # ✅ scoop install 是 PS 脚本，不依赖 $LASTEXITCODE，用命令存在性检测结果
    scoop install git

    Refresh-EnvPath

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Failure "Git 安装失败，请手动执行: scoop install git"
        exit 1
    }

    Write-Success "Git 安装成功: $(git --version)"
}

# ==================================================
# Step 6: 清理缓存并更新 Scoop
# ==================================================
Write-Step "Step 6: 清理缓存并更新 Scoop"

# 清理 Scoop 临时文件
Remove-Item "$env:LOCALAPPDATA\Temp\*.json" -Force -ErrorAction SilentlyContinue

# 清理缓存并重置 bucket
Write-Host "正在清理并更新 Scoop..." -ForegroundColor Yellow
scoop cache rm * 2>$null
scoop update
Write-Host "✔ Scoop 更新完成`n" -ForegroundColor Green

# ==================================================
# Step 7: 添加 Bucket
# ==================================================
Write-Step "Step 7: 添加 Bucket"

$buckets = @(
    [PSCustomObject]@{ Name = "extras";    Url = "";                                          Tag = "official" }
    [PSCustomObject]@{ Name = "versions";  Url = "";                                          Tag = "official" }
    [PSCustomObject]@{ Name = "apps";      Url = "https://github.com/kkzzhizhou/scoop-apps";  Tag = "cn"       }
    [PSCustomObject]@{ Name = "dorado";    Url = "https://github.com/chawyehsu/dorado";       Tag = "cn"       }
    [PSCustomObject]@{ Name = "scoop-cn";  Url = "https://github.com/duzyn/scoop-cn";         Tag = "cn"       }
    [PSCustomObject]@{ Name = "spc";       Url = "https://github.com/lzwme/scoop-proxy-cn";   Tag = "cn"       }
    [PSCustomObject]@{ Name = "extras-cn"; Url = "https://github.com/Scoopforge/Extras-CN";   Tag = "cn"       }
    [PSCustomObject]@{ Name = "scoopcn";   Url = "https://github.com/scoopcn/scoopcn";        Tag = "cn"       }
    [PSCustomObject]@{ Name = "ar";        Url = "https://github.com/arch3rPro/PST-Bucket";   Tag = "sec"      }
    [PSCustomObject]@{ Name = "sec";       Url = "https://github.com/tldro/scoop-security";   Tag = "sec"      }
    [PSCustomObject]@{ Name = "retools";   Url = "https://github.com/TheCjw/scoop-retools";   Tag = "sec"      }
)

$failedBuckets  = [System.Collections.Generic.List[string]]::new()
$skippedBuckets = [System.Collections.Generic.List[string]]::new()
$addedBuckets   = [System.Collections.Generic.List[string]]::new()

Write-Info "获取已存在的 Bucket 列表..."

# ✅ 强类型数组，防止 StrictMode 下单元素退化为标量导致 .Count 报错
[string[]]$existingBuckets = @()
try {
    $existingBuckets = [string[]]@(Get-ScoopBucketNames)
    if ($existingBuckets.Count -gt 0) {
        Write-Info "已存在 Bucket: $($existingBuckets -join ', ')"
    }
}
catch {
    Write-Info "无法获取已有 Bucket 列表，将全部尝试添加: $_"
}

foreach ($bucket in $buckets) {
    $label = "[$($bucket.Tag)]"

    if ($existingBuckets -contains $bucket.Name) {
        Write-Skip "$label $($bucket.Name) 已存在，跳过"
        $skippedBuckets.Add($bucket.Name)
        continue
    }

    Write-Host "[->] $label 添加 $($bucket.Name)..." -ForegroundColor Gray

    if ([string]::IsNullOrEmpty($bucket.Url)) {
        $exitCode = Invoke-External -Command 'scoop' -Arguments @('bucket', 'add', $bucket.Name) -Silent
    }
    else {
        $exitCode = Invoke-External -Command 'scoop' -Arguments @('bucket', 'add', $bucket.Name, $bucket.Url) -Silent
    }

    if ($exitCode -eq 0) {
        Write-Success "$label $($bucket.Name) 添加成功"
        $addedBuckets.Add($bucket.Name)
    }
    else {
        Write-Failure "$label $($bucket.Name) 添加失败（退出码: $exitCode）"
        $failedBuckets.Add($bucket.Name)
    }
}

# ==================================================
# Step 8: 更新 Bucket 索引
# ==================================================
Write-Step "Step 8: 更新 Bucket 索引"

$exitCode = Invoke-External -Command 'scoop' -Arguments @('update') -Silent
if ($exitCode -eq 0) {
    Write-Success "Bucket 索引更新完成"
}
else {
    Write-Info "Bucket 索引更新出现警告（退出码: $exitCode），继续..."
}

# ==================================================
# Step 9: 配置 PowerShell Profile 及 PSModulePath
# ⚠️ 必须在安装 scoop-completion 之前执行，
#    否则 scoop-completion 的 post_install 脚本
#    会因找不到模块路径而报错
# ==================================================
Write-Step "Step 9: 配置 PowerShell Profile"

$profilePath = $PROFILE.CurrentUserCurrentHost
Write-Info "Profile 路径: $profilePath"

if (-not (Test-Path -Path $profilePath)) {
    New-Item -Path $profilePath -ItemType File -Force | Out-Null
    Write-Success "Profile 文件已创建"
}
else {
    Write-Skip "Profile 文件已存在"
}

$scoopBase       = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
$scoopModulePath = Join-Path $scoopBase 'modules'
Write-Info "Scoop 模块路径: $scoopModulePath"

$existingContent = ''
try {
    $existingContent = Get-Content -Path $profilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
}
catch { }
$existingContent = if ($existingContent) { $existingContent } else { '' }

$configBlocks = @(
    [PSCustomObject]@{
        Marker  = $scoopModulePath
        Content = @(
            ""
            "# Scoop 模块路径（由安装脚本自动写入）"
            "`$env:PSModulePath += `";$scoopModulePath`""
        )
        Label   = "PSModulePath 配置"
    }
    [PSCustomObject]@{
        Marker  = 'Import-Module scoop-completion'
        Content = @(
            ""
            "# Scoop Tab 补全（由安装脚本自动写入）"
            "Import-Module scoop-completion"
        )
        Label   = "scoop-completion 导入"
    }
)

$profileUpdated = $false

foreach ($block in $configBlocks) {
    if ($existingContent.Contains($block.Marker)) {
        Write-Skip "$($block.Label) 已存在于 Profile，跳过"
    }
    else {
        Add-Content -Path $profilePath -Value ($block.Content -join "`n") -Encoding UTF8
        Write-Success "$($block.Label) 已写入 Profile"
        $profileUpdated = $true
    }
}

if (-not $profileUpdated) {
    Write-Skip "Profile 无需更新"
}

# ✅ 关键修复：先更新当前会话的 PSModulePath，
#    再安装 scoop-completion，确保其 post_install 脚本能找到模块
if ($env:PSModulePath -notlike "*$scoopModulePath*") {
    $env:PSModulePath += ";$scoopModulePath"
    Write-Success "当前会话 PSModulePath 已更新: $scoopModulePath"
}
else {
    Write-Skip "PSModulePath 已包含 Scoop 模块路径"
}

# ==================================================
# Step 10: 安装扩展工具
# ==================================================
Write-Step "Step 10: 安装扩展工具"

$extensions = @(
    [PSCustomObject]@{ Name = 'scoop-search';     Desc = '快速搜索替代 scoop search' }
    [PSCustomObject]@{ Name = 'scoop-completion'; Desc = 'PowerShell Tab 自动补全'   }
)

foreach ($ext in $extensions) {
    Write-Host "[->] 安装 $($ext.Name) ($($ext.Desc))..." -ForegroundColor Gray

    $listResult  = Invoke-External -Command 'scoop' -Arguments @('list', $ext.Name) -PassThru
    $isInstalled = ($listResult.Output | ForEach-Object { $_.ToString() }) -match "^\s*$([regex]::Escape($ext.Name))\s"

    if ($isInstalled) {
        Write-Skip "$($ext.Name) 已安装，跳过"
        continue
    }

    $exitCode = Invoke-External -Command 'scoop' -Arguments @('install', $ext.Name) -Silent
    if ($exitCode -eq 0) {
        Write-Success "$($ext.Name) 安装成功"
    }
    else {
        Write-Failure "$($ext.Name) 安装失败（退出码: $exitCode）"
    }
}

# ==================================================
# Step 11: 加载 scoop-completion（当前会话）
# ==================================================
Write-Step "Step 11: 加载 scoop-completion"

try {
    Import-Module scoop-completion -ErrorAction Stop
    Write-Success "scoop-completion 模块加载成功（当前会话生效）"
}
catch {
    Write-Info "scoop-completion 模块加载失败，重启 PowerShell 后生效: $_"
}

# ==================================================
# Step 12: 重装 7zip（使用本地 manifest 安装 v24.09）
# ==================================================
Write-Host "`n[Step 12] 重装 7zip → v24.09 (本地 manifest)" -ForegroundColor Cyan

# 静默卸载 7zip
$ErrorActionPreference = 'SilentlyContinue'
scoop uninstall 7zip *> $null
$ErrorActionPreference = 'Stop'

# 验证卸载结果
$still7zip = scoop list 2>$null | Select-String '^\s*7zip\s'
if (-not $still7zip) {
    Write-Host "✔ 7zip 卸载成功" -ForegroundColor Green
} else {
    Write-Host "[..] 7zip 可能未完全卸载，继续尝试安装..." -ForegroundColor Yellow
}

$downloadUrl= "https://www.7-zip.org/a/7z2409-x64.exe"
$installerPath = Join-Path $env:TEMP "7z2409-x64.exe"
$manifestPath  = Join-Path $env:TEMP "7zip.json"

Write-Host "[..] 下载 7zip v24.09 安装包..." -ForegroundColor Yellow

try {
    # 下载安装包
    Invoke-WebRequest -Uri $downloadUrl -OutFile $installerPath -UseBasicParsing

    if (-not (Test-Path $installerPath)) { throw "下载失败，文件不存在" }

    $fileSize = [math]::Round((Get-Item $installerPath).Length / 1MB, 2)
    Write-Host "✔ 下载完成 ($fileSize MB)" -ForegroundColor Green

    # 计算真实 hash
    Write-Host "[..] 计算文件 hash..." -ForegroundColor Yellow
    $actualHash = (Get-FileHash -Path $installerPath -Algorithm SHA256).Hash.ToLower()
    Write-Host "✔ SHA256: $actualHash" -ForegroundColor Green

    # 生成 manifest
    $manifestContent = @"
{
    "version": "24.09",
    "description": "7-Zip v24.09",
    "homepage": "https://www.7-zip.org/",
    "license": "LGPL-2.1-or-later",
    "architecture": {
        "64bit": {
            "url": "https://www.7-zip.org/a/7z2409-x64.exe",
            "hash": "sha256:$actualHash"
        }
    },
    "installer": {
        "script": [
            "Start-Process -FilePath \"`$dir\\`$fname\" -ArgumentList '/S', \"/D=`$dir\" -Wait -NoNewWindow"
        ]
    },
    "uninstaller": {
        "script": [
            "Start-Process -FilePath \"`$dir\\Uninstall.exe\" -ArgumentList '/S' -Wait -NoNewWindow -ErrorAction SilentlyContinue"
        ]
    },
    "bin": "7z.exe",
    "shortcuts": [
        ["7zFM.exe", "7-Zip"]
    ]
}
"@

    # 验证 JSON 格式
    $null = $manifestContent | ConvertFrom-Json
    Write-Host "✔ JSON 格式验证通过" -ForegroundColor Green

    $manifestContent | Out-File -FilePath $manifestPath -Encoding UTF8 -Force

    Write-Host "[..] 使用本地 manifest 安装 7zip v24.09..." -ForegroundColor Yellow
    scoop install $manifestPath
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
        Write-Host "✔ 7zip v24.09 安装成功" -ForegroundColor Green

        # -----------------------------------------------
        # 修复：Start-Process -ArgumentList 必须用数组形式
        # 不能在参数之间用反引号换行（会误当positional参数）
        # -----------------------------------------------
        $7zExe = Join-Path $env:SCOOP "apps\7zip\current\7z.exe"
        if (Test-Path $7zExe) {
            $verFile = Join-Path $env:TEMP "7z_ver.txt"

            # 正确写法：所有参数写在同一行，或用splatting
            $startParams = @{
                FilePath               = $7zExe
                ArgumentList           = @("i")
                NoNewWindow            = $true
                Wait                   = $true
                RedirectStandardOutput = $verFile
                ErrorAction            = "SilentlyContinue"
            }
            Start-Process @startParams

            $verText = Get-Content $verFile -ErrorAction SilentlyContinue |Select-String '7-Zip' |
                       Select-Object -First 1

            Remove-Item $verFile -Force -ErrorAction SilentlyContinue

            if ($verText) {
                Write-Host "✔ 版本验证: $verText" -ForegroundColor Green
            } else {
                Write-Host "✔ 7z.exe 存在，安装完成" -ForegroundColor Green
            }
        } else {
            Write-Host "[!] 7z.exe 未找到，请检查安装路径" -ForegroundColor Yellow
        }
    } else {
        Write-Host "✘ 7zip v24.09 安装失败（退出码: $exitCode）" -ForegroundColor Red
    }
}
catch {
    Write-Host "✘ 安装过程异常: $_" -ForegroundColor Red
}
finally {
    foreach ($f in @($installerPath, $manifestPath)) {
        if ($f -and (Test-Path $f)) {
            Remove-Item $f -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "[..] 临时文件已清理" -ForegroundColor DarkGray
}

# ==================================================
# Step 13: 汇总报告
# ==================================================
Write-Step "Step 13: 汇总报告"

$totalBuckets = $buckets.Count
$successCount = $addedBuckets.Count
$skippedCount = $skippedBuckets.Count
$failedCount  = $failedBuckets.Count

Write-Host ""
Write-Host "┌─────────────────────────────────┐" -ForegroundColor Cyan
Write-Host "│           Bucket 汇总            │" -ForegroundColor Cyan
Write-Host "├─────────────────────────────────┤" -ForegroundColor Cyan
Write-Host "│  总计 : $($totalBuckets.ToString().PadRight(24))│" -ForegroundColor Cyan
Write-Host "│  新增 : $($successCount.ToString().PadRight(24))│" -ForegroundColor Green
Write-Host "│  跳过 : $($skippedCount.ToString().PadRight(24))│" -ForegroundColor DarkGray
Write-Host "│  失败 : $($failedCount.ToString().PadRight(24))│" -ForegroundColor $(if ($failedCount -gt 0) { 'Red' } else { 'Cyan' })
Write-Host "└─────────────────────────────────┘" -ForegroundColor Cyan

if ($addedBuckets.Count -gt 0) {
    Write-Host ""
    Write-Host "新增的 Bucket:" -ForegroundColor Green
    foreach ($b in $addedBuckets) {
        Write-Host "  + $b" -ForegroundColor Green
    }
}

if ($failedBuckets.Count -gt 0) {
    Write-Host ""
    Write-Host "失败的 Bucket（可手动重试）:" -ForegroundColor Red
    foreach ($b in $failedBuckets) {
        Write-Host "  - $b" -ForegroundColor Red
        $bObj = $buckets | Where-Object { $_.Name -eq $b }
        if ($bObj.Url) {
            Write-Host "    → scoop bucket add $b $($bObj.Url)" -ForegroundColor DarkGray
        }
        else {
            Write-Host "    → scoop bucket add $b" -ForegroundColor DarkGray
        }
    }
}

Write-Host ""
Write-Host "扩展工具说明:" -ForegroundColor Cyan
Write-Host "  scoop-search     使用 'scoop-search <名称>' 替代 'scoop search'（更快）" -ForegroundColor Gray
Write-Host "  scoop-completion 重启 PowerShell 后 Tab 补全生效"                         -ForegroundColor Gray

Write-Host ""
Write-Host "常用命令速查:" -ForegroundColor Cyan
Write-Host "  scoop install <软件名>      安装软件"          -ForegroundColor Gray
Write-Host "  scoop-search  <软件名>      快速搜索软件"      -ForegroundColor Gray
Write-Host "  scoop update  *             更新所有已装软件"  -ForegroundColor Gray
Write-Host "  scoop list                  查看已安装列表"    -ForegroundColor Gray
Write-Host "  scoop bucket list           查看已添加 Bucket" -ForegroundColor Gray
Write-Host "  scoop uninstall <软件名>    卸载软件"          -ForegroundColor Gray
Write-Host "  scoop cleanup *             清理旧版本缓存"    -ForegroundColor Gray

Write-Host ""
Write-Host "安装路径:" -ForegroundColor Cyan
Write-Host "  用户软件: $env:SCOOP"        -ForegroundColor Gray
Write-Host "  全局软件: $env:SCOOP_GLOBAL" -ForegroundColor Gray
Write-Host "  Profile : $profilePath"      -ForegroundColor Gray

Write-Host ""
if ($failedCount -eq 0) {
    Write-Success "全部完成！请重启 PowerShell 使 Tab 补全生效。"
}
else {
    Write-Info "完成（存在 $failedCount 个 Bucket 添加失败，请检查网络后手动重试）。"
    Write-Info "请重启 PowerShell 使 Tab 补全生效。"
}
