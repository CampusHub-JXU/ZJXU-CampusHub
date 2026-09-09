param(
  [string[]]$FlutterArgs = @("run"),
  [switch]$OnlyAppLogs
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'flutter_env.ps1')

$noisePattern =
  "AccessibilityBridge|MIUIInput|ViewRootImpl|VRI\[|CompatChangeReporter|BufferQueue|OpenGLRenderer|InsetsController|InsetsSource|FlutterJNI.*Sending viewport metrics|ImeTracker|HandWritingStubImpl|InsetsAnimationCtrlImpl|WindowOnBackDispatcher|ActivityThread.*resolveViewAutofillFlags|AssistStructure|System\.err.*miui|System\.err.*contentcatcher|ProfileInstaller|FirebaseMessaging|FirebaseInstallations|FLTFire|WM-|WorkManager|TurboSchedMonitor|Chromium|Adreno|ContentCatcher|HyperContentProvider|Wth2:|OneTrack|MessengerIpcClient|Loading com\.google\.android\.webview|Using legacy platform view rendering strategy|setForceDark\(\) is a no-op|BLUETOOTH_CONNECT permission is missing|Unsupported mediaType|Unsupported mime|Unrecognized profile|Unknown profile|Unknown level|Shader compilation failed|Pipeline create failed|HTTP Cache size is|Transferring cookies from provisional CookieManager|failed to find setSchedAffinity method|Access denied finding property|EGL_emulation|app_time_stats"
$appPattern =
  "\[JXU\]|E/flutter|══╡|Exception|Error|Hot reload|Hot restart|Restarted application|Flutter run key commands|To hot reload|Dart VM Service|DevTools debugger and profiler|Running Gradle task|Built build\\app\\outputs\\flutter-apk\\app-debug.apk|Installing build\\app\\outputs\\flutter-apk\\app-debug.apk|Syncing files to device"

& $FlutterExe @FlutterArgs 2>&1 | ForEach-Object {
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
