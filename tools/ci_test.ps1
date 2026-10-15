param(
  [switch]$SkipFullTest,
  [switch]$WithCoverage,
  [switch]$BuildApkSmoke
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'flutter_env.ps1')

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Push-Location $repoRoot

try {
  function Invoke-Native {
    param(
      [Parameter(Mandatory = $true)]
      [string]$FilePath,
      [Parameter(ValueFromRemainingArguments = $true)]
      [string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
      throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
    }
  }

  function Invoke-CiStep {
    param(
      [Parameter(Mandatory = $true)]
      [string]$Name,
      [Parameter(Mandatory = $true)]
      [scriptblock]$Script
    )

    Write-Host ""
    Write-Host "==> $Name" -ForegroundColor Cyan
    $startedAt = Get-Date
    & $Script
    $elapsed = (Get-Date) - $startedAt
    Write-Host ("<== {0} passed in {1:n1}s" -f $Name, $elapsed.TotalSeconds) -ForegroundColor Green
  }

  Invoke-CiStep "Flutter and Dart versions" {
    Invoke-Native $FlutterExe --version
    Invoke-Native $DartExe --version
  }

  Invoke-CiStep "Install dependencies" {
    Invoke-Native $FlutterExe pub get
  }

  Invoke-CiStep "Validate workflow YAML files" {
    $code = "import pathlib, yaml; [yaml.safe_load(path.read_text(encoding='utf-8')) for path in pathlib.Path('.github/workflows').glob('*.yml')]; [yaml.safe_load(path.read_text(encoding='utf-8')) for path in pathlib.Path('.github/workflows').glob('*.yaml')]; print('workflow yaml ok')"
    Invoke-Native python -c $code
  }

  Invoke-CiStep "Verify release workflow target" {
    Invoke-Native python tools/check_release_workflow.py
  }

  Invoke-CiStep "Run test diagnostics" {
    Invoke-Native python tools/test_diagnostics.py --self-test
    Invoke-Native python tools/test_diagnostics.py --output build/test_diagnostics --fail-on error
  }

  Invoke-CiStep "Verify formatting" {
    Invoke-Native $DartExe format --output=none --set-exit-if-changed lib test integration_test
  }

  Invoke-CiStep "Analyze project source" {
    Invoke-Native $FlutterExe analyze
  }

  if ($SkipFullTest) {
    # 全量测试已包含该文件；只在跳过全量时单独跑，作为快速回归。
    Invoke-CiStep "Focused regression tests" {
      Invoke-Native $FlutterExe test test/core/update/update_service_test.dart
    }
  } else {
    Invoke-CiStep "Full Flutter test suite" {
      if ($WithCoverage) {
        Invoke-Native $FlutterExe test --coverage
      } else {
        Invoke-Native $FlutterExe test
      }
    }
  }

  if ($BuildApkSmoke) {
    Invoke-CiStep "Android APK build smoke test" {
      Invoke-Native $FlutterExe build apk --debug
    }
  }

  Write-Host ""
  Write-Host "CI test completed successfully." -ForegroundColor Green
} finally {
  Pop-Location
}
