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
    & {
        function Invoke-RestMethod {
            param($Uri, $Headers)
            if ($Uri -match '/auditLogs/') { throw 'Sign-in permission denied' }
            return @{ id = 'u'; accountEnabled = $true }
        }
        function Get-EtbGraphCollection { param($Uri, $Headers); @{ displayName = 'Loaded'; skuPartNumber = 'TEST' } }
        $UserId = 'u'; $Token = 'fake'; $Ref = @{}
        & $Script:UoLoadWork
        Assert ($Ref.Profile.id -eq 'u' -and $Ref.Groups.Count -eq 1 -and $Ref.Devices.Count -eq 1 -and $Ref.SignInsError -match 'permission denied') 'overview preserves successful sections when sign-in access is denied'
    }
    $query = [uri]::UnescapeDataString((Get-SlQuery 'user-id' ([datetime]'2026-09-01') ([datetime]'2026-09-02')))
    Assert ($query -match 'createdDateTime ge 2026-09-01' -and $query -match 'createdDateTime lt 2026-09-03' -and $query.Contains('$top=50')) 'sign-in query covers the inclusive date range with bounded pages'
    $invalid = $false
    try { $null = Get-SlQuery u ([datetime]'2026-09-03') ([datetime]'2026-09-02') } catch { $invalid = $true }
    Assert $invalid 'reversed sign-in dates are rejected before requesting Graph'
    $events = @(
        @{ id='1'; createdDateTime='2026-09-01T12:00:00Z'; appDisplayName='Teams'; status=@{ errorCode=0 }; location=@{}; deviceDetail=@{} }
        @{ id='2'; createdDateTime='2026-09-01T12:00:00Z'; appDisplayName='Teams'; status=@{ errorCode=50126; failureReason='Invalid password'; additionalDetails='Details' }; location=@{}; deviceDetail=@{}; correlationId='trace' }
    )
    $filtered = @(ConvertTo-SlRows $events $true 'password')
    Assert ($filtered.Count -eq 1 -and $filtered[0].CorrelationId -eq 'trace' -and $filtered[0].AdditionalDetails -eq 'Details') 'failure filtering retains troubleshooting details for export'
    & {
        $Script:SL_Request = 5; $Script:SL_Entries = @($events[0]); $Script:SL_Next = 'next'
        $Script:SL_UI = @{ UserList = [pscustomobject]@{ SelectedItem = [pscustomobject]@{ Tag = @{ id='u' } } }; Count = [pscustomobject]@{ Text='' } }
        function Update-SlResults { }
        Complete-SlPage @{ Request=4; UserId='u'; Entries=@($events[1]) }
        Assert ($Script:SL_Entries.Count -eq 1) 'stale sign-in responses cannot overwrite a new search'
        Complete-SlPage @{ Request=5; UserId='u'; Error='Network unavailable' }
        Assert ($Script:SL_Entries.Count -eq 1 -and $Script:SL_Next -eq 'next') 'page failures preserve rows and a retryable pagination link'
        Complete-SlPage @{ Request=5; UserId='u'; Entries=$events; Next=$null }
        Assert ($Script:SL_Entries.Count -eq 2 -and -not $Script:SL_Next) 'overlapping pages deduplicate by sign-in ID'
        $Script:SL_UI = $null
    }
    $licensed = @{ id='u'; userPrincipalName='u@school.test'; usageLocation='GB'; assignedLicenses=@(); licenseAssignmentStates=@(@{ skuId='sku'; assignedByGroup='g'; error='None' }) }
    Assert ((Get-BlPlanRow $licensed sku Remove).Result -eq 'Skip') 'bulk licence removal preserves inherited-only assignments'
    $licensed.licenseAssignmentStates += @{ skuId='sku'; assignedByGroup=$null; error='None' }
    $mixed = Get-BlPlanRow $licensed sku Remove
    Assert ($mixed.Source -eq 'Direct + group' -and $mixed.Result -eq 'Ready' -and $mixed.Detail -match 'remains') 'mixed licence sources permit only direct removal and explain retained access'
    Assert ((Get-BlPlanRow $licensed sku Assign).Result -eq 'Skip') 'existing service plans are not overwritten by bulk assignment'
    $licensed.licenseAssignmentStates=@(); $licensed.usageLocation=$null
    Assert ((Get-BlPlanRow $licensed sku Assign).Result -eq 'Blocked') 'missing usage location blocks a new licence assignment'
    Assert ((Get-BlAvailableSeats @{ prepaidUnits=@{ enabled=10 }; consumedUnits=12 }) -eq 0) 'overallocated subscriptions report zero available seats'
    & {
        $calls = [Collections.Generic.List[object]]::new()
        function Invoke-RestMethod {
            param($Uri, $Headers, $Method, $Body, $ContentType)
            if ($Method -eq 'POST') { $calls.Add(($Body | ConvertFrom-Json)); return }
            return @{ id='u'; userPrincipalName='u@school.test'; usageLocation='GB'; licenseAssignmentStates=@(@{ skuId='sku'; assignedByGroup=$null }) }
        }
        $Rows=@($mixed); $SkuId='sku'; $Action='Remove'; $Token='fake'; $Ref=@{ Results=@() }
        & $Script:BlApplyWork
        Assert ($calls.Count -eq 0 -and $Ref.Results[0].Result -eq 'Skipped') 'licence writes skip changed assignment sources after preview'
        $Rows=@([pscustomobject]@{ Id='u'; Target='u@school.test'; Source='Direct' }); $Ref=@{ Results=@() }
        & $Script:BlApplyWork
        Assert ($calls.Count -eq 1 -and $calls[0].addLicenses.Count -eq 0 -and $calls[0].removeLicenses[0] -eq 'sku') 'licence removal sends only the reviewed SKU in removeLicenses'
        $calls.Clear(); $Ref=@{ Results=@(); CancelRequested=$true }
        & $Script:BlApplyWork
        Assert ($calls.Count -eq 0) 'stopped licence batches do not begin another user'
    }
    $members = @(@{ id='owner'; userPrincipalName='owner@school.test' }, @{ id='old'; userPrincipalName='old@school.test' })
    $desired = @(@{ id='new'; userPrincipalName='new@school.test' })
    $owners = @(@{ id='owner' })
    $plan = @(Get-GmPlan $members $desired $owners 'Match user roster')
    Assert (@($plan | Where-Object Action -eq 'Remove')[0].Id -eq 'old' -and @($plan | Where-Object Id -eq 'owner')[0].Action -eq 'Keep') 'roster matching preserves owners and removes only surplus users'
    Assert (@(Get-GmPlan $members $desired $owners 'Add missing' | Where-Object Action -eq 'Remove').Count -eq 0) 'add-missing mode never removes members'
    foreach ($type in 'Dynamic','Synced','Role','Mail') {
        $group=@{ id='g'; securityEnabled=$true; mailEnabled=$false; groupTypes=@() }
        switch ($type) { Dynamic { $group.groupTypes=@('DynamicMembership') }; Synced { $group.onPremisesSyncEnabled=$true }; Role { $group.isAssignableToRole=$true }; Mail { $group.mailEnabled=$true } }
        $rejected=$false
        try { Assert-GmEditableGroup $group } catch { $rejected=$true }
        Assert $rejected "$type groups are rejected before membership writes"
    }
    & {
        $calls=[Collections.Generic.List[object]]::new()
        function Get-GmSnapshot { param($GroupId,$Headers); @{ Members=$members; Owners=$owners } }
        function Invoke-RestMethod { param($Uri,$Method,$Headers,$Body,$ContentType); $calls.Add(@{ Uri=$Uri; Method=$Method }) }
        $GroupId='g'; $Desired=$desired; $Mode='Match user roster'; $Signature='stale'; $Token='fake'; $Ref=@{ Results=@() }
        $rejected=$false
        try { & $Script:GmApplyWork } catch { $rejected=$true }
        Assert ($rejected -and $calls.Count -eq 0) 'a stale group preview cannot submit any membership changes'
        $Signature=Get-GmPlanSignature $plan
        & $Script:GmApplyWork
        $deletes=@($calls | Where-Object Method -eq 'DELETE')
        Assert ($calls.Count -eq 2 -and $deletes.Count -eq 1 -and $deletes[0].Uri -eq 'https://graph.microsoft.com/v1.0/groups/g/members/old/$ref') 'group matching deletes only the reviewed membership reference'
    }
    $historyDir=Join-Path $Global:AppRoot 'audit'; $null=New-Item $historyDir -ItemType Directory
    $auditRows=@(
        [pscustomobject]@{ Timestamp='2026-09-01 00:00:00'; Operator='admin'; Tenant='tenant-a'; Tool='Group Manager'; Action='Add member'; Target='pupil@school.test'; Result='Succeeded'; Detail='Group A' }
        [pscustomobject]@{ Timestamp='2026-09-02 23:59:59'; Operator='admin'; Tenant='tenant-a'; Tool='Group Manager'; Action='Remove member'; Target='pupil@school.test'; Result='Failed'; Detail='Denied' }
        [pscustomobject]@{ Timestamp='2026-09-02 12:00:00'; Operator='admin'; Tenant='tenant-b'; Tool='Other'; Action='Other'; Target='private'; Result='OK'; Detail='' }
    )
    $auditRows | Export-Csv (Join-Path $historyDir 'tenant-a-2026-09.csv') -NoTypeInformation
    $auditRows | Export-Csv (Join-Path $historyDir 'tenant-b-2026-09.csv') -NoTypeInformation
    'broken,columns' | Set-Content (Join-Path $historyDir 'tenant-a-broken.csv')
    'x,y' | Add-Content (Join-Path $historyDir 'tenant-a-broken.csv')
    $history=Read-EtbHistory $historyDir tenant-a
    Assert ($history.Rows.Count -eq 2 -and @($history.Rows | Where-Object Tenant -ne 'tenant-a').Count -eq 0) 'history isolates both filenames and row tenant IDs'
    Assert ($history.Errors.Count -eq 1) 'history reports corrupt files while retaining readable records'
    $found=@(Select-EtbHistory $history.Rows ([datetime]'2026-09-01') ([datetime]'2026-09-02') admin 'Group Manager' pupil)
    Assert ($found.Count -eq 2 -and $found[0].Result -eq 'Failed') 'history filters include both boundary days and retain newest-first ordering'
    Assert (@(Select-EtbHistory $history.Rows ([datetime]'2026-09-01') ([datetime]'2026-09-02') other '' '').Count -eq 0) 'operator filtering uses the requested operator'
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
