#!/usr/bin/env pwsh
#requires -Version 7.0
<#
.SYNOPSIS
    应用内更新的模拟器端到端验收：A(当前版本) -> 本地源 -> B(versionCode 9999) 覆盖安装。

.DESCRIPTION
    1. 构建 debug APK A（pubspec 当前版本）与 B（--build-number 9999，版本名 patch+1），
       均带 --dart-define=JXU_UPDATE_TEST_ORIGIN=http://10.0.2.2:<Port>。
    2. 生成 GitHub Release API 同形的 www/latest.json（含 B 的 sha256 / size / tag），
       B 放在 www/<tag>/<asset>，在 <BindAddress>:<Port> 起静态服务（模拟器经 10.0.2.2 访问宿主 loopback）。
    3. adb install -r -t -d A 到显式 -Serial，启动应用（绝不卸载 / 清数据 / flutter run / flutter test）。
    4. 你在应用里手动：设置 -> 检查更新 -> 更新 -> 系统安装确认；脚本每 3 秒轮询
       dumpsys package，versionCode 变为 9999 即成功（退出码 0），超时退出码 2，其它错误 1。
    5. 全程把 logcat -s AppUpdate 收集到 output/update_e2e/logcat.txt。

    原生 / Dart 的测试源开关只在 debug 构建生效（见 docs/in-app-update-state-machine.md §8）。

.PARAMETER Serial
    adb 设备序列号，默认 emulator-5554。脚本只操作该设备。

.PARAMETER Port
    本地静态服务端口（1024-65535），默认 8765。必须与已构建 APK 里 baked 的端口一致。

.PARAMETER SkipBuild
    跳过构建，复用 output/update_e2e 下的 app-A.apk / app-B.apk / meta.json（端口须一致）。

.PARAMETER ServeOnly
    不构建、不安装、不启动应用，只起静态服务并轮询（重跑用）。

.PARAMETER TimeoutSec
    等待 versionCode 变为 9999 的最长秒数，默认 600。

.PARAMETER BindAddress
    静态服务监听地址，默认 127.0.0.1（10.0.2.2 即宿主 loopback，无需放行防火墙）。

.EXAMPLE
    pwsh -File .\tools\update_e2e\run_e2e.ps1
#>
[CmdletBinding()]
param(
    [string]$Serial = 'emulator-5554',
    [ValidateRange(1024, 65535)][int]$Port = 8765,
    [switch]$SkipBuild,
    [switch]$ServeOnly,
    [ValidateRange(30, 7200)][int]$TimeoutSec = 600,
    [string]$BindAddress = '127.0.0.1'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$OutDir = Join-Path $RepoRoot 'output\update_e2e'
$WwwDir = Join-Path $OutDir 'www'
$ApkA = Join-Path $OutDir 'app-A.apk'
$ApkB = Join-Path $OutDir 'app-B.apk'
$MetaPath = Join-Path $OutDir 'meta.json'
$LogcatPath = Join-Path $OutDir 'logcat.txt'
$ServerLogPath = Join-Path $OutDir 'server.log'
$BuiltApk = Join-Path $RepoRoot 'build\app\outputs\flutter-apk\app-debug.apk'
$Package = 'edu.zjxu.jxucampushub.dev'   # applicationId + debug 的 applicationIdSuffix ".dev"
$TargetVersionCode = 9999
$Origin = "http://10.0.2.2:$Port"
$ReleaseRepo = 'CampusHub-JXU/ZJXU-CampusHub'

. (Join-Path $PSScriptRoot '..\flutter_env.ps1')   # 提供 $FlutterExe

function Write-Step([string]$Message) {
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message) -ForegroundColor Cyan
}

