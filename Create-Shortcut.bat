@echo off
setlocal

echo Creating shortcut for Seelock Watcher Sync...

REM Get the full path to the directory where this script is located
set "SCRIPT_DIR=%~dp0"
REM Remove trailing backslash if it exists
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

REM Define shortcut properties
set "SHORTCUT_NAME=Seelock Watcher Sync"
set "TARGET_FILE=%SCRIPT_DIR%\sync.ps1"
set "ICON_FILE=%SCRIPT_DIR%\seelock.ico"
set "POWERSHELL_PATH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

REM PowerShell command to create the shortcut
set "PS_COMMAND=$desktop = [System.Environment]::GetFolderPath('Desktop');"
set "PS_COMMAND=%PS_COMMAND% $ws = New-Object -ComObject WScript.Shell;"
set "PS_COMMAND=%PS_COMMAND% $sc = $ws.CreateShortcut([System.IO.Path]::Combine($desktop, '%SHORTCUT_NAME%.lnk'));"
set "PS_COMMAND=%PS_COMMAND% $sc.TargetPath = '%POWERSHELL_PATH%';"
set "PS_COMMAND=%PS_COMMAND% $sc.Arguments = '-ExecutionPolicy Bypass -NoProfile -File ""%TARGET_FILE%""';"
set "PS_COMMAND=%PS_COMMAND% $sc.WorkingDirectory = '%SCRIPT_DIR%';"
set "PS_COMMAND=%PS_COMMAND% $sc.Description = 'Starts the Seelock video synchronization process.';"
set "PS_COMMAND=%PS_COMMAND% if (Test-Path -LiteralPath '%ICON_FILE%') { $sc.IconLocation = '%ICON_FILE%' } else { echo 'Icon file not found: %ICON_FILE%. Using default icon.'; };"
set "PS_COMMAND=%PS_COMMAND% $sc.Save();"

REM Execute the PowerShell command
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& {%PS_COMMAND%}"

echo.
echo Shortcut '%SHORTCUT_NAME%' has been created on your desktop.
echo.
pause
