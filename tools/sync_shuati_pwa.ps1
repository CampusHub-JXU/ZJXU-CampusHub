param(
  [string]$SourcePath,
  [switch]$SkipBuild,
  [switch]$Install
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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

function Get-RelativePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BasePath,
    [Parameter(Mandatory = $true)]
    [string]$TargetPath
  )

  return [System.IO.Path]::GetRelativePath($BasePath, $TargetPath).Replace('\', '/')
}

function Get-StringSha256 {
  param([Parameter(Mandatory = $true)][string]$Text)

  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Get-GitValue {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepoPath,
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  try {
    $value = & git -C $RepoPath @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
      return $null
    }
    return ($value -join "`n").Trim()
  } catch {
    return $null
  }
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$defaultSourcePath = Join-Path (Split-Path -Parent $repoRoot) 'shuatipwa'
if ([string]::IsNullOrWhiteSpace($SourcePath)) {
  $SourcePath = $defaultSourcePath
}

$sourceRoot = Resolve-Path -LiteralPath $SourcePath
$distRoot = Join-Path $sourceRoot 'dist'
$assetRoot = Join-Path $repoRoot 'assets'
$destinationRoot = Join-Path $assetRoot 'shuatipwa'

if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'package.json'))) {
  throw "Missing package.json in PWA source: $sourceRoot"
}

Push-Location $sourceRoot
try {
  if ($Install) {
    if (Test-Path -LiteralPath (Join-Path $sourceRoot 'package-lock.json')) {
      Invoke-Native npm ci
    } else {
      Invoke-Native npm install
    }
  }

  if (-not $SkipBuild) {
    Invoke-Native npm run build
  }
} finally {
  Pop-Location
}

if (-not (Test-Path -LiteralPath $distRoot)) {
  throw "Missing PWA dist directory: $distRoot"
}

foreach ($requiredFile in @('index.html', 'manifest.webmanifest', 'sw.js')) {
  $path = Join-Path $distRoot $requiredFile
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Missing required PWA dist file: $path"
  }
}

$resolvedAssetRoot = Resolve-Path -LiteralPath $assetRoot
if (Test-Path -LiteralPath $destinationRoot) {
  $resolvedDestination = Resolve-Path -LiteralPath $destinationRoot
  if (-not $resolvedDestination.Path.StartsWith($resolvedAssetRoot.Path, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean destination outside assets/: $($resolvedDestination.Path)"
  }
  Get-ChildItem -LiteralPath $resolvedDestination.Path -Force | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Recurse -Force
  }
} else {
  New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null
}

Get-ChildItem -LiteralPath $distRoot -Force | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination $destinationRoot -Recurse -Force
}

$packageJson = Get-Content -Raw -LiteralPath (Join-Path $sourceRoot 'package.json') | ConvertFrom-Json
$distFiles = Get-ChildItem -LiteralPath $distRoot -Recurse -File | Sort-Object FullName
$hashLines = foreach ($file in $distFiles) {
  $relativePath = Get-RelativePath -BasePath $distRoot -TargetPath $file.FullName
  $fileHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
  "$relativePath`t$($file.Length)`t$fileHash"
}

$sourceCommit = Get-GitValue -RepoPath $sourceRoot -Arguments @('rev-parse', '--short=12', 'HEAD')
$sourceStatus = Get-GitValue -RepoPath $sourceRoot -Arguments @('status', '--porcelain')
$embedManifest = [ordered]@{
  generatedBy = 'tools/sync_shuati_pwa.ps1'
  packageName = $packageJson.name
  packageVersion = $packageJson.version
  sourceCommit = $sourceCommit
  sourceDirty = -not [string]::IsNullOrWhiteSpace($sourceStatus)
  distHash = Get-StringSha256 -Text ($hashLines -join "`n")
  fileCount = $distFiles.Count
}

$manifestPath = Join-Path $destinationRoot 'embed_manifest.json'
$embedManifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

Write-Host "Synced shuatipwa dist to assets/shuatipwa" -ForegroundColor Green
Write-Host "package: $($embedManifest.packageName)@$($embedManifest.packageVersion)"
Write-Host "commit : $($embedManifest.sourceCommit)"
Write-Host "dirty  : $($embedManifest.sourceDirty)"
Write-Host "files  : $($embedManifest.fileCount)"
Write-Host "hash   : $($embedManifest.distHash)"
