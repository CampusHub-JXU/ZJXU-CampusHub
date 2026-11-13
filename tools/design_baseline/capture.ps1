param(
  [Parameter(Mandatory = $true)][string]$Name,
  [string]$OutDir = "docs/design-baseline/screenshots",
  [string]$Serial = "8d0d9702"
)

$ErrorActionPreference = "Stop"
$remote = "/sdcard/phase0_cap.png"

$dir = Join-Path $PSScriptRoot "../../$OutDir"
$target = (Join-Path $dir "$Name.png").Replace('/', '\')
$parent = Split-Path -Parent $target
New-Item -ItemType Directory -Force -Path $parent | Out-Null

adb -s $Serial shell screencap -p $remote | Out-Null
adb -s $Serial pull $remote "$target" 2>&1 | Out-Null
adb -s $Serial shell rm $remote | Out-Null

if (-not (Test-Path -LiteralPath $target)) { throw "capture failed: $target" }
$size = (Get-Item -LiteralPath $target).Length
Write-Output "saved $target ($size bytes)"
