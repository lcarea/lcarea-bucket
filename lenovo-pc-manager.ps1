# 联想电脑管家 Scoop 安装脚本（7zip 直接解压版）

$ErrorActionPreference = "Continue"
$appName = "lenovo-pc-manager"

Write-Host "`n════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  联想电脑管家 - 7zip 直接解压安装" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════`n" -ForegroundColor Cyan

# 确保 7zip 已安装
Write-Host "[0/4] 检查依赖..." -ForegroundColor Yellow
if (!(Get-Command 7z.exe -ErrorAction SilentlyContinue)) {
    Write-Host "正在安装 7zip..." -ForegroundColor Gray
    scoop install 7zip
}
Write-Host "✓ 7zip 就绪`n" -ForegroundColor Green

# 获取 Scoop 路径
$scoopPath = scoop prefix scoop
$bucketsPath = Split-Path $scoopPath
$localBucketPath = Join-Path $bucketsPath "local-apps"

# ===== 步骤 1: 准备 Bucket =====
Write-Host "[1/4] 准备 Bucket..." -ForegroundColor Yellow
if (!(Test-Path "$localBucketPath\bucket")) {
    New-Item -ItemType Directory -Path "$localBucketPath\bucket" -Force | Out-Null
}

Push-Location $localBucketPath
if (!(Test-Path ".git")) {
    git init -b main 2>&1 | Out-Null
    git config user.name "Local" 2>&1 | Out-Null
    git config user.email "local@local" 2>&1 | Out-Null
}
Pop-Location
Write-Host "✓ Bucket 就绪`n" -ForegroundColor Green

# ===== 步骤 2: 创建清单（7zip解压版） =====
Write-Host "[2/4] 创建安装清单..." -ForegroundColor Yellow

$manifest = @'
{
    "version": "5.0.50.12151",
    "description": "联想电脑管家 - 联想官方系统优化和管理工具",
    "homepage": "https://guanjia.lenovo.com.cn/",
    "license": "Freeware",
    "url": "https://guanjia-fast.lenovo.com.cn/download/lenovopcmanager_apps.exe",
    "hash": "0791aa2c229be81739527f356291a0d6b2bbcc6eab6d2cc928eefcbdfdbb6679",
    "installer": {
        "script": [
            "$ErrorActionPreference = 'Continue'",
            "Write-Host '使用 7zip 解压安装包...' -ForegroundColor Cyan",
            "",
            "$exePath = Join-Path $dir $fname",
            "$7z = Get-Command 7z -ErrorAction Stop",
            "",
            "Write-Host '正在解压文件...' -ForegroundColor Yellow",
            "& $7z x \"-o$dir\" \"$exePath\" -y | Out-Null",
            "",
            "Remove-Item $exePath -Force -ErrorAction SilentlyContinue",
            "",
            "Write-Host '查找可执行文件...' -ForegroundColor Yellow",
            "$exes = Get-ChildItem $dir -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'unins*' -and $_.Name -notlike '*.tmp.exe' }",
            "",
            "if ($exes) {",
            "    Write-Host \"找到 $($exes.Count) 个可执行文件:\" -ForegroundColor Green",
            "    $exes | Sort-Object Length -Descending | ForEach-Object {",
            "        $size = [math]::Round($_.Length / 1MB, 2)",
            "        Write-Host \"  [$size MB] $($_.Name)\" -ForegroundColor Gray",
            "    }",
            "} else {",
            "    Write-Host '未找到可执行文件' -ForegroundColor Red",
            "}",
            "",
            "$totalFiles = (Get-ChildItem $dir -Recurse -File).Count",
            "Write-Host \"总计提取 $totalFiles 个文件\" -ForegroundColor Green"
        ]
    },
    "uninstaller": {
        "script": [
            "$uninst = Get-ChildItem $dir -Recurse -Filter 'unins*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1",
            "if ($uninst) {",
            "    Write-Host \"运行卸载程序: $($uninst.Name)\" -ForegroundColor Yellow",
            "    Start-Process -FilePath $uninst.FullName -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait -WindowStyle Hidden",
            "}"
        ]
    },
    "checkver": {
        "url": "https://guanjia.lenovo.com.cn/",
        "regex": "版本号[：:]\\s*([\\d.]+)"
    }
}
'@

$manifestPath = "$localBucketPath\bucket\$appName.json"
$manifest | Set-Content -Path $manifestPath -Encoding UTF8

