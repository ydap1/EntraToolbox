#Requires -Version 7.0
# Offline regression checks: real runspaces and a loopback HTTP server, no tenant.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$Global:AppRoot = Join-Path ([IO.Path]::GetTempPath()) ('etb-tests-' + [guid]::NewGuid())
New-Item $Global:AppRoot -ItemType Directory | Out-Null
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "PASS $Message"
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    $message = ''
    try { & $Action } catch { $message = $_.Exception.Message }
    Assert ($message -like "*$Pattern*") "rejects $Pattern"
}
try {
    $parseErrors = @()
    foreach ($file in @(Get-ChildItem $root/src -Recurse -Filter *.ps1) + @(Get-Item $root/Start.ps1, $root/Update.ps1)) {
        $e = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$e)
        $parseErrors += $e
    }
    Assert ($parseErrors.Count -eq 0) "all application scripts parse ($($parseErrors -join '; '))"
    $authSource = Get-Content "$root/src/Auth.ps1" -Raw
    Assert ($authSource.Contains("`$iParams['Prompt'] = 'Login'") -and -not $authSource.Contains("@{ prompt = 'login' }")) 'MFA retry uses the reserved MSAL prompt parameter'
    . "$root/src/Auth.ps1"

    . "$root/src/Import.ps1"
    . "$root/src/Tools/PasswordReset.ps1"
    $passwords = @(1..1000 | ForEach-Object { New-Password })
    Assert (@($passwords | Where-Object { $_ -notmatch '^[a-z]{3}\.[a-z]{3}\.[a-z]{3}[1-9][0-9]!$' }).Count -eq 0) 'classroom password format is preserved'
    $csv = [pscustomobject]@{ Name = '=HYPERLINK("bad")'; Upn = 'student@school.test'; Password = 'cat.sun.cup42!'; Count = -2 } | ConvertTo-EtbCsvRow
    Assert ($csv.Name.StartsWith("'=") -and $csv.Upn -eq 'student@school.test' -and $csv.Password -eq 'cat.sun.cup42!' -and $csv.Count -eq -2) 'CSV formula protection preserves ordinary values and passwords'
    foreach ($file in Get-ChildItem "$root/src/Tools" -Filter *.ps1) { . $file.FullName }
    . "$root/src/Demo.ps1"
    & {
        $users = @(
            [pscustomobject]@{ id = 'a'; department = '7A' }
            [pscustomobject]@{ id = 'b'; department = '7B' }
            [pscustomobject]@{ id = 'c'; department = '10A' }
            [pscustomobject]@{ id = 'd'; department = 'Staff - Teaching' }
            [pscustomobject]@{ id = 'e'; department = 'Staff - Support' }
            [pscustomobject]@{ id = 'f'; department = $null }
        )
        $years = @(Get-EtbPopulationChoices -Users $users -Mode YearGroup)
        $departments = @(Get-EtbPopulationChoices -Users $users -Mode Department)
        Assert ($years.Count -eq 3 -and $years[0].Value -eq 7 -and $years[1].Value -eq 10 -and $years[2].Value -eq 'Staff') 'security group year choices use Teams grouping and numeric year ordering'
        Assert ($years[0].Label -eq 'Year 7 - 2 users' -and ($years[0].Users.id -join ',') -eq 'a,b') 'a year group combines classes and reports their total membership'
        Assert ($departments.Count -eq 5 -and @($departments | Where-Object Value -eq '7A')[0].Users.id -eq 'a' -and @($departments | Where-Object Value -eq 'Staff - Support')[0].Users.id -eq 'e') 'department choices preserve exact departments and their own membership'
        Assert (@(Get-EtbPopulationChoices -Users @() -Mode YearGroup).Count -eq 0) 'an empty user list has no year-group choices'
        Assert ((Get-DeptGroup 'Year 7') -eq 7 -and (Get-DeptGroup 'Year 10') -eq 10 -and (Get-DeptGroup '10B') -eq 10) 'written year labels and class codes use the same year grouping'
    }
    & {
        function Write-AppLog { param($Message, $Color) }
        function Set-MainStatus { param($Message, $Color) }
        $savedGroups = [Collections.Generic.List[string]]::new()
        function Set-TenantSetting { param($TenantId, $Name, $Value); $savedGroups.Add("${Name}:$Value") }
        $users = @(
            [pscustomobject]@{ id = 'a'; displayName = 'Ann'; userPrincipalName = 'ann@school.test'; department = '7A' }
            [pscustomobject]@{ id = 'b'; displayName = 'Ben'; userPrincipalName = 'ben@school.test'; department = '7B' }
        )
        $year = @(Get-EtbPopulationChoices -Users $users -Mode YearGroup)[0]
        $dept = @(Get-EtbPopulationChoices -Users $users -Mode Department)[0]
        foreach ($tool in 'TP', 'PwReset') {
            $rows = Get-Variable "${tool}_Rows" -Scope Script -ValueOnly
            $grid = [pscustomobject]@{ ItemsSource = $rows; SelectedItems = @() }
            $grid | Add-Member ScriptMethod SelectAll { $this.SelectedItems = @($this.ItemsSource) }
            $ui = @{ Grid = $grid; RbLive = [pscustomobject]@{ IsChecked = $false }; TeamName = [pscustomobject]@{ Text = 'Test' } }
            foreach ($name in 'BtnSelectAll','BtnSelectNone','BtnImport','BtnExport','BtnPrint','PnlStats','BtnRun','BtnCreate','BtnClear','LblSelection') {
                $ui[$name] = [pscustomobject]@{ IsEnabled = $false; Visibility = ''; Content = ''; Background = ''; Text = '' }
            }
            Set-Variable "${tool}_UI" -Scope Script -Value $ui
        }
        Set-TpPopulation -Choice $year
        Assert ($Script:TP_Rows.Count -eq 2 -and $Script:TP_UI.Grid.SelectedItems.Count -eq 2) 'Teams year loading selects every class in the year'
        Set-TpPopulation -Choice $dept
        Assert ($Script:TP_Rows.Count -eq 1 -and $Script:TP_Rows[0].Id -eq 'a' -and -not $Script:TP_Rows[0].IsOwner) 'Teams department loading replaces members with that exact department'
        $Script:TP_Creating = $true
        Set-TpPopulation -Choice $year
        Assert ($Script:TP_Rows.Count -eq 1) 'Teams population cannot change during creation'
        $Script:TP_Creating = $false
        $Script:CurrentTenantId = 'test-tenant'
        Set-PwPopulation -Choice $year -RememberYear
        Assert ($Script:PwReset_Rows.Count -eq 2 -and $Script:PwReset_UI.Grid.SelectedItems.Count -eq 2) 'password reset year loading selects every class in the year'
        Set-PwPopulation -Choice $dept
        Assert ($Script:PwReset_Rows.Count -eq 1 -and $Script:PwReset_Rows[0].Id -eq 'a' -and $savedGroups.Count -eq 1 -and $savedGroups[0] -eq 'LastYearGroup:7') 'department loading preserves the remembered password-reset year'
        $Script:PwReset_Running = $true
        Set-PwPopulation -Choice $year
        Assert ($Script:PwReset_Rows.Count -eq 1) 'password-reset population cannot change during a run'
        $Script:PwReset_Running = $false
        $Script:CurrentTenantId = $null
        function Update-BucUserFilter { }
        function Update-BucButtons { }
        $Script:BUC_AllUsers = $users
        $Script:BUC_UI = @{ DomainCombo = [pscustomobject]@{ SelectedItem = 'new.school.test' } }
        Add-BucByField -Field YearGroup -ComboBox ([pscustomobject]@{ SelectedItem = [pscustomobject]@{ Tag = 7 } })
        Add-BucByField -Field department -ComboBox ([pscustomobject]@{ SelectedItem = [pscustomobject]@{ Tag = '7A' } })
        Assert ($Script:BUC_Rows.Count -eq 2 -and $Script:BUC_Rows[0].NewUpn -eq 'ann@new.school.test') 'bulk UPN year selection sets the target domain and deduplicates an overlapping department'
        foreach ($tool in 'TP', 'PwReset', 'BUC') {
            (Get-Variable "${tool}_Rows" -Scope Script -ValueOnly).Clear()
            Set-Variable "${tool}_UI" -Scope Script -Value $null
        }
        $Script:BUC_AllUsers = @()
    }
    # Group creation uses a single create request and reports member failures
    # without losing the group ID or skipping the remaining users.
    & {
        $calls = [Collections.Generic.List[object]]::new()
        function Invoke-RestMethod {
            param($Uri, $Method, $Headers, $Body, $ContentType)
            $payload = $Body | ConvertFrom-Json
            $calls.Add([pscustomobject]@{ Uri = $Uri; Method = $Method; Body = $payload })
            if ($Uri -eq 'https://graph.microsoft.com/v1.0/groups') { return @{ id = 'created-group' } }
            if ($payload.'@odata.id' -like '*/user-2' -or $payload.'@odata.id' -like '*/device-denied') { throw 'Membership denied' }
        }
        $GroupName = 'Year 7 resources'
        $Description = 'Classroom access'
        $Members = @(1..25 | ForEach-Object { [pscustomobject]@{ Id = "user-$_"; Target = "user$_@school.test" } })
        $Token = 'test'
        $Ref = @{ GroupId = $null; Results = @() }
        & $Script:SgCreateWork
        Assert ($calls.Count -eq 26 -and $calls[0].Body.securityEnabled -and -not $calls[0].Body.mailEnabled -and $calls[0].Body.groupTypes.Count -eq 0) 'creates a security group with assigned membership before adding users'
        Assert ($calls[0].Body.displayName -eq $GroupName -and $calls[0].Body.description -eq $Description -and $calls[0].Body.mailNickname) 'group request carries the entered details and a mail nickname'
        Assert ($calls[25].Uri -eq 'https://graph.microsoft.com/v1.0/groups/created-group/members/$ref' -and $calls[25].Body.'@odata.id' -like '*/user-25') 'member requests support lists larger than 20 users'
        Assert ($Ref.GroupId -eq 'created-group' -and @($Ref.Results | Where-Object Result -eq 'Added').Count -eq 24 -and $Ref.Results[1].Error -eq 'Membership denied') 'failed membership is reported and later users are still added'
        $calls.Clear()
        $Members = @(
            [pscustomobject]@{ Id = 'user-2'; Target = 'User: denied@school.test' }
            [pscustomobject]@{ Id = 'entra-object-1'; Target = 'Device: Classroom PC [device-id-1]' }
        )
        $Ref = @{ GroupId = $null; Results = @() }
        & $Script:SgCreateWork
        Assert ($calls[2].Body.'@odata.id' -eq 'https://graph.microsoft.com/v1.0/directoryObjects/entra-object-1') 'mixed membership uses the Entra object ID, not the device registration ID'
        Assert ($Ref.Results[0].Result -eq 'Failed' -and $Ref.Results[1].Result -eq 'Added' -and $Ref.Results[1].Target -eq $Members[1].Target) 'device results retain an audit target and proceed after a failed user'
        $calls.Clear()
        $Members = @($Members[1])
        $Ref = @{ GroupId = $null; Results = @() }
        & $Script:SgCreateWork
        Assert ($calls.Count -eq 2 -and $Ref.Results[0].Result -eq 'Added') 'device-only group creation does not require users'
        $calls.Clear()
        $Members = @([pscustomobject]@{ Id = 'device-denied'; Target = 'Device: Restricted PC' }, $Members[0])
        $Ref = @{ GroupId = $null; Results = @() }
        & $Script:SgCreateWork
        Assert ($Ref.Results[0].Error -eq 'Membership denied' -and $Ref.Results[1].Result -eq 'Added' -and $Ref.GroupId -eq 'created-group') 'failed devices are reported individually without discarding the group or skipping later devices'
        $calls.Clear()
        $Members = @()
        $Ref = @{ GroupId = $null; Results = @() }
        & $Script:SgCreateWork
        Assert ($calls.Count -eq 1 -and $Ref.GroupId -eq 'created-group') 'empty security group creation makes no member requests'
        $calls.Clear()
        $Description = ''
        $Ref = @{ GroupId = $null; Results = @() }
        & $Script:SgCreateWork
        Assert ($calls.Count -eq 1 -and 'description' -notin $calls[0].Body.PSObject.Properties.Name) 'a blank description is omitted because Graph rejects empty strings'
        function Invoke-RestMethod { throw 'Group creation denied' }
        $Ref = @{ GroupId = $null; Results = @() }
        Assert-Throws { & $Script:SgCreateWork } 'Group creation denied'
        Assert (-not $Ref.GroupId -and $Ref.Results.Count -eq 0) 'failed group creation cannot report successful membership'
    }
    & {
        $Script:SG_UI = @{
            Editor = [pscustomobject]@{ IsEnabled = $true }; Remove = [pscustomobject]@{ IsEnabled = $true }
            New = [pscustomobject]@{ IsEnabled = $true }; Create = [pscustomobject]@{ IsEnabled = $false }
            Clear = [pscustomobject]@{ IsEnabled = $false }
            Name = [pscustomobject]@{ Text = 'Classroom access' }; Count = [pscustomobject]@{ Text = '' }
            Status = [pscustomobject]@{ Text = '' }
            DeviceSearch = [pscustomobject]@{ Text = '' }; DeviceMatches = [pscustomobject]@{ ItemsSource = @() }
            DeviceStatus = [pscustomobject]@{ Text = '' }; ReloadDevices = [pscustomobject]@{ IsEnabled = $false }
        }
        $user = [pscustomobject]@{ id = 'pupil'; displayName = 'Pupil'; userPrincipalName = 'pupil@school.test'; department = 'Year 7' }
        Add-SgUsers @($user, $user)
        Add-SgUsers @($user)
        Assert ($Script:SG_Rows.Count -eq 1) 'combining security group imports does not duplicate members'
        $Script:SG_Rows.Clear()
        $users = @(
            [pscustomobject]@{ id = 'a'; displayName = 'Ann'; userPrincipalName = 'ann@school.test'; department = '7A' }
            [pscustomobject]@{ id = 'b'; displayName = 'Ben'; userPrincipalName = 'ben@school.test'; department = '7B' }
        )
        Add-SgUsers @(Get-EtbPopulationChoices -Users $users -Mode YearGroup)[0].Users
        Add-SgUsers @(Get-EtbPopulationChoices -Users $users -Mode Department)[0].Users
        Assert ($Script:SG_Rows.Count -eq 2) 'adding a department after its year group does not duplicate pupils'
        $device = [pscustomobject]@{ id = 'entra-object-1'; deviceId = 'registration-1'; displayName = 'Classroom PC'; operatingSystem = 'Windows' }
        Add-SgDevices @($device, $device)
        Add-SgDevices @($device)
        Assert ($Script:SG_Rows.Count -eq 3 -and $Script:SG_Rows[2].MemberType -eq 'Device' -and $Script:SG_Rows[2].Id -eq 'entra-object-1' -and $Script:SG_Rows[2].Identifier -eq 'registration-1') 'device additions deduplicate by object ID and preserve the separate device ID'
        Assert ($Script:SG_Rows[0].MemberType -eq 'User' -and $Script:SG_Rows[0].Identifier -eq 'ann@school.test') 'mixed preview retains user identity and type'
        $Script:SG_Busy = $true
        Add-SgDevices @([pscustomobject]@{ id = 'blocked' })
        Clear-SgMembers
        $Script:SG_Busy = $false
        $Script:SG_GroupId = 'created-group'
        Add-SgDevices @([pscustomobject]@{ id = 'blocked' })
        Clear-SgMembers
        Assert ($Script:SG_Rows.Count -eq 3) 'member editing is blocked during creation and after a group is created'
        $Script:SG_GroupId = $null
        $Script:SG_Devices = @($device)
        foreach ($query in 'classROOM', 'registration-1', 'entra-object-1') {
            $Script:SG_UI.DeviceSearch.Text = $query
            Update-SgDeviceSearch
            Assert ($Script:SG_UI.DeviceMatches.ItemsSource.Count -eq 1) 'device search matches name, device ID and object ID'
        }
        $Script:SG_UI.DeviceSearch.Text = 'absent'
        Update-SgDeviceSearch
        Assert ($Script:SG_UI.DeviceMatches.ItemsSource.Count -eq 0) 'device search clears old matches when nothing matches'
        $Script:SG_UI.DeviceSearch.Text = ''
        $Script:SG_Devices = @(1..60 | ForEach-Object { [pscustomobject]@{ id = "entra-$_" } })
        Update-SgDeviceSearch
        Assert ($Script:SG_UI.DeviceMatches.ItemsSource.Count -eq 50) 'device picker caps visible search results'
        function Start-AsyncWork { throw 'Preview must not start a worker' }
        function Write-AppLog { param($Message, $Color) }
        $Script:AccessToken = 'test'
        $Script:DryMode = $true
        Start-SgCreate
        Assert ($Script:SG_UI.Status.Text -like '[[]DRY[]]*No changes made*' -and -not $Script:SG_GroupId) 'security group dry run leaves the directory unchanged'
        $Script:DryMode = $false
        $Script:DemoMode = $true
        Start-SgDeviceLoad
        Assert ($Script:SG_Devices.Count -eq $Script:Demo_DirectoryDevices.Count -and $Script:SG_Devices.Count -gt 0) 'device demo loads Entra-shaped records without a network worker'
        Start-SgCreate
        Assert ($Script:SG_UI.Status.Text -like '[[]DEMO[]]*No changes made*') 'security group demo never starts a network worker'
        $Script:DemoMode = $false
        Clear-SgMembers
        Assert ($Script:SG_Rows.Count -eq 0 -and $Script:SG_UI.Name.Text -eq 'Classroom access') 'Clear all removes mixed members but keeps group details'
        function Start-AsyncWork {
            param($RefSeed, $Script, $OnComplete)
            $script:deviceCompletion = $OnComplete
            [pscustomobject]@{ Active = $true }
        }
        $Script:SG_Users = $users
        Start-SgDeviceLoad
        Assert ($Script:SG_DeviceTimer -and -not $Script:SG_UI.ReloadDevices.IsEnabled -and $Script:SG_Devices.Count -eq 0) 'device refresh disables reload and clears stale search data'
        & $script:deviceCompletion @{ Error = 'Forbidden'; Devices = @() }
        Assert (-not $Script:SG_DeviceTimer -and $Script:SG_UI.ReloadDevices.IsEnabled -and $Script:SG_UI.DeviceStatus.Text -like '*Device.Read.All*' -and $Script:SG_Users.Count -eq 2) 'device load failure offers consent guidance and retry without losing users'
        Start-SgDeviceLoad
        & $script:deviceCompletion @{ Error = $null; Devices = @($device) }
        Assert ($Script:SG_Devices.Count -eq 1 -and $Script:SG_UI.DeviceMatches.ItemsSource.Count -eq 1) 'device reload recovers after an error'
        $Script:AccessToken = $null
        $Script:SG_Users = @()
        $Script:SG_Devices = @()
        $Script:SG_Rows.Clear()
        $Script:SG_UI = $null
    }
    & {
        $calls = [Collections.Generic.List[string]]::new()
        function Invoke-RestMethod {
            param($Uri, $Headers, $Method)
            $calls.Add($Uri)
            Assert ($Method -eq 'GET' -and $Headers.Authorization -eq 'Bearer test') 'device discovery only reads directory data'
            if ($calls.Count -eq 1) {
                return @{ value = @(@{ id = 'object-1'; deviceId = 'registration-1' }); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/devices?$skiptoken=next' }
            }
            return @{ value = @(@{ id = 'object-2'; deviceId = 'registration-2' }) }
        }
        $Token = 'test'
        $Ref = @{ Devices = @() }
        & $Script:SgDeviceLoadWork
        Assert ($calls.Count -eq 2 -and $calls[0] -eq 'https://graph.microsoft.com/v1.0/devices?$select=id,deviceId,displayName,operatingSystem' -and $Ref.Devices.Count -eq 2) 'device discovery uses Entra directory devices and follows pagination'
        Assert ($Script:GraphScopes -contains 'https://graph.microsoft.com/Device.Read.All') 'device membership requests the delegated device read permission'
    }
    $missing = @()
    $xamlCount = 0
    foreach ($file in Get-ChildItem "$root/src" -Recurse -Filter *.ps1) {
        $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
        foreach ($command in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.CommandAst] }, $true)) {
            $name = $command.GetCommandName()
            if ($name -eq 'if') { throw "Invalid conditional argument: $($command.Extent)" }
            if ($name -like 'Start-*Demo' -and -not (Get-Command $name -ErrorAction SilentlyContinue)) { $missing += $name }
        }
        foreach ($node in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.StringConstantExpressionAst] -and $a.Value -match '^<(Grid|Window)\s+xmlns=' }, $true)) {
            $themed = Invoke-ThemeXaml $node.Value
            $null = [xml]$themed
            # Shared styles are appended only when absent; a duplicate key here
            # would still be valid XML but would fail at XamlReader.Load.
            $dupes = @([regex]::Matches($themed, 'x:Key="([^"]+)"') |
                ForEach-Object { $_.Groups[1].Value } |
                Group-Object | Where-Object Count -gt 1)
            if ($dupes) { throw "$($file.Name): duplicate resource key $($dupes[0].Name)" }
            $xamlCount++
        }
    }
    Assert ($missing.Count -eq 0) "all referenced demo loaders exist ($($missing -join ', '))"
    Assert ($xamlCount -gt 10) "all $xamlCount application XAML documents are well-formed after theme substitution"
    # Dry run must not launch a worker, claim success, or change prompt status.
    $Script:DryMode = $true
    $Script:DemoMode = $false
    $Script:UPR_UI = @{ InlineStatus = [pscustomobject]@{ Text=''; Foreground=''; Visibility='' }; PromptStatus = [pscustomobject]@{ Text='unchanged' } }
    function Set-MainStatus { param($Text, $Color) }
    function Write-UprLog { param($Msg, $Color) }
    Start-UprPasswordReset -User ([pscustomobject]@{ id='test'; displayName='Test User' }) -Password (ConvertTo-SecureString 'cat.sun.cup42!' -AsPlainText -Force) -Force $true
    Assert ($Script:UPR_UI.InlineStatus.Text -like '*No changes made*' -and $Script:UPR_UI.PromptStatus.Text -eq 'unchanged' -and $Script:AsyncJobs.Count -eq 0) 'dry-run password reset leaves actual account state untouched'
    $Script:DryMode = $false
    & {
        function Start-AsyncWork {
            param($Script, $OnComplete, $Vars, $RefSeed)
            $Script:CapturedCompletion = $OnComplete
            $Script:CapturedRef = $RefSeed
        }
        $Script:UPR_ProfTimer = $null
        $Script:UPR_UI = @{
            PromptStatus = [pscustomobject]@{ Text=''; Foreground='' }
            BtnReset = [pscustomobject]@{ IsEnabled=$true }
            UserList = [pscustomobject]@{ SelectedItem = [pscustomobject]@{ Tag = [pscustomobject]@{ id='old-user' } } }
        }
        Start-UprProfileLoad -UserId 'old-user'
        $Script:UPR_UI.UserList.SelectedItem.Tag.id = 'new-user'
        $Script:UPR_UI.PromptStatus.Text = 'New user status'
        & $Script:CapturedCompletion $Script:CapturedRef
        Assert ($Script:UPR_UI.PromptStatus.Text -eq 'New user status') 'late profile reads cannot overwrite a different selected user'
    }


    # ── Shared style injection ────────────────────────────────────────────────
    $bare = Invoke-ThemeXaml '<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"><Grid.Resources></Grid.Resources></Grid>'
    Assert ($bare -like '*TargetType="DataGrid"*' -and $bare -like '*x:Key="DgRow"*') 'a document without its own grid styles is given the shared ones'
    $owned = Invoke-ThemeXaml '<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"><Grid.Resources><Style TargetType="DataGrid"><Setter Property="RowHeight" Value="99"/></Style></Grid.Resources></Grid>'
    Assert (([regex]::Matches($owned, '<Style TargetType="DataGrid">')).Count -eq 1) 'a tool that declares its own style is not given a competing copy'
    Assert ($owned -like '*Value="99"*') 'the tool keeps its own values'

    # ── User list import ──────────────────────────────────────────────────────
    $parsed = @(Get-EtbUpnsFromText "a@school.test`r`nB@SCHOOL.TEST`na@school.test`nnot-a-upn`n`n")
    Assert ($parsed.Count -eq 2) 'pasted usernames are de-duplicated case-insensitively and junk is dropped'
    $row = @(Get-EtbUpnsFromText '"Smith, John",jsmith@school.test,Year 7')
    Assert ($row.Count -eq 1 -and $row[0] -eq 'jsmith@school.test') 'a whole spreadsheet row yields just its username'
    $csvPath = Join-Path $Global:AppRoot 'import.csv'
    'Name,Email' | Set-Content $csvPath
    'Ann,ann@school.test' | Add-Content $csvPath
    Assert ((@(Get-EtbUpnsFromCsv -Path $csvPath))[0] -eq 'ann@school.test') 'CSV import finds the username column whatever it is called'
    $lookup = Select-EtbUsersByUpn -Users @([pscustomobject]@{ userPrincipalName = 'ann@school.test'; id = '1' }) -Upns @('ANN@school.test', 'gone@school.test')
    Assert ($lookup.Matched.Count -eq 1 -and $lookup.Missing -eq 'gone@school.test') 'unmatched names are reported rather than silently dropped'

    # ── Change record ─────────────────────────────────────────────────────────
    $Script:CurrentTenantId   = 'tenant-under-test'
    $Script:CurrentAccountUPN = 'admin@school.test'
    $Script:DemoMode = $false
    Write-EtbAudit -Tool 'Year Group Passwords' -Action 'Reset password' -Target 'pupil@school.test'
    $auditPath = Get-EtbAuditPath
    $logged = @(Import-Csv $auditPath)
    Assert ($logged.Count -eq 1 -and $logged[0].Target -eq 'pupil@school.test' -and $logged[0].Operator -eq 'admin@school.test') 'a live change is recorded with its operator and target'
    Assert (($logged[0].PSObject.Properties.Name -notcontains 'Password')) 'the change record has no password column'
    $Script:DemoMode = $true
    Write-EtbAudit -Tool 'Year Group Passwords' -Action 'Reset password' -Target 'demo@school.test'
    $Script:DemoMode = $false
    Assert ((@(Import-Csv $auditPath)).Count -eq 1) 'demo mode records nothing'
    $Script:CurrentTenantId = $null

    # ── Mid-batch token refresh ───────────────────────────────────────────────
    $Ref = @{ Token = 'REFRESHED' }
    Assert-Throws { Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/users' -Headers @{ Authorization = 'Bearer DEMO' } } 'Demo mode'
    $Ref = $null
    $Script:AppFont = 'Font & "quoted"'
    $fontXaml = Invoke-ThemeXaml '<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><TextBlock FontFamily="Segoe UI"/></Grid>'
    $null = [xml]$fontXaml
    Assert ($fontXaml -like '*&amp;*' -and $fontXaml -like '*&quot;*') 'saved font names are safely escaped in XAML'
    $Script:AppFont = 'Segoe UI'
    $Script:Theme.Accent = '#F59E0B'
    $accentXaml = Invoke-ThemeXaml '<Button Background="#6366F1" Foreground="White"/>'
    Assert ($accentXaml -like '*Foreground="#000000"*') 'amber action buttons use contrasting dark text'

    # Substitute only the dispatcher for Linux. Pipelines/runspaces are real.
    function New-EtbDispatcherTimer {
        param([int]$IntervalMs)
        $t = [pscustomobject]@{ Tag=$null; IsEnabled=$false; Handler=$null }
        $t | Add-Member ScriptMethod Add_Tick { param($handler) $this.Handler = $handler }
        $t | Add-Member ScriptMethod Start { $this.IsEnabled = $true }
        $t | Add-Member ScriptMethod Stop { $this.IsEnabled = $false }
        $t | Add-Member ScriptMethod Fire { & $this.Handler }
        $t
    }
    function Wait-JobCleanup($Timer) {
        $deadline = [datetime]::UtcNow.AddSeconds(10)
        while ($Timer.Tag -and [datetime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 20
            if ($Timer.IsEnabled) { $Timer.Fire() }
            $Script:WorkerCleanupTimer.Fire()
        }
        Assert ($null -eq $Timer.Tag) 'worker releases its pipeline, runspace and timer state'
    }
    $Script:Completed = 0
    $job = Start-AsyncWork -Script { $Ref['Value'] = 42 } -OnComplete { param($ref) $Script:Completed = $ref.Value }
    Wait-JobCleanup $job
    Assert ($Script:Completed -eq 42) 'completed worker delivers its result'
    $job = Start-AsyncWork -BulkName 'Tracking test' -BulkTotal 2 -Script {
        Publish-EtbWriteResult @{ Uri='https://graph.microsoft.com/v1.0/users/u'; Method='PATCH'; Body='{"userPrincipalName":"new@school.test"}' } 'Succeeded'
        Publish-EtbWriteResult @{ Uri='https://graph.microsoft.com/v1.0/users/v'; Method='PATCH'; Body='{"userPrincipalName":"other@school.test"}' } 'Uncertain' 'Connection lost'
    } -OnComplete { }
    Wait-JobCleanup $job
    $bulkRun=$Script:BulkRuns[0]
    Assert ($bulkRun.Rows.Count -eq 2 -and $bulkRun.State -eq 'Finished' -and -not $bulkRun.Timer) 'bulk runs drain worker results and finish without retaining a live timer'
    Assert (-not $bulkRun.Ref.ContainsKey('Token')) 'completed bulk runs release their worker token'

    $job = Start-AsyncWork -Script { Start-Sleep -Seconds 30 } -OnComplete { $Script:Completed = -1 }
    $job.Stop()
    Wait-JobCleanup $job
    Assert ($Script:Completed -eq 42) 'superseded worker is canceled without a stale callback'
    $job = Start-AsyncWork -NoToken -Script { $Ref['Token'] = 'OLD TENANT' } -OnComplete { $Script:AccessToken = $args[0].Token }
    Reset-EtbSessionWork
    $Script:AccessToken = 'NEW TENANT'
    Wait-JobCleanup $job
    Assert ($Script:AccessToken -eq 'NEW TENANT') 'late refresh cannot overwrite a different tenant token'
    Assert ($Script:AsyncJobs.Count -eq 0) 'worker registry returns to zero'

    # A stopped batch must still reach OnComplete, or the tool is left disabled
    # with no idea how far it got.
    $Script:CancelDone = $null
    $job = Start-AsyncWork -RefSeed @{ Processed = 0 } -Script {
        for ($i = 0; $i -lt 200; $i++) {
            if ($Ref['CancelRequested']) { break }
            $Ref['Processed']++
            Start-Sleep -Milliseconds 10
        }
    } -OnComplete { param($ref) $Script:CancelDone = $ref['Processed'] }
    Start-Sleep -Milliseconds 150
    Request-EtbAsyncCancel $job
    Wait-JobCleanup $job
    Assert ($null -ne $Script:CancelDone -and $Script:CancelDone -lt 200) 'a cancelled batch stops early and still reports its progress'

    # Long batches outlive the token they captured at launch.
    $Script:AccessToken = 'ORIGINAL'
    $job = Start-AsyncWork -Script { Start-Sleep -Milliseconds 400 } -OnComplete { }
    Assert ($job.Tag.Ref['Token'] -eq 'ORIGINAL') 'a worker starts with the current token'
    $Script:AccessToken = 'REFRESHED'
    Publish-EtbWorkerToken
    Assert ($job.Tag.Ref['Token'] -eq 'REFRESHED') 'a silent refresh reaches workers already running'
    Wait-JobCleanup $job
    $Script:AccessToken = $null
    $job = Start-AsyncWork -Script { Get-Item '/etb-missing-path-974397' } -OnComplete { param($ref) $Script:WorkerError = $ref.Error }
    Wait-JobCleanup $job
    Assert ([bool]$Script:WorkerError) 'worker cmdlet failures cannot be reported as success'
    $Script:DryMode = $true
    $job = Start-AsyncWork -Script { Invoke-RestMethod -Uri 'http://localhost:1/' -Method POST } -OnComplete { param($ref) $Script:ReadOnlyError = $ref.Error }
    $Script:DryMode = $false
    Wait-JobCleanup $job
    Assert ($Script:ReadOnlyError -like '*Dry run is active*') 'background workers retain the dry-run policy captured at launch'
    Assert ($Script:GraphScopes -contains 'https://graph.microsoft.com/DeviceManagementManagedDevices.PrivilegedOperations.All' -and $Script:GraphScopes -contains 'https://graph.microsoft.com/User-PasswordProfile.ReadWrite.All') 'device sync and password resets request documented scopes'

    $headers = @{ Authorization = 'Bearer test' }
    foreach ($uri in 'http://graph.microsoft.com/v1.0/users', 'https://example.com/users', 'https://graph.microsoft.com.evil.test/users', 'https://graph.microsoft.com:444/users') {
        Assert-Throws { Invoke-RestMethod -Uri $uri -Headers $headers } 'Refusing to send credentials'
    }
    $Script:DryMode = $true
    Assert-Throws { Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/users' -Method POST -Headers $headers } 'Dry run is active'
    $Script:DryMode = $false
    $Ref = @{ Cancelled = $true }
    Assert-Throws { Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/users' -Headers $headers } 'canceled'
    $Ref = $null
    $response = [Net.Http.HttpResponseMessage]::new()
    $response.Headers.RetryAfter = [Net.Http.Headers.RetryConditionHeaderValue]::new([TimeSpan]::FromSeconds(120))
    Assert ((Get-EtbRetryDelay $response 0) -eq 120) 'Retry-After longer than 60 seconds is respected'
    $response.Headers.RetryAfter = [Net.Http.Headers.RetryConditionHeaderValue]::new([DateTimeOffset]::UtcNow.AddSeconds(100))
    Assert ((Get-EtbRetryDelay $response 0) -ge 99) 'HTTP-date Retry-After is respected'
    $response.Dispose()

    # Exercise the actual HTTP cmdlet: retries, response headers, ambiguous writes.
    $portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $portProbe.Start(); $port = $portProbe.LocalEndpoint.Port; $portProbe.Stop()
    $listener = [Net.HttpListener]::new()
    $listener.Prefixes.Add("http://localhost:$port/")
    $listener.Start()
    $counts = [hashtable]::Synchronized(@{})
    $server = [powershell]::Create()
    $null = $server.AddScript({
        param($listener, $counts)
        try {
            while ($listener.IsListening) {
                $ctx = $listener.GetContext()
                $path = $ctx.Request.Url.AbsolutePath
                $counts[$path] = 1 + $counts[$path]
                $ctx.Response.ContentType = 'application/json'
                $ctx.Response.Headers.Add('Location', '/created')
                $status = if ($path -eq '/accepted') { 202 } elseif ($path -eq '/write') { 503 } elseif ($path -eq '/retry' -and $counts[$path] -eq 1) { 429 } else { 200 }
                $ctx.Response.StatusCode = $status
                $ctx.Response.Headers.Add('Retry-After', '1')
                $payload = if ($path -eq '/pages') {
                    '{"value":[{"id":1}],"@odata.nextLink":"' + $ctx.Request.Url.GetLeftPart([UriPartial]::Authority) + '/page2"}'
                } elseif ($path -eq '/page2') { '{"value":[{"id":2}]}' }
                elseif ($path -eq '/cycle') { '{"value":[],"@odata.nextLink":"' + $ctx.Request.Url.AbsoluteUri + '"}' }
                else { '{"ok":true}' }
                $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
                $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $ctx.Response.Close()
            }
        } catch { }
    }).AddArgument($listener).AddArgument($counts)
    $serverAsync = $server.BeginInvoke()
    try {
        $result = Invoke-RestMethod -Uri "http://localhost:$port/retry" -ResponseHeadersVariable returnedHeaders
        Assert ($result.ok -and $counts['/retry'] -eq 2) '429 request retries and returns the response'
        Assert ($returnedHeaders.Location -contains '/created') 'response headers reach the caller (Teams provisioning)'
        $Ref = @{ BulkQueue=[Collections.Concurrent.ConcurrentQueue[object]]::new() }
        Assert-Throws { Invoke-RestMethod -Uri "http://localhost:$port/write" -Method POST } '503'
        $captured=$null; $null=$Ref.BulkQueue.TryDequeue([ref]$captured)
        Assert ($captured.Result -eq 'Uncertain') 'real HTTP write errors reach the shared results queue once'
        $null=Invoke-RestMethod -Uri "http://localhost:$port/ok" -Method POST
        $null=$Ref.BulkQueue.TryDequeue([ref]$captured)
        Assert ($captured.Result -eq 'Succeeded') 'real HTTP successes reach the shared results queue'
        $null=Invoke-RestMethod -Uri "http://localhost:$port/accepted" -Method POST
        $null=$Ref.BulkQueue.TryDequeue([ref]$captured)
        Assert ($captured.Result -eq 'Accepted') 'HTTP 202 acceptance is not reported as completed provisioning'
        $Ref=$null
        Assert ($counts['/write'] -eq 1) 'ambiguous writes are never replayed'
        $pages = @(Get-EtbGraphCollection -Uri "http://localhost:$port/pages")
        Assert ($pages.Count -eq 2 -and $pages[1].id -eq 2) 'collection reads include subsequent pages'
        Assert-Throws { Get-EtbGraphCollection -Uri "http://localhost:$port/cycle" } 'repeated pagination link'
    } finally {
        $listener.Stop(); $listener.Close()
        $server.EndInvoke($serverAsync) | Out-Null
        $server.Dispose()
    }
} finally {
    Remove-Item $Global:AppRoot -Recurse -Force -ErrorAction SilentlyContinue
}
