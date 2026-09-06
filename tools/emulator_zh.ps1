#!/usr/bin/env pwsh
#requires -Version 5.1
<#
.SYNOPSIS
    启动 Android 模拟器并设置为东八区时区（SDK/AVD 自动探测，跨机器可移植）

.DESCRIPTION
    与旧版不同，不再硬编码 %LOCALAPPDATA%\Android\Sdk，SDK 根目录按以下顺序探测：
      1. android/local.properties 的 sdk.dir（Flutter 工程标准做法，随仓库各机器各配）
      2. ANDROID_HOME / ANDROID_SDK_ROOT 环境变量
      3. %LOCALAPPDATA%\Android\Sdk 等常见默认位置
    AVD 名称按以下顺序解析：
      1. -EmulatorName 参数
      2. ANDROID_AVD_HOME（或 ~/.android/avd）下唯一可用的 .ini

.PARAMETER EmulatorName
    模拟器名称；缺省时自动探测本机唯一的 AVD

.EXAMPLE
    .\emulator_zh.ps1
    有真机在线时跳过；模拟器在线时唤醒后跳过；否则启动探测到的 AVD 并设置时区

.EXAMPLE
    .\emulator_zh.ps1 -EmulatorName "Pixel_8_API_37"
    启动指定模拟器

.NOTES
    需要 PowerShell 7（pwsh）。被 .vscode F5 的 preLaunchTask 复用，非交互安全。
#>

param(
    [Parameter()]
    [string]$EmulatorName = ""
)

$ErrorActionPreference = "Stop"