function Resolve-Adb {
    $candidates = @()
    $props = Join-Path $RepoRoot 'android\local.properties'
    if (Test-Path -LiteralPath $props) {
        $dir = (Select-String -Path $props -Pattern '^\s*sdk\.dir\s*=\s*(.+)$').Matches |
            ForEach-Object { $_.Groups[1].Value.Trim() } | Select-Object -First 1
        if ($dir) { $candidates += (Join-Path ($dir -replace '\\\\', '\') 'platform-tools\adb.exe') }
    }
    foreach ($root in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)) {
        if ($root) { $candidates += (Join-Path $root 'platform-tools\adb.exe') }
    }
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    foreach ($c in $candidates | Select-Object -Unique) {
        if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    throw 'adb not found. Fix android/local.properties sdk.dir, ANDROID_HOME, or PATH.'
}

function Invoke-Adb {
    # 输出返回给调用者，非零退出码抛错。
    $output = & $script:Adb -s $Serial @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "adb -s $Serial $($args -join ' ') failed (exit $LASTEXITCODE): $($output -join ' ')"
    }
    return $output
}

function Get-InstalledVersionCode {
    $out = & $script:Adb -s $Serial shell dumpsys package $Package 2>$null
    foreach ($line in $out) {
        if ($line -match 'versionCode=(\d+)') { return [long]$Matches[1] }
    }
    return $null
}

function Invoke-FlutterBuild([string]$Label, [string[]]$ExtraArgs, [string]$Destination) {
    Write-Step "Building APK $Label (debug; several minutes, sequential) ..."
    # AGP 的 zipflinger 对已有 debug APK 做原地增量更新，旧条目会留下死空间（实测同内容 A 204 MB、
    # 全新打包的 B 121 MB）。每次构建前删掉打包产物，强制全新紧凑打包。
    foreach ($stale in @($BuiltApk, (Join-Path $RepoRoot 'build\app\intermediates\apk\debug'),
            (Join-Path $RepoRoot 'build\app\outputs\apk\debug'))) {
        if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Recurse -Force }
    }
    # 只打设备 ABI 的原生库：debug 全 ABI 包 200+ MB，经模拟器 NAT 下载极慢。
    $buildArgs = @('build', 'apk', '--debug', '--target', 'lib/main.dart',
        '--target-platform', $script:TargetPlatform,
        "--dart-define=JXU_UPDATE_TEST_ORIGIN=$Origin") + $ExtraArgs
    & $FlutterExe @buildArgs
    if ($LASTEXITCODE -ne 0) { throw "flutter build apk ($Label) failed with exit $LASTEXITCODE" }
    if (-not (Test-Path -LiteralPath $BuiltApk)) { throw "Expected $BuiltApk after building $Label" }
    Copy-Item -LiteralPath $BuiltApk -Destination $Destination -Force
    Write-Step ("APK {0} -> {1} ({2:N1} MB)" -f $Label, $Destination, ((Get-Item $Destination).Length / 1MB))
}

function Test-PortInUse([int]$P) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync('127.0.0.1', $P)
        return ($task.Wait(500) -and $client.Connected)
    } catch { return $false } finally { $client.Dispose() }
}

