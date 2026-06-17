<#
.SYNOPSIS
    Scoop 批量安装软件列表
.DESCRIPTION
    自动批量全局安装软件列表
.NOTES
    全局安装 (-g) 需要管理员权限
#>

# 管理员权限检查
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "✘ 需要管理员权限运行" -ForegroundColor Red
    exit 1
}
Write-Host "✔ 管理员权限确认`n" -ForegroundColor Green

# 清理缓存并更新 Scoop
Write-Host "正在清理缓存并更新 Scoop..." -ForegroundColor Yellow
scoop cache rm * 2>$null
scoop update
Write-Host "✔ Scoop 更新完成`n" -ForegroundColor Green

# -----------------------------------------------
# 安装 Python 环境（普通安装，作为依赖）
# -----------------------------------------------
$pythonList = @(
    @{ Name = "python27"; Bucket = "versions" },
    @{ Name = "python310"; Bucket = "versions" }
)

Write-Host "========== 安装 Python 环境 ==========" -ForegroundColor Yellow

foreach ($py in $pythonList) {
    $appName = "$($py.Bucket)/$($py.Name)"
    Write-Host "[..] 安装 $appName ..." -ForegroundColor Cyan

    # 检查是否已安装
    $installed = scoop list 2>$null | Select-String "^\s*$($py.Name)\s"
    if ($installed) {
        Write-Host "✔ $($py.Name) 已安装，跳过" -ForegroundColor DarkGray
        continue
    }

    scoop install $appName
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✔ $($py.Name) 安装成功" -ForegroundColor Green
    } else {
        Write-Host "✘ $($py.Name) 安装失败（退出码: $LASTEXITCODE）" -ForegroundColor Red
    }
}

# -----------------------------------------------
# 安全工具列表（全部全局安装）
# -----------------------------------------------
$apps = @(
    "sec/afrog",
    "sec/AntSword",
    "sec/Behinder",
    "sec/Godzilla",
    "sec/BlueTeamTools",
    "sec/dirsearch",
    "sec/fscan",
    "sec/httpx",
    "sec/nuclei",
    "sec/sqlmap",
    "lcarea/TscanPlus",
    "sec/xray"
)

# 统计变量
$successList = [System.Collections.Generic.List[string]]::new()
$failList    = [System.Collections.Generic.List[string]]::new()
$skipList    = [System.Collections.Generic.List[string]]::new()

Write-Host "`n========== 开始批量全局安装安全工具 ==========" -ForegroundColor Yellow
Write-Host "共 $($apps.Count) 个工具待安装`n" -ForegroundColor Gray

$index = 0
foreach ($app in $apps) {
    $index++
    $appShortName = $app -replace '^.+/', ''  # 去掉 bucket 前缀

    Write-Host "[$index/$($apps.Count)] 正在安装: $app [全局]" -ForegroundColor Cyan

    # 检查是否已安装
    $installed = scoop list 2>$null | Select-String "^\s*$appShortName\s"
    if ($installed) {
        Write-Host "✔ $app 已安装，跳过" -ForegroundColor DarkGray
        $skipList.Add($app)
        Write-Host ("-" * 50) -ForegroundColor DarkGray
        continue
    }

    # 执行全局安装
    scoop install $app -g
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
        $successList.Add($app)
        Write-Host "✔ $app 安装成功" -ForegroundColor Green
    } else {
        $failList.Add($app)
        Write-Host "✘ $app 安装失败（退出码: $exitCode）" -ForegroundColor Red
    }

    Write-Host ("-" * 50) -ForegroundColor DarkGray
}

# -----------------------------------------------
# 安装结果汇总
# -----------------------------------------------
Write-Host "`n========== 安装结果汇总 ==========" -ForegroundColor Yellow
Write-Host "总计: $($apps.Count) | 成功: $($successList.Count) | 失败: $($failList.Count) | 跳过: $($skipList.Count)" -ForegroundColor Gray

if ($successList.Count -gt 0) {
    Write-Host "`n✔ 成功安装 ($($successList.Count)):" -ForegroundColor Green
    $successList | ForEach-Object { Write-Host "   - $_" -ForegroundColor Green }
}

if ($skipList.Count -gt 0) {
    Write-Host "`n- 已跳过 ($($skipList.Count)):" -ForegroundColor DarkGray
    $skipList | ForEach-Object { Write-Host "   - $_" -ForegroundColor DarkGray }
}

if ($failList.Count -gt 0) {
    Write-Host "`n✘ 安装失败 ($($failList.Count)):" -ForegroundColor Red
    $failList | ForEach-Object { Write-Host "   - $_" -ForegroundColor Red }

    Write-Host "`n提示：失败的应用可手动执行以下命令重试:" -ForegroundColor Yellow
    $failList | ForEach-Object {
        Write-Host "   scoop install $_ -g" -ForegroundColor Gray
    }
}

Write-Host "`n使用 'scoop list' 查看所有已安装软件`n" -ForegroundColor Cyan