function Find-AndroidSdkRoot {
    $candidates = @()

    # 1. Flutter 工程 android/local.properties（路径形如 D:\\Android\\Sdk，需还原反斜杠）
    $localProps = Join-Path $PSScriptRoot "..\android\local.properties"
    if (Test-Path $localProps) {
        $sdkDir = (Select-String -Path $localProps -Pattern '^\s*sdk\.dir\s*=\s*(.+)$').Matches |
            ForEach-Object { $_.Groups[1].Value.Trim() } | Select-Object -First 1
        if ($sdkDir) { $candidates += $sdkDir -replace '\\\\', '\' }
    }

    # 2. 环境变量
    if ($env:ANDROID_HOME) { $candidates += $env:ANDROID_HOME }
    if ($env:ANDROID_SDK_ROOT) { $candidates += $env:ANDROID_SDK_ROOT }

    # 3. 常见默认位置
    $candidates += @(
        "$env:LOCALAPPDATA\Android\Sdk",
        "$env:SystemDrive\Android\Sdk",
        "D:\Android\Sdk"
    )

    foreach ($c in $candidates | Select-Object -Unique) {
        if ($c -and (Test-Path (Join-Path $c "platform-tools\adb.exe"))) {
            return (Resolve-Path $c).Path
        }
    }
    return $null
}

function Find-AvdName {
    param([string]$Requested)

    if ($Requested) { return $Requested }

    $avdHome = $env:ANDROID_AVD_HOME
    if (-not $avdHome) { $avdHome = "$env:USERPROFILE\.android\avd" }
    $ini = Get-ChildItem -Path $avdHome -Filter *.ini -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($ini) { return $ini.BaseName }
    return $null
}

$AndroidSdk = Find-AndroidSdkRoot
if (-not $AndroidSdk) {
    Write-Error "未找到 Android SDK：请检查 android/local.properties 的 sdk.dir、ANDROID_HOME 或默认安装位置"
    exit 1
}
$EmulatorPath = "$AndroidSdk\emulator\emulator.exe"
$AdbPath = "$AndroidSdk\platform-tools\adb.exe"

if (-not (Test-Path $EmulatorPath)) {
    Write-Error "找不到 emulator.exe（SDK: $AndroidSdk），请安装 emulator 组件"
    exit 1
}

$AvdName = Find-AvdName -Requested $EmulatorName
if (-not $AvdName) {
    Write-Error "未指定 -EmulatorName 且未在本机找到任何 AVD（已查找 ANDROID_AVD_HOME / ~\.android\avd）"
    exit 1
}

function Set-ChinaTimezone {
    param(
        [string]$AdbExe
    )

    Write-Host ""
    Write-Host "配置时区为东八区..." -ForegroundColor Green

    # 禁用自动时间和时区
    & $AdbExe shell settings put global auto_time 0 | Out-Null
    & $AdbExe shell settings put global auto_time_zone 0 | Out-Null

    # 设置时区为 GMT+8 (东八区)
    & $AdbExe shell settings put global time_zone GMT+8 | Out-Null

    # 设置24小时制
    & $AdbExe shell settings put system time_12_24 24 | Out-Null

    # 验证设置
    Write-Host ""
    Write-Host "验证时区配置:" -ForegroundColor Cyan
    $currentTimezone = & $AdbExe shell settings get global time_zone
    $currentTime = & $AdbExe shell date

    Write-Host "  时区设置: $currentTimezone" -ForegroundColor White
    Write-Host "  当前时间: $currentTime" -ForegroundColor White

    if ($currentTimezone -eq "GMT+8") {
        Write-Host ""
        Write-Host "==========================================" -ForegroundColor Green
        Write-Host "✓ 时区配置成功!" -ForegroundColor Green
        Write-Host "==========================================" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "==========================================" -ForegroundColor Yellow
        Write-Host "⚠ 时区配置可能未生效，当前时区: $currentTimezone" -ForegroundColor Yellow
        Write-Host "==========================================" -ForegroundColor Yellow
    }
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Android 模拟器启动工具" -ForegroundColor Cyan
Write-Host "目标时区: 东八区 (Asia/Shanghai/GMT+8)" -ForegroundColor Yellow
Write-Host "SDK 根目录: $AndroidSdk" -ForegroundColor White
Write-Host "模拟器: $AvdName" -ForegroundColor White
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# 设备守卫（非交互，供手动运行与 .vscode preLaunchTask 复用）：
# 1. 有真机在线 -> 跳过，调试直接用真机；
# 2. 有任意模拟器在线 -> 唤醒屏幕（避免熄屏黑屏假死）后跳过，避免重复拉起。
# adb 在 Windows 输出带 \r，需 Trim 后再匹配。
$deviceLines = & $AdbPath devices |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -match '\t\w+$' }

if ($deviceLines | Where-Object { $_ -notmatch '^emulator-' }) {
    Write-Host "检测到真机，跳过模拟器启动。" -ForegroundColor Yellow
    exit 0
}

if ($deviceLines | Where-Object { $_ -match '^emulator-' }) {
    Write-Host "检测到模拟器已在线，唤醒屏幕并跳过启动。" -ForegroundColor Yellow
    & $AdbPath shell input keyevent KEYCODE_WAKEUP 2>$null
    exit 0
}

# 启动模拟器
Write-Host "启动模拟器: $AvdName ..." -ForegroundColor Green
# 使用 AVD 配置里的宿主 GPU 渲染与 Quick Boot 快照（首次冷启动后，后续启动走快照秒开）
Start-Process -FilePath $EmulatorPath -ArgumentList "-avd", $AvdName, "-timezone", "Asia/Shanghai", "-no-boot-anim" -WindowStyle Normal

# 等待设备连接
Write-Host "等待设备启动..." -ForegroundColor Gray
$maxAttempts = 60
$attempt = 0

while ($attempt -lt $maxAttempts) {
    Start-Sleep -Seconds 2
    $attempt++

    $deviceState = & $AdbPath get-state 2>$null
    if ($deviceState -eq "device") {
        # 检查系统是否完全启动
        $bootCompleted = & $AdbPath shell getprop sys.boot_completed 2>$null
        if ($bootCompleted -eq "1") {
            Write-Host "设备已就绪!" -ForegroundColor Green
            break
        }
    }

    if ($attempt % 10 -eq 0) {
        Write-Host "  等待中... ($attempt/$maxAttempts)" -ForegroundColor Gray
    }
}

if ($attempt -ge $maxAttempts) {
    Write-Error "等待设备启动超时"
    exit 1
}

Set-ChinaTimezone -AdbExe $AdbPath

Write-Host ""
Write-Host "模拟器已就绪，可以开始 Flutter 开发了!" -ForegroundColor Cyan
