#Requires -Version 7.0
# Offline behavioural checks for the helpdesk tools; no WPF or tenant required.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$Global:AppRoot = Join-Path ([IO.Path]::GetTempPath()) ('etb-features-' + [guid]::NewGuid())
$null = New-Item $Global:AppRoot -ItemType Directory
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message }; Write-Host "PASS $Message" }
try {
    . "$root/src/Auth.ps1"
    . "$root/src/Import.ps1"
    foreach ($file in Get-ChildItem "$root/src/Tools" -Filter *.ps1) { . $file.FullName }
    foreach ($file in Get-ChildItem "$root/src" -Recurse -Filter *.ps1) {
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
        Assert (-not $errors) "$($file.Name) parses"
    }
    Assert ((Get-EtbWriteResult 403) -eq 'Failed' -and (Get-EtbWriteResult 504) -eq 'Uncertain' -and (Get-EtbWriteResult 0) -eq 'Uncertain') 'write failures distinguish rejection from uncertain delivery'
    $Ref = @{ BulkQueue = [Collections.Concurrent.ConcurrentQueue[object]]::new(); BulkLabels = @{ user1 = 'pupil@school.test' } }
    Publish-EtbWriteResult @{ Uri = 'https://graph.microsoft.com/v1.0/users/user1'; Method = 'PATCH'; Body = '{"passwordProfile":{"password":"secret"}}' } 'Failed' 'secret echoed'
    $row = $null; $null = $Ref.BulkQueue.TryDequeue([ref]$row)
    Assert (-not $row.Retry -and $row.Detail -notmatch 'secret' -and $row.Target -match 'pupil@school.test') 'password results cannot retain or replay secrets and identify the user'
    Publish-EtbWriteResult @{ Uri = 'https://graph.microsoft.com/v1.0/users/user1'; Method = 'PATCH'; Body = '{"userPrincipalName":"new@school.test"}' } 'Uncertain'
    $null = $Ref.BulkQueue.TryDequeue([ref]$row)
    Assert ($row.Retry.Method -eq 'PATCH') 'readable UPN changes support verification'
    Publish-EtbWriteResult @{ Uri = 'https://graph.microsoft.com/v1.0/groups/g/members/u/$ref'; Method = 'DELETE' } 'Failed'
    $null = $Ref.BulkQueue.TryDequeue([ref]$row)
    Assert ($row.Retry.Uri.EndsWith('/$ref') -and $row.Retry.VerifyUri.EndsWith('/members/u')) 'membership recovery preserves the reference-only deletion endpoint'
    Publish-EtbWriteResult @{ Uri = 'https://graph.microsoft.com/v1.0/groups'; Method = 'POST'; Body = '{"displayName":"Test"}' } 'Uncertain'
    $null = $Ref.BulkQueue.TryDequeue([ref]$row)
    Assert (-not $row.Retry) 'uncertain object creation is never replayed'
    $export = @(Get-BrExportRows ([pscustomobject]@{ Tool='Test'; Rows=@($row) }) -FailuresOnly)
    Assert ($export.Count -eq 1 -and -not $export[0].PSObject.Properties['Retry']) 'failure exports omit retained request data'
} finally { Remove-Item $Global:AppRoot -Recurse -Force }
