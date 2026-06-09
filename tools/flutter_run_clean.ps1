param(
  [string[]]$FlutterArgs = @("run"),
  [switch]$OnlyAppLogs
)

$ErrorActionPreference = "Stop"

$noisePattern =
  "AccessibilityBridge|MIUIInput|ViewRootImpl|VRI\[|CompatChangeReporter|BufferQueue|OpenGLRenderer|InsetsController|InsetsSource"
$appPattern =
  "\[JXU\]|E/flutter|══╡|Exception|Error|Hot reload|Hot restart|Restarted application|Flutter run key commands|To hot reload"

& flutter @FlutterArgs 2>&1 | ForEach-Object {
  $line = "$_"
  if ($OnlyAppLogs) {
    if ($line -match $appPattern) {
      Write-Output $line
    }
    return
  }
  if ($line -notmatch $noisePattern) {
    Write-Output $line
  }
}

exit $LASTEXITCODE
