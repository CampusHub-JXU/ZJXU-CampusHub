$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sourcePath = $null
$skipPwaBuild = $false
$installPwaDependencies = $false
$flutterArgs = @()

$i = 0
while ($i -lt $args.Count) {
  $arg = [string]$args[$i]

  if ($arg -eq '-SourcePath') {
    $i++
    if ($i -ge $args.Count) {
      throw '-SourcePath requires a value'
    }
    $sourcePath = [string]$args[$i]
    $i++
    continue
  }

  if ($arg -eq '-SkipPwaBuild') {
    $skipPwaBuild = $true
    $i++
    continue
  }

  if ($arg -eq '-InstallPwaDependencies') {
    $installPwaDependencies = $true
    $i++
    continue
  }

  if ($arg -eq '--') {
    for ($j = $i + 1; $j -lt $args.Count; $j++) {
      $flutterArgs += [string]$args[$j]
    }
    $i = $args.Count
    continue
  }

  for ($j = $i; $j -lt $args.Count; $j++) {
    $flutterArgs += [string]$args[$j]
  }
  $i = $args.Count
}

if ($flutterArgs.Count -eq 0) {
  $flutterArgs = @('run')
}

$syncScript = Join-Path $PSScriptRoot 'sync_shuati_pwa.ps1'
$syncParams = @{}
if (-not [string]::IsNullOrWhiteSpace($sourcePath)) {
  $syncParams.SourcePath = $sourcePath
}
if ($skipPwaBuild) {
  $syncParams.SkipBuild = $true
}
if ($installPwaDependencies) {
  $syncParams.Install = $true
}

& $syncScript @syncParams
if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}

& flutter @flutterArgs
exit $LASTEXITCODE
