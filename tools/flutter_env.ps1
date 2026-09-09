# Resolves the Flutter executable without requiring it on PATH.
# Dot-source from tools scripts:  . (Join-Path $PSScriptRoot 'flutter_env.ps1')
#
# Order: FLUTTER_ROOT -> android/local.properties flutter.sdk -> PATH -> D:\flutter

# 应用日志为 UTF-8；Windows 控制台默认按 GBK 解码原生进程输出，中文会变乱码。
if ($env:OS -eq 'Windows_NT') {
    try {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    } catch {
        # 无控制台句柄（重定向/CI）时保持默认。
    }
}

# 内部辅助库：被其他脚本 dot-source 使用，直接执行时给出入口提示。
if ($MyInvocation.InvocationName -ne '.') {
    Write-Host '这是内部辅助脚本，不会启动应用。'
    Write-Host '启动应用请运行:  .\tools\flutter_run_clean.ps1'
    exit 0
}

function Resolve-FlutterExecutable {
    $candidates = @()

    if ($env:FLUTTER_ROOT) {
        $candidates += Join-Path $env:FLUTTER_ROOT 'bin\flutter.bat'
    }

    $localProps = Join-Path $PSScriptRoot '..\android\local.properties'
    if (Test-Path -LiteralPath $localProps) {
        $sdkDir = (Select-String -Path $localProps -Pattern '^\s*flutter\.sdk\s*=\s*(.+)$').Matches |
            ForEach-Object { $_.Groups[1].Value.Trim() } | Select-Object -First 1
        if ($sdkDir) {
            $sdkDir = $sdkDir -replace '\\\\', '\'
            $candidates += Join-Path $sdkDir 'bin\flutter.bat'
        }
    }

    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        $candidates += $cmd.Source
    }

    $candidates += 'D:\flutter\bin\flutter.bat'

    foreach ($c in $candidates | Select-Object -Unique) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            return (Resolve-Path -LiteralPath $c).Path
        }
    }

    throw 'Flutter SDK not found. Set FLUTTER_ROOT or fix android/local.properties flutter.sdk.'
}

$FlutterExe = Resolve-FlutterExecutable
$DartExe = Join-Path (Split-Path -Parent $FlutterExe) 'dart.bat'
