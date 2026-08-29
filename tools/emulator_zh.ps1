#!/usr/bin/env pwsh
#requires -Version 5.1
<#
.SYNOPSIS
    启动 Android 模拟器并设置为东八区时区

.DESCRIPTION
    该脚本启动 Android 模拟器，自动配置时区为东八区 (Asia/Shanghai/GMT+8)
    适用于 Flutter 开发中需要测试中国时区的场景

.PARAMETER EmulatorName
    模拟器名称，默认为 Pixel_9

.EXAMPLE
    .\emulator_zh.ps1
    启动默认模拟器并设置时区

.EXAMPLE
    .\emulator_zh.ps1 -EmulatorName "Pixel_8_API_37"
    启动指定模拟器

.NOTES
    需要 Android SDK 已安装并配置环境变量
#>

param(
    [Parameter()]
    [string]$EmulatorName = "Pixel_9"
)

$ErrorActionPreference = "Stop"

# Android SDK 路径
$AndroidSdk = "$env:LOCALAPPDATA\Android\Sdk"
$EmulatorPath = "$AndroidSdk\emulator\emulator.exe"
$AdbPath = "$AndroidSdk\platform-tools\adb.exe"

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

# 检查必要的工具是否存在
if (-not (Test-Path $EmulatorPath)) {
    Write-Error "找不到 emulator.exe，请检查 Android SDK 是否已安装"
    exit 1
}

if (-not (Test-Path $AdbPath)) {
    Write-Error "找不到 adb.exe，请检查 Android SDK 是否已安装"
    exit 1
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Android 模拟器启动工具" -ForegroundColor Cyan
Write-Host "目标时区: 东八区 (Asia/Shanghai/GMT+8)" -ForegroundColor Yellow
Write-Host "模拟器: $EmulatorName" -ForegroundColor White
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# 检查模拟器是否已在运行
Write-Host "检查是否有运行中的模拟器..." -ForegroundColor Gray
$runningDevices = & $AdbPath devices | Select-String "emulator-"
if ($runningDevices) {
    Write-Host "检测到已运行的模拟器: $runningDevices" -ForegroundColor Yellow
    $restart = Read-Host "是否重启模拟器? (y/N)"
    if ($restart -eq 'y' -or $restart -eq 'Y') {
        Write-Host "正在关闭现有模拟器..." -ForegroundColor Gray
        & $AdbPath emu kill 2>$null
        Start-Sleep -Seconds 3
    } else {
        Write-Host "跳过启动，直接配置时区..." -ForegroundColor Gray
        Set-ChinaTimezone -AdbExe $AdbPath
        Write-Host ""
        Write-Host "模拟器已就绪，可以开始 Flutter 开发了!" -ForegroundColor Cyan
        exit 0
    }
}

# 启动模拟器
Write-Host "启动模拟器: $EmulatorName ..." -ForegroundColor Green
# 使用 AVD 配置里的宿主 GPU 渲染与 Quick Boot 快照（首次冷启动后，后续启动走快照秒开）
Start-Process -FilePath $EmulatorPath -ArgumentList "-avd", $EmulatorName, "-timezone", "Asia/Shanghai", "-no-boot-anim" -WindowStyle Normal

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
