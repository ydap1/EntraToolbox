#Requires -Version 5.1
<#
.SYNOPSIS
    One-time setup: downloads MSAL.PS into the local ./Modules/ folder.
    Run this once per machine before using Launch.cmd.
.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File ".\Bootstrap.ps1"
#>
$ErrorActionPreference = 'Stop'
$ModulesPath = Join-Path $PSScriptRoot 'Modules'

Write-Host ''
Write-Host "=== Art's Entra Toolbox - Bootstrap ===" -ForegroundColor Cyan
Write-Host "Modules folder: $ModulesPath"
Write-Host ''

$psGet = Get-Module -Name PowerShellGet -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if ($psGet.Version.Major -lt 2) {
    Write-Host 'Upgrading PowerShellGet to 2.x...' -ForegroundColor Yellow
    Install-Module -Name PowerShellGet -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
    Write-Host 'PowerShellGet upgraded. Re-run Bootstrap.ps1.' -ForegroundColor Green
    exit 0
}

if (-not (Test-Path $ModulesPath)) { New-Item -ItemType Directory -Path $ModulesPath | Out-Null }

if (Test-Path (Join-Path $ModulesPath 'MSAL.PS')) {
    Write-Host '  [SKIP] MSAL.PS - already present' -ForegroundColor DarkGray
} else {
    Write-Host '  [DOWNLOAD] MSAL.PS ...' -ForegroundColor Yellow
    Save-Module -Name MSAL.PS -Path $ModulesPath -Repository PSGallery -Force
    Write-Host '  [OK] MSAL.PS' -ForegroundColor Green
}

Write-Host ''
Write-Host 'Bootstrap complete. Run Launch.cmd to start.' -ForegroundColor Cyan
Write-Host ''
