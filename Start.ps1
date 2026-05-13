#Requires -Version 7.0
<#
.SYNOPSIS
    Entry point for Art's Entra Toolbox. Always launch via Launch.cmd.
#>
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Write-Error 'PSScriptRoot not set. Use Launch.cmd'
    exit 1
}

$Global:AppRoot = $PSScriptRoot

$vf = Join-Path $PSScriptRoot 'version.txt'
$Global:AppVersion = if (Test-Path $vf) { (Get-Content $vf -Raw).Trim() } else { '' }

$modulesPath = Join-Path $PSScriptRoot 'Modules'
if (-not (Test-Path $modulesPath)) {
    Write-Host ''
    Write-Host 'Modules folder not found.' -ForegroundColor Red
    Write-Host "Run: powershell.exe -ExecutionPolicy Bypass -File `"$PSScriptRoot\Bootstrap.ps1`"" -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

$env:PSModulePath = $modulesPath + [System.IO.Path]::PathSeparator + $env:PSModulePath

if (-not (Get-Module MSAL.PS -ErrorAction SilentlyContinue)) {
    Write-Host '[startup] Importing MSAL.PS...' -ForegroundColor DarkGray
    Import-Module MSAL.PS -ErrorAction Stop
}

. (Join-Path $PSScriptRoot 'src\Auth.ps1')
. (Join-Path $PSScriptRoot 'src\Tools\PasswordReset.ps1')
. (Join-Path $PSScriptRoot 'src\Tools\UserPasswordReset.ps1')
. (Join-Path $PSScriptRoot 'src\Tools\LastDevice.ps1')
. (Join-Path $PSScriptRoot 'src\Tools\SignInLogs.ps1')
. (Join-Path $PSScriptRoot 'src\MainWindow.ps1')

Write-Log "Art's Entra Toolbox $Global:AppVersion starting (PS $($PSVersionTable.PSVersion))" 'INFO'

try {
    Show-MainWindow -AppVersion $Global:AppVersion
} catch {
    Write-Log "Fatal error in Show-MainWindow: $_" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    Read-Host 'Press Enter to exit'
}