Push-Location $localBucketPath
git add . 2>&1 | Out-Null
git commit -m "Update $appName - 7zip extraction" --allow-empty 2>&1 | Out-Null
Pop-Location

try {
    Get-Content $manifestPath -Raw | ConvertFrom-Json | Out-Null
    Write-Host "✓ 清单验证通过`n" -ForegroundColor Green
} catch {
    Write-Host "✗ 清单格式错误: $_`n" -ForegroundColor Red
    exit 1
}

# ===== 步骤 3: 执行安装 =====
Write-Host "[3/4] 开始安装..." -ForegroundColor Yellow
Write-Host "════════════════════════════════════════════════`n" -ForegroundColor DarkGray
scoop install $manifestPath
Write-Host "`n════════════════════════════════════════════════" -ForegroundColor DarkGray

# ===== 步骤 4: 安装后处理 =====
Write-Host "`n[4/4] 验证安装结果..." -ForegroundColor Yellow
Start-Sleep -Seconds 2

$installPath = scoop prefix $appName 2>$null

if ($installPath -and (Test-Path $installPath)) {
    Write-Host "✓ 安装目录: $installPath`n" -ForegroundColor Green
    
    # 查找可执行文件
    $exeFiles = Get-ChildItem $installPath -Recurse -Filter "*.exe" -ErrorAction SilentlyContinue | 
                Where-Object { $_.Name -notlike 'unins*' -and $_.Name -notlike '*.tmp.exe' }
    
    if ($exeFiles.Count -gt 0) {
        Write-Host "可执行文件列表:" -ForegroundColor Cyan
        $exeFiles | Sort-Object Length -Descending | ForEach-Object {
            $relPath = $_.FullName.Replace("$installPath\", "")
            $size = [math]::Round($_.Length / 1MB, 2)
            $marker = if ($size -gt 5) { "🎯" } elseif ($size -gt 1) { "⭐" } else { "  " }
            Write-Host "  $marker [$size MB] $relPath" -ForegroundColor Gray
        }
        
        # 智能识别主程序
        $mainExe = $exeFiles | Where-Object { 
            ($_.Name -match "Lenovo.*Manager|LenovoPC|PCManager") -and $_.Length -gt 1MB 
        } | Sort-Object Length -Descending | Select-Object -First 1
        
        if (!$mainExe) {
            $mainExe = $exeFiles | Sort-Object Length -Descending | Select-Object -First 1
        }
        
        if ($mainExe) {
            Write-Host "`n推荐主程序: $($mainExe.Name)" -ForegroundColor Green
            Write-Host "完整路径: $($mainExe.FullName)`n" -ForegroundColor Gray
            
            # 创建快捷方式
            try {
                $shortcutPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\联想电脑管家.lnk"
                $shell = New-Object -ComObject WScript.Shell
                $shortcut = $shell.CreateShortcut($shortcutPath)
                $shortcut.TargetPath = $mainExe.FullName
                $shortcut.WorkingDirectory = $mainExe.DirectoryName
                $shortcut.Save()
                Write-Host "✓ 已创建开始菜单快捷方式" -ForegroundColor Green
            } catch {
                Write-Host "⚠ 创建快捷方式失败: $_" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "⚠ 未找到可执行文件，显示目录内容:" -ForegroundColor Yellow
        Get-ChildItem $installPath -Recurse | Select-Object -First 30 | ForEach-Object {
            $type = if ($_.PSIsContainer) { "📁" } else { "📄" }
            $size = if (!$_.PSIsContainer) { " [$([math]::Round($_.Length/1KB,1)) KB]" } else { "" }
            Write-Host "  $type $($_.Name)$size" -ForegroundColor Gray
        }
    }
    
    $totalSize = [math]::Round((Get-ChildItem $installPath -Recurse -File | Measure-Object Length -Sum).Sum / 1MB, 2)
    Write-Host "`n安装统计: $totalSize MB" -ForegroundColor Cyan
} else {
    Write-Host "✗ 安装失败`n" -ForegroundColor Red
}

Write-Host "`n════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "快速命令:" -ForegroundColor Yellow
Write-Host "  scoop prefix $appName         # 查看安装路径" -ForegroundColor Gray
Write-Host "  scoop uninstall $appName      # 卸载" -ForegroundColor Gray
Write-Host "════════════════════════════════════════════════`n" -ForegroundColor Cyan