$serverProc = $null
$logcatProc = $null
$exitCode = 1
Push-Location $RepoRoot
try {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $script:Adb = Resolve-Adb
    Write-Step "adb: $script:Adb ; serial: $Serial ; origin: $Origin"

    $state = (& $script:Adb -s $Serial get-state 2>&1) -join ''
    if ($LASTEXITCODE -ne 0 -or $state.Trim() -ne 'device') {
        throw "Device $Serial is not online ($state). Start it first: pwsh -File .\tools\emulator_zh.ps1"
    }

    # --- 版本信息 --------------------------------------------------------
    $pubspec = Get-Content -LiteralPath (Join-Path $RepoRoot 'pubspec.yaml') -Raw
    if ($pubspec -notmatch '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)') {
        throw 'Cannot read "version: X.Y.Z+N" from pubspec.yaml'
    }
    $major, $minor, $patch, $baseCode = [int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [long]$Matches[4]
    $baseName = "$major.$minor.$patch"
    $nameB = "$major.$minor.$($patch + 1)"
    if ($baseCode -ge $TargetVersionCode) { throw "pubspec build number $baseCode must be below $TargetVersionCode" }
    $abi = ((& $script:Adb -s $Serial shell getprop ro.product.cpu.abi) -join '').Trim()
    if (-not $abi) { throw "Cannot read ro.product.cpu.abi from $Serial" }
    $script:TargetPlatform = switch ($abi) {
        'x86_64' { 'android-x64' }
        'arm64-v8a' { 'android-arm64' }
        'armeabi-v7a' { 'android-arm' }
        default { throw "Unsupported device ABI $abi" }
    }
    $tag = "v$nameB"
    $assetName = "JXU-CampusHub-$tag-$abi.apk"

    # --- 构建 / 复用 -----------------------------------------------------
    if ($ServeOnly -or $SkipBuild) {
        foreach ($p in @($ApkA, $ApkB, $MetaPath)) {
            if (-not (Test-Path -LiteralPath $p)) { throw "Missing $p; run once without -SkipBuild / -ServeOnly first." }
        }
        $meta = Get-Content -LiteralPath $MetaPath -Raw | ConvertFrom-Json
        if ([int]$meta.port -ne $Port) {
            throw "APKs were built for port $($meta.port) but -Port is $Port; rebuild or pass -Port $($meta.port)."
        }
        $baseName = $meta.baseName; $baseCode = [long]$meta.baseCode
        $nameB = $meta.nameB; $tag = $meta.tag; $assetName = $meta.assetName
        Write-Step "Reusing built APKs (A=$baseName+$baseCode, B=$nameB+$TargetVersionCode, asset=$assetName)"
    } else {
        Invoke-FlutterBuild 'A' @() $ApkA
        Invoke-FlutterBuild 'B' @('--build-number', "$TargetVersionCode", '--build-name', $nameB) $ApkB
        [ordered]@{
            port = $Port; baseName = $baseName; baseCode = $baseCode
            nameB = $nameB; tag = $tag; assetName = $assetName
        } | ConvertTo-Json | Set-Content -LiteralPath $MetaPath -Encoding utf8NoBOM
    }

    # --- 发布物：latest.json + www/<tag>/<asset> ---------------------------
    Write-Step "Preparing $WwwDir"
    if (Test-Path -LiteralPath $WwwDir) { Remove-Item -LiteralPath $WwwDir -Recurse -Force }
    $tagDir = Join-Path $WwwDir $tag
    New-Item -ItemType Directory -Force -Path $tagDir | Out-Null
    Copy-Item -LiteralPath $ApkB -Destination (Join-Path $tagDir $assetName)
    $sha = (Get-FileHash -LiteralPath $ApkB -Algorithm SHA256).Hash.ToLowerInvariant()
    $size = [long](Get-Item -LiteralPath $ApkB).Length
    $release = [ordered]@{
        tag_name     = $tag
        name         = "JXU-CampusHub $tag (e2e)"
        html_url     = "https://github.com/$ReleaseRepo/releases/tag/$tag"
        draft        = $false
        prerelease   = $false
        published_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        body         = "E2E test release $tag. Served from the local test origin; the canonical GitHub URL is identity only and is never fetched."
        assets       = @(
            [ordered]@{
                id                   = 999001
                name                 = $assetName
                content_type         = 'application/vnd.android.package-archive'
                size                 = $size
                digest               = "sha256:$sha"
                # 规范 GitHub URL 只做身份校验，测试源下实际从 <origin>/<tag>/<name> 下载。
                browser_download_url = "https://github.com/$ReleaseRepo/releases/download/$tag/$assetName"
            }
        )
    }
    $latestPath = Join-Path $WwwDir 'latest.json'
    [System.IO.File]::WriteAllText($latestPath, ($release | ConvertTo-Json -Depth 6),
        [System.Text.UTF8Encoding]::new($false))

    $python = (Get-Command python -ErrorAction SilentlyContinue) ?? (Get-Command python3 -ErrorAction SilentlyContinue)
    if (-not $python) { throw 'python not found on PATH (needed for the static server and JSON check).' }
    $checkArgs = @('-I', (Join-Path $PSScriptRoot 'check_latest_json.py'), $latestPath,
        '--current-version', $baseName, '--apk', $ApkB, '--served-root', $WwwDir)
    if ($abi -in 'arm64-v8a', 'armeabi-v7a') { $checkArgs += @('--abi', $abi) }
    & $python.Source @checkArgs
    if ($LASTEXITCODE -ne 0) { throw 'latest.json failed the parser-rule check (see above).' }

    # --- 静态服务 --------------------------------------------------------
    if (Test-PortInUse $Port) { throw "Port $Port is already in use on 127.0.0.1; pass another -Port (APKs bake it in)." }
    Write-Step "Starting static server on ${BindAddress}:$Port (log: $ServerLogPath)"
    $serverProc = Start-Process -FilePath $python.Source -PassThru -NoNewWindow `
        -ArgumentList @('-u', (Join-Path $PSScriptRoot 'serve.py'), "$Port", $BindAddress, $WwwDir) `
        -RedirectStandardError $ServerLogPath -RedirectStandardOutput (Join-Path $OutDir 'server.out.log')
    $ready = $false
    for ($i = 0; $i -lt 20 -and -not $ready; $i++) {
        if ($serverProc.HasExited) { throw "Static server exited early (code $($serverProc.ExitCode)); see $ServerLogPath" }
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/latest.json" -UseBasicParsing -TimeoutSec 2
            $ready = ($r.StatusCode -eq 200)
        } catch { Start-Sleep -Milliseconds 500 }
    }
    if (-not $ready) { throw "Static server did not answer on port $Port" }

    # --- logcat ---------------------------------------------------------
    & $script:Adb -s $Serial logcat -c
    $logcatProc = Start-Process -FilePath $script:Adb -PassThru -NoNewWindow `
        -ArgumentList @('-s', $Serial, 'logcat', '-v', 'time', '-s', 'AppUpdate:V') `
        -RedirectStandardOutput $LogcatPath -RedirectStandardError (Join-Path $OutDir 'logcat.err.txt')

    # --- 安装 A 并启动 ---------------------------------------------------
    if (-not $ServeOnly) {
        Write-Step "Installing A over the existing install (adb install -r -t -d; data kept, never uninstalls)"
        $installOut = (& $script:Adb -s $Serial install -r -t -d $ApkA 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $installOut -notmatch 'Success') {
            $hint = if ($installOut -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE|signatures do not match') {
                ' The installed app is signed with a different key (e.g. a release keystore). This script never uninstalls; install matching builds manually.'
            } else { '' }
            throw "adb install failed: $installOut.$hint"
        }
        $code = Get-InstalledVersionCode
        if ($code -ne $baseCode) { Write-Warning "Installed versionCode is $code, expected $baseCode (pubspec)." }
        $launchOut = (& $script:Adb -s $Serial shell monkey -p $Package -c android.intent.category.LAUNCHER 1 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $launchOut -match 'No activities found') { throw "Could not launch ${Package}: $launchOut" }
    }

    $startCode = Get-InstalledVersionCode
    Write-Host ''
    Write-Host '=== 手动步骤（在模拟器里） ===' -ForegroundColor Yellow
    Write-Host "  1. 应用已是 A（$baseName+$startCode），测试源 $Origin -> $tag（$assetName，$([math]::Round($size / 1MB, 1)) MB）"
    Write-Host '  2. 我的 -> 设置 -> 检查更新 -> 看到新版本 -> 点「更新」'
    Write-Host '  3. 下载完成后在系统安装确认页点「安装/更新」'
    Write-Host "  脚本每 3 秒轮询 versionCode，目标 $TargetVersionCode，最长 $TimeoutSec 秒（Ctrl+C 可中止，服务会被清理）。"
    Write-Host ''

    # --- 轮询 ------------------------------------------------------------
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    $last = $null
    $succeeded = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($serverProc.HasExited) { throw "Static server died (code $($serverProc.ExitCode)); see $ServerLogPath" }
        $code = Get-InstalledVersionCode
        if ($code -ne $last) {
            Write-Step "versionCode = $code"
            $last = $code
        }
        if ($code -eq $TargetVersionCode) { $succeeded = $true; break }
        Start-Sleep -Seconds 3
    }

    if ($succeeded) {
        Write-Step "SUCCESS: $Package is now versionCode $TargetVersionCode ($nameB)."
        # server.log 由服务进程持有写句柄：用共享读打开，避免被锁或读到截断内容。
        $serverLines = @()
        try {
            $fs = [System.IO.File]::Open($ServerLogPath, 'Open', 'Read', 'ReadWrite,Delete')
            try { $serverLines = ([System.IO.StreamReader]::new($fs)).ReadToEnd() -split "`r?`n" } finally { $fs.Dispose() }
        } catch { }
        $apkHits = @($serverLines | Where-Object { $_ -like "*`"GET /$tag/$assetName *" })
        Write-Host ("  local server saw the APK download: {0}" -f $(
            if ($apkHits.Count -gt 0) { "yes ($($apkHits.Count) request(s); statuses: $((($apkHits | ForEach-Object { ($_ -split ' ')[-2] }) | Select-Object -Unique) -join ','))" }
            else { 'NOT seen (check server.log)' }))
        Write-Host "  logcat: $LogcatPath"
        Write-Host '  The emulator now runs B with the test origin baked in. To restore a normal build: flutter build apk --debug --target lib/main.dart, then adb -s <serial> install -r -t <apk>.'
        $exitCode = 0
    } else {
        Write-Host "TIMEOUT: versionCode never reached $TargetVersionCode within $TimeoutSec s (last: $last)." -ForegroundColor Red
        Write-Host "  See $LogcatPath and $ServerLogPath."
        $exitCode = 2
    }
    if (Test-Path -LiteralPath $LogcatPath) {
        Write-Host '--- last AppUpdate log lines ---'
        Get-Content -LiteralPath $LogcatPath -Tail 20
    }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
} finally {
    foreach ($p in @($serverProc, $logcatProc)) {
        if ($p -and -not $p.HasExited) { try { Stop-Process -Id $p.Id -Force } catch { } }
    }
    Pop-Location
}
exit $exitCode
