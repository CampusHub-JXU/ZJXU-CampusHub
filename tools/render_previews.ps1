# 预览渲染脚本：把视觉预览场景（组件画廊 + 关键页面真实状态）渲染成 PNG。
#
# 用途：视觉重构时所有页面共用同一套渲染产物做验收基准，
# 避免每个页面各设计各的。输出到 preview/render/。
#
# 用法：
#   .\tools\render_previews.ps1                     # 渲染全部场景
#   .\tools\render_previews.ps1 -Filter page_home   # 只渲染名字含 page_home 的场景
#   .\tools\render_previews.ps1 -Filter gallery_dark
param(
  [string]$Filter = ""
)

$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

New-Item -ItemType Directory -Force -Path "preview/render" | Out-Null

$env:JXU_PREVIEW_RENDER = "1"

$flutterArgs = @(
  "test",
  "test/preview/preview_render_test.dart",
  "--update-goldens"
)
if ($Filter -ne "") {
  $flutterArgs += @("--plain-name", $Filter)
}

& flutter @flutterArgs
$exitCode = $LASTEXITCODE
Remove-Item Env:JXU_PREVIEW_RENDER -ErrorAction SilentlyContinue

if ($exitCode -ne 0) {
  Write-Host ""
  Write-Host "渲染失败（exit=$exitCode）。" -ForegroundColor Red
  exit $exitCode
}

Write-Host ""
Write-Host "已生成预览（preview/render/）：" -ForegroundColor Green
Get-ChildItem "preview/render" -Filter *.png |
  Sort-Object Name |
  Format-Table Name, @{Label = "KB"; Expression = { [math]::Round($_.Length / 1KB) } }, LastWriteTime -AutoSize
