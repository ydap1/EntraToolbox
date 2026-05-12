#Requires -Version 5.1
<#
.SYNOPSIS
    Entry point for Entra Tools. Always launch via Launch.cmd.
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
    Import-Module MSAL.PS -ErrorAction Stop
}

. (Join-Path $PSScriptRoot 'src\Auth.ps1')
. (Join-Path $PSScriptRoot 'src\Tools\PasswordReset.ps1')
. (Join-Path $PSScriptRoot 'src\Tools\LastDevice.ps1')
. (Join-Path $PSScriptRoot 'src\MainWindow.ps1')

Show-MainWindow -AppVersion $Global:AppVersion
