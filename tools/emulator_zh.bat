@echo off
chcp 65001 >nul
:: 启动 Android 模拟器并设置为东八区时区
:: 用法: emulator_zh.bat [模拟器名称]

set "EMULATOR_NAME=%~1"
if "%EMULATOR_NAME%"=="" set "EMULATOR_NAME=Pixel_9"

echo 正在启动模拟器: %EMULATOR_NAME%
echo 时区将设置为: 东八区 (Asia/Shanghai/GMT+8)

:: 启动模拟器（在后台）
start "" "%LOCALAPPDATA%\Android\Sdk\emulator\emulator.exe" -avd %EMULATOR_NAME% -timezone Asia/Shanghai

:: 等待模拟器启动
echo 等待模拟器启动...
timeout /t 15 /nobreak >nul

:: 等待设备就绪
echo 等待设备连接...
:wait_for_device
"%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe" wait-for-device
timeout /t 2 /nobreak >nul

:: 检查设备是否真正就绪
for /f "tokens=*" %%a in ('"%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe" shell getprop sys.boot_completed 2^>nul') do (
    if "%%a"=="1" goto device_ready
)
goto wait_for_device

:device_ready
echo 设备已就绪，设置时区...

:: 设置时区为东八区
"%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe" shell settings put global time_zone GMT+8
"%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe" shell settings put global auto_time 0
"%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe" shell settings put global auto_time_zone 0
"%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe" shell settings put system time_12_24 24

echo.
echo ==========================================
echo 模拟器启动完成！
echo 时区已设置为: 东八区 (GMT+8)
echo 当前时间: 
"%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe" shell date
echo ==========================================
pause
