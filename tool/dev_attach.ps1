#Requires -Version 7
<#
.SYNOPSIS
    Debug 包起不来的绕过脚本：am start 当前启用的 launcher alias + flutter attach。

.DESCRIPTION
    应用图标切换（AppIconChannelHandler）会禁用 manifest 默认 alias LauncherCeladon，
    导致 `flutter run` 报 "Activity class ... does not exist"。
    本脚本通过 pm resolve-activity 找到设备上当前启用的 LAUNCHER alias，
    带 debug extras 手动 am start，再 flutter attach 接管调试会话。

.EXAMPLE
    pwsh tool/dev_attach.ps1                 # 唯一设备
    pwsh tool/dev_attach.ps1 -Device 8d0d9702 # 指定设备
#>
param(
    [string]$Device = ""
)

$ErrorActionPreference = "Stop"
$Pkg = "edu.zjxu.jxucampushub.dev"
$Adb = "adb"

function Resolve-Device {
    if ($Device) { return $Device }
    $lines = & $Adb devices | Select-Object -Skip 1 | Where-Object { $_ -match "\tdevice$" }
    if (-not $lines) { throw "没有发现已连接的 adb 设备" }
    if ($lines.Count -gt 1) {
        Write-Host "多个设备在线，请用 -Device 指定:" -ForegroundColor Yellow
        $lines | ForEach-Object { Write-Host "  $($_.Split("`t")[0])" }
        exit 1
    }
    return ($lines[0] -split "`t")[0]
}

$dev = Resolve-Device
Write-Host "设备: $dev" -ForegroundColor Cyan

# 解析当前启用的 launcher alias（resolve-activity 只返回 enabled 组件）
$resolved = & $Adb -s $dev shell cmd package resolve-activity --brief `
    -a android.intent.action.MAIN -c android.intent.category.LAUNCHER $Pkg 2>$null
$component = ($resolved | Where-Object { $_ -match "$Pkg/" } | Select-Object -Last 1)
if (-not $component) {
    throw "无法解析 $Pkg 的 launcher alias（app 未安装？）"
}
$component = $component.Trim()
Write-Host "启用 alias: $component" -ForegroundColor Cyan

# 先强杀再冷启动：若进程已活，am start 只 bring-to-front，不会重建进程，
# 而旧进程未必带 debug extras（VM Service 不开），attach 会一直等。
Write-Host "冷启动 app（带 debug extras）..." -ForegroundColor Cyan
& $Adb -s $dev shell am force-stop $Pkg | Out-Null
Start-Sleep -Milliseconds 800
& $Adb -s $dev shell am start -a android.intent.action.MAIN `
    -c android.intent.category.LAUNCHER -f 0x20000000 `
    --ez enable-dart-profiling true `
    --ez enable-checked-mode true `
    --ez verify-entry-points true `
    $component
if ($LASTEXITCODE -ne 0) { throw "am start 失败" }

# flutter attach（无 --device-id 参数时用 -d；--app-id 明确包名避免猜错）
flutter attach -d $dev --app-id $Pkg
