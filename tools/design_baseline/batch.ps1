param(
  [Parameter(Mandatory = $true)][string]$Manifest,
  [string]$Theme = "light",
  [string]$Serial = "8d0d9702",
  [string]$Package = "edu.zjxu.jxucampushub.dev"
)

$ErrorActionPreference = "Stop"

# Manifest lines: <waitSeconds>|<slug>|<deepLinkActionId or "-">|<optional tap chain "x,y;x,y">
$lines = Get-Content -LiteralPath $Manifest | Where-Object { $_.Trim() -ne "" -and -not $_.Trim().StartsWith("#") }

foreach ($line in $lines) {
  $parts = $line.Split("|")
  $wait = [int]$parts[0]
  $slug = $parts[1].Trim()
  $action = $parts[2].Trim()
  $taps = if ($parts.Count -gt 3) { $parts[3].Trim() } else { "" }

  adb -s $Serial shell am force-stop $Package | Out-Null
  Start-Sleep -Milliseconds 400

  if ($action -eq "-") {
    adb -s $Serial shell am start -n "$Package/edu.zjxu.jxucampushub.MainActivity" | Out-Null
  }
  else {
    adb -s $Serial shell am start -a android.intent.action.VIEW -d "jxucampushub://action/$action" -p $Package | Out-Null
  }

  Start-Sleep -Seconds $wait

  if ($taps -ne "") {
    foreach ($tap in $taps.Split(";")) {
      $xy = $tap.Split(",")
      adb -s $Serial shell input tap $xy[0].Trim() $xy[1].Trim() | Out-Null
      Start-Sleep -Seconds 2
    }
  }

  & (Join-Path $PSScriptRoot "capture.ps1") -Name "$Theme/$slug" -Serial $Serial -OutDir "docs/design-baseline/screenshots"
}
