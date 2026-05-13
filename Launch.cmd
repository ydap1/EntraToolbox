@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

where pwsh.exe >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ERROR: PowerShell 7 ^(pwsh.exe^) is not installed.
    echo Download it from https://aka.ms/powershell
    echo.
    pause
    exit /b 1
)

pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\Start.ps1" %*

endlocal
