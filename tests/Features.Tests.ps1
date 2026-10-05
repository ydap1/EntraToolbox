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
        $ast=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$null,[ref]$null)
        foreach ($node in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.StringConstantExpressionAst] -and $a.Value -match '^<(Grid|Window)\s+xmlns=' },$true)) {
            $null=[xml](Invoke-ThemeXaml $node.Value)
        }
    }
    & {
        function Invoke-RestMethod {
            param($Uri, $Headers)
            if ($Uri -match '/auditLogs/') { throw 'Sign-in permission denied' }
            return @{ id = 'u'; accountEnabled = $true }
        }
        function Get-EtbGraphCollection { param($Uri, $Headers); @{ displayName = 'Loaded'; skuPartNumber = 'TEST'; '@odata.type'='#microsoft.graph.group' } }
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
    & {
        $paths=[Collections.Generic.List[string]]::new()
        function Invoke-RestMethod { param($Uri,$Headers); @{ id='g'; securityEnabled=$true; mailEnabled=$false; groupTypes=@() } }
        function Get-EtbGraphCollection {
            param($Uri,$Headers)
            $paths.Add($Uri)
            if ($Uri -match '/owners') { return @() }
            @(@{ id='u'; '@odata.type'='#microsoft.graph.user' }, @{ id='d'; '@odata.type'='#microsoft.graph.device' })
        }
        $snapshot=Get-GmSnapshot g @{}
        Assert ($snapshot.Members.Count -eq 1 -and $snapshot.Members[0].id -eq 'u' -and -not @($paths | Where-Object { $_ -match '/microsoft.graph.user' }).Count) 'group previews filter users from direct membership reads without an eventual-index cast'
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
    Publish-EtbBulkPreview 'Offline plan' @([pscustomobject]@{ Target='u@school.test'; Action='Assign'; Result='Demo'; Detail='' }) 'Demo'
    Assert ($Script:BulkRuns[0].State -eq 'Demo' -and $Script:BulkRuns[0].Rows[0].Result -eq 'Demo' -and -not $Script:BulkRuns[0].Rows[0].Retry) 'offline bulk previews use shared result rows without replayable requests'
    & {
        $audit=[Collections.Generic.List[string]]::new(); $messages=[Collections.Generic.List[string]]::new()
        function Write-EtbAudit { param($Tool,$Action,$Target,$Result,$Detail); $audit.Add($Action) }
        function Write-LwLog { param($Message,$Color); $messages.Add($Message) }
        function Set-MainStatus { param($Message,$Color) }
        function Start-AsyncWork {
            param($BulkName,$Vars,$RefSeed,$Script,$OnComplete)
            $RefSeed.CancelRequested=$true
            & $OnComplete $RefSeed
        }
        $Script:LW_SelectedUser=@{ id='u'; displayName='Pupil'; userPrincipalName='u@school.test' }
        $Script:LW_UI=@{}
        foreach($name in 'ChkDisable','ChkRevoke','ChkGroups') { $Script:LW_UI[$name]=[pscustomobject]@{ IsChecked=$true } }
        foreach($name in 'BtnRun','UserSearch','UserList') { $Script:LW_UI[$name]=[pscustomobject]@{ IsEnabled=$true } }
        $Script:DryMode=$false; $Script:DemoMode=$false
        $started=[Collections.Generic.List[int]]::new()
        function Confirm-EtbAction { param($Message,$Title); $false }
        function Start-AsyncWork { $started.Add(1) }
        Start-LwRun
        Assert ($started.Count -eq 0) 'declining the leaver confirmation changes nothing'
        function Confirm-EtbAction { param($Message,$Title); $true }
        function Start-AsyncWork {
            param($BulkName,$Vars,$RefSeed,$Script,$OnComplete)
            $RefSeed.CancelRequested=$true
            & $OnComplete $RefSeed
        }
        Start-LwRun
        Assert ($audit.Count -eq 0 -and @($messages | Where-Object { $_ -match 'stopped' }).Count -gt 0) 'stopping a leaver before its first step cannot log or audit unperformed changes as successful'
        function Start-AsyncWork {
            param($BulkName,$Vars,$RefSeed,$Script,$OnComplete)
            $Ref=$RefSeed; $UserId=$Vars.UserId; $Token='fake'
            & $Script
            & $OnComplete $Ref
        }
        function Get-EtbGraphCollection {
            param($Uri,$Headers)
            @{ '@odata.type'='#microsoft.graph.group'; id='dyn'; displayName='All Users'; groupTypes=@('DynamicMembership'); securityEnabled=$true }
            @{ '@odata.type'='#microsoft.graph.group'; id='sec'; displayName='All Staff'; groupTypes=@(); securityEnabled=$true; mailEnabled=$false }
        }
        $deleted=[Collections.Generic.List[string]]::new()
        function Invoke-RestMethod { param($Uri,$Headers,$Method,$Body,$ErrorAction); if ($Method -eq 'DELETE') { $deleted.Add($Uri) } }
        foreach($name in 'ChkDisable','ChkRevoke') { $Script:LW_UI[$name].IsChecked=$false }
        Start-LwRun
        Assert ($deleted.Count -eq 1 -and $deleted[0] -match '/groups/sec/' -and @($messages | Where-Object { $_ -match 'Skipped group.*All Users' }).Count -eq 1) 'leaver skips groups Graph will not edit and removes the rest'
        $Script:LW_UI=$null; $Script:LW_SelectedUser=$null
    }
    Assert ((Get-EtbWriteResult 403) -eq 'Failed' -and (Get-EtbWriteResult 415) -eq 'Failed' -and (Get-EtbWriteResult 504) -eq 'Uncertain' -and (Get-EtbWriteResult 0) -eq 'Uncertain') 'write failures distinguish rejection from uncertain delivery'
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
    Publish-EtbWriteResult @{ Uri='https://graph.microsoft.com/v1.0/groups/g/members/$ref'; Method='POST'; Body='{"@odata.id":"https://graph.microsoft.com/v1.0/directoryObjects/user1"}' } 'Succeeded'
    $null=$Ref.BulkQueue.TryDequeue([ref]$row)
    Assert ($row.Target -match 'pupil@school.test' -and $row.Action -eq 'Add member') 'bulk membership rows identify the actual member as well as the group'
    Publish-EtbWriteResult @{ Uri='https://graph.microsoft.com/v1.0/users/user1/assignLicense'; Method='POST'; Body='{"addLicenses":[{"skuId":"sku","disabledPlans":[]}],"removeLicenses":[]}' } 'Uncertain'
    $null=$Ref.BulkQueue.TryDequeue([ref]$row)
    Assert ($row.Retry.Kind -eq 'Licence' -and $row.Retry.VerifyUri -eq 'https://graph.microsoft.com/v1.0/users/user1?$select=licenseAssignmentStates') 'licence failures retain a non-secret assignment verification request'
    & {
        function Invoke-RestMethod { param($Uri,$Headers); @{ licenseAssignmentStates=@(@{ skuId='sku'; assignedByGroup=$null; state='Active'; error='None' }) } }
        Assert (Test-EtbLicenceRecoveryState $row.Retry @{}) 'licence recovery verifies a healthy direct assignment'
        $rejected=$false
        try { Assert-EtbLicenceRetry $row.Retry @{} } catch { $rejected=$true }
        Assert $rejected 'licence retries cannot overwrite an assignment created after the original failure'
    }
    Publish-EtbWriteResult @{ Uri = 'https://graph.microsoft.com/v1.0/groups'; Method = 'POST'; Body = '{"displayName":"Test"}' } 'Uncertain'
    $null = $Ref.BulkQueue.TryDequeue([ref]$row)
    Assert (-not $row.Retry) 'uncertain object creation is never replayed'
    $export = @(Get-BrExportRows ([pscustomobject]@{ Tool='Test'; Rows=@($row) }) -FailuresOnly)
    Assert ($export.Count -eq 1 -and -not $export[0].PSObject.Properties['Retry']) 'failure exports omit retained request data'
    & {
        $members = [Collections.Generic.HashSet[string]]::new([string[]]@('in'))
        $users = @(
            [pscustomobject]@{ id='in'; userPrincipalName='in@school.test' }
            [pscustomobject]@{ id='new'; userPrincipalName='new@school.test'; department='7A'; officeLocation='Main' }
            [pscustomobject]@{ id='new'; userPrincipalName='new@school.test' }
            [pscustomobject]@{ id='listed'; userPrincipalName='listed@school.test' }
        )
        $missing = @(Get-TeMissingRows $users $members @([pscustomobject]@{ Id='listed' }))
        Assert ($missing.Count -eq 1 -and $missing[0].Id -eq 'new' -and $missing[0].Office -eq 'Main' -and -not $missing[0].IsOwner) 'team editor lists only people not already in the team or the list'

        $Script:TE_UI = @{ Teams = [pscustomobject]@{ SelectedItem = [pscustomobject]@{ id='team1'; displayName='7 Science' } } }
        foreach ($name in 'TeamPicker','Picker','Remove','Clear','Apply','Count','Status','Banner','BannerBar','BannerName','BannerInfo','BannerBadge','BannerCount') {
            $Script:TE_UI[$name] = [pscustomobject]@{ IsEnabled=$false; Text=''; Background=''; Foreground=''; Visibility=''; ToolTip='' }
        }
        $selected = $Script:TE_UI.Teams.SelectedItem
        $Script:TE_UI.Teams.SelectedItem = $null
        Update-TeState
        Assert ($Script:TE_UI.BannerName.Text -eq 'No team selected' -and $Script:TE_UI.BannerBadge.Visibility -eq 'Collapsed') 'the team banner says plainly when no team is chosen'
        $Script:TE_UI.Teams.SelectedItem = $selected
        $Script:TE_MemberIds = $null
        Update-TeState
        Assert ($Script:TE_UI.BannerName.Text -eq '7 Science' -and $Script:TE_UI.BannerInfo.Text -match 'Reading' -and $Script:TE_UI.BannerBar.Background -eq (Get-ThemeHex 'Accent')) 'the team banner names the chosen team while its members load'
        $Script:TE_UI.Grid = [pscustomobject]@{} | Add-Member -PassThru ScriptMethod CommitEdit { $true }
        $Script:TE_MemberIds = [Collections.Generic.HashSet[string]]::new([string[]]@('in'))
        $Script:TE_Rows.Clear()
        $Script:TE_Rows.Add([pscustomobject]@{ Id='pupil'; UPN='pupil@school.test'; IsOwner=$false })
        $Script:TE_Rows.Add([pscustomobject]@{ Id='teacher'; UPN='teacher@school.test'; IsOwner=$true })
        $Script:TE_Rows.Add([pscustomobject]@{ Id='late'; UPN='late@school.test'; IsOwner=$false })
        $Script:TE_Rows.Add([pscustomobject]@{ Id='dup'; UPN='dup@school.test'; IsOwner=$false })
        $Script:DryMode = $false; $Script:DemoMode = $false
        $started = [Collections.Generic.List[object]]::new()
        function Start-AsyncWork { param($BulkName, $BulkTotal, $Vars, $RefSeed, $Script, $OnProgress, $OnComplete); $started.Add(@{ Vars=$Vars; Ref=$RefSeed; Script=$Script; OnProgress=$OnProgress; OnComplete=$OnComplete }) }
        function Confirm-EtbAction { param($Message, $Title); $false }
        Start-TeApply
        Assert ($started.Count -eq 0) 'declining the team editor confirmation changes nothing'

        function Confirm-EtbAction { param($Message, $Title); $true }
        $audit = [Collections.Generic.List[string]]::new()
        function Write-EtbAudit { param($Tool, $Action, $Target, $Result, $Detail); $audit.Add("${Action}:${Target}:$Result") }
        $log = [Collections.Generic.List[string]]::new()
        function Write-AppLog { param($Msg, $Color); $log.Add("${Color}|$Msg") }
        function Set-MainStatus { param($Text, $Color) }
        Start-TeApply
        $job = $started[0]
        $bodies = [Collections.Generic.List[object]]::new()
        function Invoke-RestMethod {
            param($Uri, $Method, $Headers, $Body, $ContentType)
            if ($Uri -notmatch '/teams/team1/members$' -or $Method -ne 'POST') { throw "unexpected request $Method $Uri" }
            $bodies.Add(($Body | ConvertFrom-Json))
            if ($Body -match 'teacher') { throw 'Graph rejected the owner' }
            if ($Body -match 'dup') { throw 'One or more added object references already exist' }
        }
        # 'late' joined the team after the list was built.
        function Get-EtbTeamMemberIds { param($TeamId, $Headers); , [Collections.Generic.HashSet[string]]::new([string[]]@('in', 'late')) }
        $Members = $job.Vars.Members; $TeamId = $job.Vars.TeamId; $Token = 'fake'; $Ref = $job.Ref
        & $job.Script
        Assert ($bodies.Count -eq 3 -and @($bodies[0].roles).Count -eq 0 -and $bodies[1].roles -contains 'owner' -and $bodies[0].'user@odata.bind' -match "users\('pupil'\)") 'team editor adds members and owners with the Teams member API'
        & $job.OnProgress $Ref
        Assert (@($log | Where-Object { $_ -match '^Success\|Team Editor: Added: pupil@school.test \[member\]$' }).Count -eq 1 -and @($log | Where-Object { $_ -match '^Danger\|Team Editor: FAILED: teacher@school.test' }).Count -eq 1 -and @($log | Where-Object { $_ -match '^Muted\|Team Editor: Skipped: late@school.test' }).Count -eq 1) 'team editor writes each person to the activity log as it works'
        & $job.OnComplete $Ref
        Assert ($log[-1] -match "^Warning\|Team Editor: finished '7 Science' — 1 added, 2 already in the team, 1 failed") 'team editor logs a summary when it finishes'
        Assert ($Script:TE_Rows.Count -eq 1 -and $Script:TE_Rows[0].Id -eq 'teacher' -and $Script:TE_MemberIds.Contains('pupil') -and -not $Script:TE_Busy) 'people not added stay listed for another try'
        Assert ($Script:TE_UI.BannerName.Text -eq '7 Science' -and $Script:TE_UI.BannerInfo.Text -match '^4 people already in this team' -and $Script:TE_UI.BannerCount.Text -eq '1 to add' -and $Script:TE_UI.BannerBadge.Visibility -eq 'Visible') 'the team banner stays on the chosen team with current counts after adding'
        Assert (@($Ref.Results | Where-Object Result -eq 'Skipped').Target -join ',' -eq 'late@school.test,dup@school.test' -and $Script:TE_MemberIds.Contains('late') -and $Script:TE_MemberIds.Contains('dup')) 'people already in the team are skipped, not failed, even when the list was stale'
        Assert (($audit -join ',') -eq 'Add member:pupil@school.test:Succeeded,Add owner:teacher@school.test:Uncertain,Add member:late@school.test:Skipped,Add member:dup@school.test:Skipped') 'every team editor outcome is audited with its role'
        $Script:TE_UI = $null; $Script:TE_Rows.Clear()
    }
    & {
        Assert ($Script:IID_Rows.Count -eq 0) 'the immutable ID list starts empty'
        function Update-IidView { }
        function Write-AppLog { param($Msg, $Color) }
        $people = @(
            [pscustomobject]@{ id='a'; displayName='Ann'; userPrincipalName='ann@school.test'; department='7A'; officeLocation='Year 7'; onPremisesImmutableId='' }
            [pscustomobject]@{ id='b'; displayName='Ben'; userPrincipalName='ben@school.test'; department='Staff'; officeLocation='Main'; onPremisesImmutableId='abc==' }
        )
        Add-IidUsers @($people[0])
        Add-IidUsers $people
        Assert ($Script:IID_Rows.Count -eq 2 -and $Script:IID_Rows[0].Selected -and -not $Script:IID_Rows[1].Selected -and $Script:IID_Rows[1].HasExisting -and $Script:IID_Rows[0].Office -eq 'Year 7') 'adding overlapping groups lists each user once, ticking only those without an ImmutableId'
        Assert ((@(Select-IidRows $Script:IID_Rows 'BEN@' $false).Name -join ',') -eq 'Ben' -and @(Select-IidRows $Script:IID_Rows 'ben' $true).Count -eq 0 -and @(Select-IidRows $Script:IID_Rows '' $false).Count -eq 2) 'immutable ID search matches name or UPN and can hide users who already have one'
        $Script:IID_Rows.Clear()
    }
    & {
        $jobs = [Collections.Generic.List[object]]::new()
        function Start-AsyncWork { param($Vars, $RefSeed, $Script, $OnComplete); $jobs.Add(@{ Vars=$Vars; Ref=$RefSeed; Script=$Script; OnComplete=$OnComplete }) }
        function Request-EtbUsers { param($OnReady) }
        function Stop-EtbAsyncWork { param($Timer) }
        $Script:DemoMode = $false; $Script:TE_Busy = $false
        $Script:TE_UI = @{ Search = [pscustomobject]@{ Text = '  ' }; Teams = [pscustomobject]@{ ItemsSource = @() }; Status = [pscustomobject]@{ Text = '' } }
        Start-TeLoad
        Start-TeSearch
        Assert ($jobs.Count -eq 0) 'team editor loads no teams until a search is entered'
        $Script:TE_UI.Search.Text = ' 20"26 '
        Start-TeSearch
        $seen = @{}
        function Get-EtbGraphCollection { param($Uri, $Headers); $seen.Uri = $Uri; $seen.Headers = $Headers; @{ displayName='Maths 2026'; resourceProvisioningOptions=@('Team') }, @{ displayName='Staff 2026'; resourceProvisioningOptions=@() } }
        $Query = $jobs[0].Vars.Query; $Token = 'fake'; $Ref = $jobs[0].Ref
        & $jobs[0].Script
        Assert ([uri]::UnescapeDataString($seen.Uri) -match '\$search="displayName:2026"' -and $seen.Headers.ConsistencyLevel -eq 'eventual' -and $Ref.Teams.Count -eq 1 -and $Ref.Teams[0].displayName -eq 'Maths 2026') 'team search asks Graph for matching names and keeps only Teams'
        Complete-TeSearch $Ref
        Assert ($Script:TE_UI.Teams.ItemsSource.Count -eq 1 -and $Script:TE_UI.Status.Text -match "1 teams match '2026'") 'team search results are listed for selection'
        $Script:TE_UI = $null
    }
    & {
        function Get-EtbGraphCollection { param($Uri, $Headers); if ($Uri -match '/teams/') { @{ userId='OWNER-ONLY' }, @{ userId='both' } } else { @{ id='owner-only' }, @{ id='group-only' } } }
        $ids = Get-EtbTeamMemberIds 't' @{}
        Assert ($ids.Count -eq 3 -and $ids.Contains('group-only') -and $ids.Contains('both')) 'team membership combines the Teams roster with its group, ignoring ID case'
    }
    & {
        . "$root/src/MainWindow.ps1"
        function Update-NavPinned { }
        $Script:NavDefs = @{ SignIn = @{}; Overview = @{} }
        Switch-NavPin 'SignIn'; Switch-NavPin 'Overview'
        Assert ((@(Get-NavPinned) -join ',') -eq 'SignIn,Overview') 'pinned tools persist in the order they were pinned'
        Switch-NavPin 'SignIn'
        Assert ((@(Get-NavPinned) -join ',') -eq 'Overview') 'pinning a pinned tool again unpins it'
        Set-AppSetting -Name 'PinnedTools' -Value @('Overview', 'RemovedTool', 'Overview')
        Assert ((@(Get-NavPinned) -join ',') -eq 'Overview') 'unknown or duplicate saved pins are ignored'
        Switch-NavPin 'Overview'
        Assert (@(Get-NavPinned).Count -eq 0) 'the last pin can be removed'
    }
} finally { Remove-Item $Global:AppRoot -Recurse -Force }
