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
$msalPath    = Join-Path $modulesPath 'MSAL.PS'

if (-not (Test-Path $msalPath)) {
    Write-Host ''
    Write-Host 'First run — downloading MSAL.PS module...' -ForegroundColor Yellow
    if (-not (Test-Path $modulesPath)) { New-Item -ItemType Directory -Path $modulesPath | Out-Null }
    try {
        Save-Module -Name MSAL.PS -Path $modulesPath -Repository PSGallery -Force
        Write-Host 'MSAL.PS installed.' -ForegroundColor Green
        Write-Host ''
    } catch {
        Write-Host "Failed to install MSAL.PS: $_" -ForegroundColor Red
        Write-Host 'Check your internet connection and try again.' -ForegroundColor Yellow
        Read-Host 'Press Enter to exit'
        exit 1
    }
}

$env:PSModulePath = $modulesPath + [System.IO.Path]::PathSeparator + $env:PSModulePath

if (-not (Get-Module MSAL.PS -ErrorAction SilentlyContinue)) {
    Write-Host '[startup] Importing MSAL.PS...' -ForegroundColor DarkGray
    Import-Module MSAL.PS -ErrorAction Stop
}

. (Join-Path $PSScriptRoot 'src\Auth.ps1')
. (Join-Path $PSScriptRoot 'src\Demo.ps1')
. (Join-Path $PSScriptRoot 'src\Tools\PasswordReset.ps1')
. (Join-Path $PSScriptRoot 'src\Tools\UserPasswordReset.ps1')
. (Join-Path $PSScriptRoot 'src\Tools\LastDevice.ps1')
. (Join-Path $PSScriptRoot 'src\Tools\SignInLogs.ps1')
. (Join-Path $PSScriptRoot 'src\Tools\GroupCopy.ps1')
. (Join-Path $PSScriptRoot 'src\Tools\TeamsProvisioning.ps1')
. (Join-Path $PSScriptRoot 'src\Tools\BulkUpnChange.ps1')
. (Join-Path $PSScriptRoot 'src\Tools\ImmutableId.ps1')
. (Join-Path $PSScriptRoot 'src\Tools\UpdateHistory.ps1')
. (Join-Path $PSScriptRoot 'src\Tools\SecureScore.ps1')
. (Join-Path $PSScriptRoot 'src\Tools\LeaverWorkflow.ps1')
. (Join-Path $PSScriptRoot 'src\Tools\DeviceCompliance.ps1')
. (Join-Path $PSScriptRoot 'src\Tools\LicenceAssignment.ps1')
. (Join-Path $PSScriptRoot 'src\MainWindow.ps1')

# Capture the fully-loaded script session so WPF dispatcher callbacks can resolve
# dot-sourced functions (Write-Log, Start-BucLoad, etc.) via Invoke-EtbScript.
$Script:EtbSessionState = $ExecutionContext.SessionState

Write-Log "Art's Entra Toolbox $Global:AppVersion starting (PS $($PSVersionTable.PSVersion))" 'INFO'

# Compile the token-cache persistence helper up front so the first sign-in isn't delayed.
Initialize-TokenCacheHelper

try {
    Show-MainWindow -AppVersion $Global:AppVersion
} catch {
    Write-Log "Fatal error in Show-MainWindow: $_" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    Read-Host 'Press Enter to exit'
}
