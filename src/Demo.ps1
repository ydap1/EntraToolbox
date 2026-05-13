<#
    Demo/showcase mode for Art's Entra Toolbox.
    Dot-sourced by Start.ps1 after Auth.ps1.
    Provides a fake Oakfield Academy tenant so the app can be demonstrated
    without connecting to a real tenant or exposing any real data.
#>

$Script:DemoMode = $false

# ── Fake users ─────────────────────────────────────────────────────────────────
$Script:Demo_Users = @(
    # Year 10
    [PSCustomObject]@{ id='u-y10-01'; displayName='Amara Osei';         userPrincipalName='amara.osei@oakfield.sch.uk';         department='10A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-02'; displayName='Callum Reid';        userPrincipalName='callum.reid@oakfield.sch.uk';        department='10A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-03'; displayName='Priya Sharma';       userPrincipalName='priya.sharma@oakfield.sch.uk';       department='10B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-04'; displayName='Jake Morrison';      userPrincipalName='jake.morrison@oakfield.sch.uk';      department='10B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-05'; displayName='Sophie Chen';        userPrincipalName='sophie.chen@oakfield.sch.uk';        department='10B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-06'; displayName='Liam Walsh';         userPrincipalName='liam.walsh@oakfield.sch.uk';         department='10C'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-07'; displayName='Fatima Al-Hassan';   userPrincipalName='fatima.alhassan@oakfield.sch.uk';    department='10C'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-08'; displayName='Noah Clarke';        userPrincipalName='noah.clarke@oakfield.sch.uk';        department='10A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-09'; displayName='Aisha Patel';        userPrincipalName='aisha.patel@oakfield.sch.uk';        department='10B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-10'; displayName='Dylan Roberts';      userPrincipalName='dylan.roberts@oakfield.sch.uk';      department='10C'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-11'; displayName='Mia Thompson';       userPrincipalName='mia.thompson@oakfield.sch.uk';       department='10A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-12'; displayName='Aaron Khan';         userPrincipalName='aaron.khan@oakfield.sch.uk';         department='10C'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-13'; displayName='Emma Wilson';        userPrincipalName='emma.wilson@oakfield.sch.uk';        department='10B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-14'; displayName='Joshua Okafor';      userPrincipalName='joshua.okafor@oakfield.sch.uk';      department='10A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-15'; displayName='Isabelle Martin';    userPrincipalName='isabelle.martin@oakfield.sch.uk';    department='10C'; accountEnabled=$true },
    # Year 11
    [PSCustomObject]@{ id='u-y11-01'; displayName='Tyler Hughes';       userPrincipalName='tyler.hughes@oakfield.sch.uk';       department='11A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-02'; displayName='Zara Ahmed';         userPrincipalName='zara.ahmed@oakfield.sch.uk';         department='11B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-03'; displayName='Connor Burke';       userPrincipalName='connor.burke@oakfield.sch.uk';       department='11A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-04'; displayName='Leila Naseri';       userPrincipalName='leila.naseri@oakfield.sch.uk';       department='11B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-05'; displayName='Marcus Johnson';     userPrincipalName='marcus.johnson@oakfield.sch.uk';     department='11C'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-06'; displayName='Hannah Lee';         userPrincipalName='hannah.lee@oakfield.sch.uk';         department='11A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-07'; displayName='Ethan Nguyen';       userPrincipalName='ethan.nguyen@oakfield.sch.uk';       department='11C'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-08'; displayName='Chloe Dubois';       userPrincipalName='chloe.dubois@oakfield.sch.uk';       department='11B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-09'; displayName='Ryan Cooper';        userPrincipalName='ryan.cooper@oakfield.sch.uk';        department='11A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-10'; displayName='Nadia Kowalski';     userPrincipalName='nadia.kowalski@oakfield.sch.uk';     department='11C'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-11'; displayName='Samuel Osei';        userPrincipalName='samuel.osei@oakfield.sch.uk';        department='11B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-12'; displayName='Bethany Ellis';      userPrincipalName='bethany.ellis@oakfield.sch.uk';      department='11A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-13'; displayName='Kieran Murphy';      userPrincipalName='kieran.murphy@oakfield.sch.uk';      department='11C'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-14'; displayName='Anaya Singh';        userPrincipalName='anaya.singh@oakfield.sch.uk';        department='11B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-15'; displayName='Leo Fernandez';      userPrincipalName='leo.fernandez@oakfield.sch.uk';      department='11A'; accountEnabled=$true },
    # Year 12
    [PSCustomObject]@{ id='u-y12-01'; displayName='Olivia Bennett';     userPrincipalName='olivia.bennett@oakfield.sch.uk';     department='12A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y12-02'; displayName='James Carter';       userPrincipalName='james.carter@oakfield.sch.uk';       department='12A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y12-03'; displayName='Maya Ramachandran';  userPrincipalName='maya.ramachandran@oakfield.sch.uk';  department='12B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y12-04'; displayName='William Scott';      userPrincipalName='william.scott@oakfield.sch.uk';      department='12B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y12-05'; displayName='Aria Delgado';       userPrincipalName='aria.delgado@oakfield.sch.uk';       department='12A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y12-06'; displayName='Daniel Park';        userPrincipalName='daniel.park@oakfield.sch.uk';        department='12B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y12-07'; displayName='Freya Johansson';    userPrincipalName='freya.johansson@oakfield.sch.uk';    department='12A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y12-08'; displayName='Alex Mitchell';      userPrincipalName='alex.mitchell@oakfield.sch.uk';      department='12B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y12-09'; displayName='Serena Ibrahim';     userPrincipalName='serena.ibrahim@oakfield.sch.uk';     department='12A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y12-10'; displayName='Luke Petrov';        userPrincipalName='luke.petrov@oakfield.sch.uk';        department='12B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y12-11'; displayName='Imogen Taylor';      userPrincipalName='imogen.taylor@oakfield.sch.uk';      department='12A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y12-12'; displayName='Ravi Krishnamurthy'; userPrincipalName='ravi.krishnamurthy@oakfield.sch.uk'; department='12B'; accountEnabled=$true },
    # Staff
    [PSCustomObject]@{ id='u-st-01'; displayName='Michael Graves';      userPrincipalName='m.graves@oakfield.sch.uk';           department='Staff'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-st-02'; displayName='Sarah Nkosi';         userPrincipalName='s.nkosi@oakfield.sch.uk';            department='Staff'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-st-03'; displayName='Tom Lawson';          userPrincipalName='t.lawson@oakfield.sch.uk';           department='Staff'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-st-04'; displayName='Claire Atkins';       userPrincipalName='c.atkins@oakfield.sch.uk';           department='Staff'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-st-05'; displayName='Paul Yeboah';         userPrincipalName='p.yeboah@oakfield.sch.uk';           department='Staff'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-st-06'; displayName='Helen Marsh';         userPrincipalName='h.marsh@oakfield.sch.uk';            department='Staff'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-st-07'; displayName='James Obrien';        userPrincipalName='j.obrien@oakfield.sch.uk';           department='Staff'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-st-08'; displayName='Priya Mehta';         userPrincipalName='p.mehta@oakfield.sch.uk';            department='Staff'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-st-09'; displayName='Dave Fowler';         userPrincipalName='d.fowler@oakfield.sch.uk';           department='Staff'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-st-10'; displayName='Rachel Green';        userPrincipalName='r.green@oakfield.sch.uk';            department='Staff'; accountEnabled=$true }
)

# ── Fake devices ───────────────────────────────────────────────────────────────
# lastSyncDateTime strings are UTC (relative to 2026-05-13)
$Script:Demo_Devices = @(
    [PSCustomObject]@{ id='d-lt-001'; deviceName='OAKF-LT-001'; lastSyncDateTime='2026-05-12T09:14:00Z'
        usersLoggedOn=@( @{userId='u-y10-01';lastLogOnDateTime='2026-05-12T08:55:00Z'}, @{userId='u-y10-02';lastLogOnDateTime='2026-05-10T13:22:00Z'} ) },
    [PSCustomObject]@{ id='d-lt-002'; deviceName='OAKF-LT-002'; lastSyncDateTime='2026-05-10T11:30:00Z'
        usersLoggedOn=@( @{userId='u-y10-03';lastLogOnDateTime='2026-05-10T11:00:00Z'}, @{userId='u-y10-04';lastLogOnDateTime='2026-05-09T14:10:00Z'} ) },
    [PSCustomObject]@{ id='d-lt-003'; deviceName='OAKF-LT-003'; lastSyncDateTime='2026-05-08T08:00:00Z'
        usersLoggedOn=@( @{userId='u-y10-05';lastLogOnDateTime='2026-05-08T07:45:00Z'}, @{userId='u-y10-06';lastLogOnDateTime='2026-05-07T15:30:00Z'} ) },
    [PSCustomObject]@{ id='d-lt-004'; deviceName='OAKF-LT-004'; lastSyncDateTime='2026-04-25T14:00:00Z'
        usersLoggedOn=@( @{userId='u-y10-07';lastLogOnDateTime='2026-04-25T13:50:00Z'}, @{userId='u-y10-08';lastLogOnDateTime='2026-04-24T09:20:00Z'} ) },
    [PSCustomObject]@{ id='d-lt-005'; deviceName='OAKF-LT-005'; lastSyncDateTime='2026-04-20T10:45:00Z'
        usersLoggedOn=@( @{userId='u-y10-09';lastLogOnDateTime='2026-04-20T10:30:00Z'}, @{userId='u-y10-10';lastLogOnDateTime='2026-04-18T12:00:00Z'} ) },
    [PSCustomObject]@{ id='d-lt-006'; deviceName='OAKF-LT-006'; lastSyncDateTime='2026-05-02T09:00:00Z'
        usersLoggedOn=@( @{userId='u-y11-01';lastLogOnDateTime='2026-05-02T08:45:00Z'}, @{userId='u-y11-02';lastLogOnDateTime='2026-04-30T16:00:00Z'} ) },
    [PSCustomObject]@{ id='d-lt-007'; deviceName='OAKF-LT-007'; lastSyncDateTime='2026-03-30T08:30:00Z'
        usersLoggedOn=@( @{userId='u-y11-03';lastLogOnDateTime='2026-03-30T08:20:00Z'}, @{userId='u-y11-04';lastLogOnDateTime='2026-03-28T14:15:00Z'} ) },
    [PSCustomObject]@{ id='d-lt-008'; deviceName='OAKF-LT-008'; lastSyncDateTime='2026-03-15T12:00:00Z'
        usersLoggedOn=@( @{userId='u-y11-05';lastLogOnDateTime='2026-03-15T11:50:00Z'}, @{userId='u-y11-06';lastLogOnDateTime='2026-03-14T09:30:00Z'} ) },
    [PSCustomObject]@{ id='d-lt-009'; deviceName='OAKF-LT-009'; lastSyncDateTime='2026-02-20T09:00:00Z'
        usersLoggedOn=@( @{userId='u-y12-01';lastLogOnDateTime='2026-02-20T08:50:00Z'}, @{userId='u-y12-02';lastLogOnDateTime='2026-02-18T15:00:00Z'} ) },
    [PSCustomObject]@{ id='d-lt-010'; deviceName='OAKF-LT-010'; lastSyncDateTime='2025-11-10T10:00:00Z'
        usersLoggedOn=@( @{userId='u-y12-03';lastLogOnDateTime='2025-11-10T09:45:00Z'}, @{userId='u-y12-04';lastLogOnDateTime='2025-11-08T13:00:00Z'} ) },
    [PSCustomObject]@{ id='d-sp-001'; deviceName='OAKF-SP-001'; lastSyncDateTime='2026-05-13T07:30:00Z'
        usersLoggedOn=@( @{userId='u-st-01';lastLogOnDateTime='2026-05-13T07:20:00Z'}, @{userId='u-y12-05';lastLogOnDateTime='2026-05-12T16:00:00Z'} ) },
    [PSCustomObject]@{ id='d-sp-002'; deviceName='OAKF-SP-002'; lastSyncDateTime='2026-05-12T15:00:00Z'
        usersLoggedOn=@( @{userId='u-st-02';lastLogOnDateTime='2026-05-12T14:50:00Z'}, @{userId='u-y12-06';lastLogOnDateTime='2026-05-11T10:30:00Z'} ) },
    [PSCustomObject]@{ id='d-sp-003'; deviceName='OAKF-SP-003'; lastSyncDateTime='2026-05-11T11:00:00Z'
        usersLoggedOn=@( @{userId='u-st-03';lastLogOnDateTime='2026-05-11T10:45:00Z'}, @{userId='u-y11-07';lastLogOnDateTime='2026-05-09T14:00:00Z'} ) },
    [PSCustomObject]@{ id='d-sp-004'; deviceName='OAKF-SP-004'; lastSyncDateTime='2026-04-01T08:00:00Z'
        usersLoggedOn=@( @{userId='u-st-04';lastLogOnDateTime='2026-04-01T07:55:00Z'}, @{userId='u-y11-08';lastLogOnDateTime='2026-03-31T16:30:00Z'} ) },
    [PSCustomObject]@{ id='d-sp-005'; deviceName='OAKF-SP-005'; lastSyncDateTime='2026-05-13T08:45:00Z'
        usersLoggedOn=@( @{userId='u-st-05';lastLogOnDateTime='2026-05-13T08:40:00Z'}, @{userId='u-y12-07';lastLogOnDateTime='2026-05-12T12:00:00Z'} ) },
    [PSCustomObject]@{ id='d-sp-006'; deviceName='OAKF-SP-006'; lastSyncDateTime='2026-03-01T09:00:00Z'
        usersLoggedOn=@( @{userId='u-st-06';lastLogOnDateTime='2026-03-01T08:55:00Z'}, @{userId='u-y10-11';lastLogOnDateTime='2026-02-28T15:00:00Z'} ) },
    [PSCustomObject]@{ id='d-sp-007'; deviceName='OAKF-SP-007'; lastSyncDateTime='2026-05-12T13:00:00Z'
        usersLoggedOn=@( @{userId='u-st-07';lastLogOnDateTime='2026-05-12T12:55:00Z'}, @{userId='u-y12-08';lastLogOnDateTime='2026-05-11T09:00:00Z'} ) },
    [PSCustomObject]@{ id='d-sp-008'; deviceName='OAKF-SP-008'; lastSyncDateTime='2026-05-09T10:00:00Z'
        usersLoggedOn=@( @{userId='u-st-08';lastLogOnDateTime='2026-05-09T09:50:00Z'}, @{userId='u-y11-09';lastLogOnDateTime='2026-05-08T14:00:00Z'} ) },
    [PSCustomObject]@{ id='d-cb-001'; deviceName='OAKF-CB-001'; lastSyncDateTime='2026-05-10T08:00:00Z'
        usersLoggedOn=@( @{userId='u-y10-12';lastLogOnDateTime='2026-05-10T07:50:00Z'} ) },
    [PSCustomObject]@{ id='d-cb-002'; deviceName='OAKF-CB-002'; lastSyncDateTime='2026-05-07T09:30:00Z'
        usersLoggedOn=@( @{userId='u-y10-13';lastLogOnDateTime='2026-05-07T09:20:00Z'} ) },
    [PSCustomObject]@{ id='d-cb-003'; deviceName='OAKF-CB-003'; lastSyncDateTime='2026-04-28T08:15:00Z'
        usersLoggedOn=@( @{userId='u-y10-14';lastLogOnDateTime='2026-04-28T08:05:00Z'} ) },
    [PSCustomObject]@{ id='d-cb-004'; deviceName='OAKF-CB-004'; lastSyncDateTime='2025-12-15T10:00:00Z'
        usersLoggedOn=@( @{userId='u-y10-15';lastLogOnDateTime='2025-12-15T09:45:00Z'} ) },
    [PSCustomObject]@{ id='d-cb-005'; deviceName='OAKF-CB-005'; lastSyncDateTime='2026-05-05T11:00:00Z'
        usersLoggedOn=@( @{userId='u-y11-10';lastLogOnDateTime='2026-05-05T10:50:00Z'} ) },
    [PSCustomObject]@{ id='d-cb-006'; deviceName='OAKF-CB-006'; lastSyncDateTime='2026-01-08T09:00:00Z'
        usersLoggedOn=@( @{userId='u-y11-11';lastLogOnDateTime='2026-01-08T08:55:00Z'} ) },
    [PSCustomObject]@{ id='d-cb-007'; deviceName='OAKF-CB-007'; lastSyncDateTime=$null
        usersLoggedOn=@() }
)

# ── Fake groups ────────────────────────────────────────────────────────────────
$Script:Demo_Groups = @(
    [PSCustomObject]@{ displayName='All Students';      '@odata.type'='#microsoft.graph.group' },
    [PSCustomObject]@{ displayName='All Staff';         '@odata.type'='#microsoft.graph.group' },
    [PSCustomObject]@{ displayName='Year 10';           '@odata.type'='#microsoft.graph.group' },
    [PSCustomObject]@{ displayName='Year 11';           '@odata.type'='#microsoft.graph.group' },
    [PSCustomObject]@{ displayName='Year 12';           '@odata.type'='#microsoft.graph.group' },
    [PSCustomObject]@{ displayName='Office 365 A3';     '@odata.type'='#microsoft.graph.group' },
    [PSCustomObject]@{ displayName='MFA Enabled';       '@odata.type'='#microsoft.graph.group' },
    [PSCustomObject]@{ displayName='Intune Users';      '@odata.type'='#microsoft.graph.group' },
    [PSCustomObject]@{ displayName='Global Users';      '@odata.type'='#microsoft.graph.directoryRole' }
)

# ── Sign-in log generator ──────────────────────────────────────────────────────
function New-DemoSignInLogs {
    param([string]$UserId)

    $apps = @(
        'Microsoft Teams', 'Microsoft SharePoint', 'Microsoft Outlook',
        'Azure Portal', 'Microsoft OneDrive', 'Office 365 Portal',
        'Microsoft Exchange Online', 'Microsoft Forms', 'Microsoft Stream',
        'Microsoft Whiteboard'
    )
    $locations = @(
        'London, United Kingdom', 'Manchester, United Kingdom',
        'Birmingham, United Kingdom', 'Bristol, United Kingdom'
    )

    $devNames = @($Script:Demo_Devices |
        Where-Object { $_.usersLoggedOn | Where-Object { $_.userId -eq $UserId } } |
        ForEach-Object { $_.deviceName })
    if ($devNames.Count -eq 0) { $devNames = @('Unknown') }

    $greenBrush = [System.Windows.Media.SolidColorBrush]::new(
        [System.Windows.Media.Color]::FromRgb(0x22, 0xC5, 0x5E))
    $redBrush   = [System.Windows.Media.SolidColorBrush]::new(
        [System.Windows.Media.Color]::FromRgb(0xEF, 0x44, 0x44))
    $greenBrush.Freeze(); $redBrush.Freeze()

    $base = [datetime]::new(2026, 5, 13, 8, 0, 0)
    $seed = [System.Math]::Abs($UserId.GetHashCode())
    $rows = [System.Collections.Generic.List[PSObject]]::new()

    for ($i = 0; $i -lt 50; $i++) {
        $appIdx  = ($seed + $i * 3)  % $apps.Count
        $locIdx  = ($seed + $i)      % $locations.Count
        $devIdx  = $i                % $devNames.Count
        $isFail  = (($seed + $i * 7) % 100) -lt 15

        $rows.Add([PSCustomObject]@{
            DateTime    = $base.AddHours(-($i * 3 + ($seed % 7))).ToString('yyyy-MM-dd HH:mm')
            Application = $apps[$appIdx]
            Result      = if ($isFail) { 'Failure (50126)' } else { 'Success' }
            ResultColor = if ($isFail) { $redBrush } else { $greenBrush }
            IpAddress   = "85.213.$(($seed + $i) % 100 + 100).$(($seed + $i * 3) % 200 + 20)"
            Location    = $locations[$locIdx]
            Device      = $devNames[$devIdx]
        })
    }
    [object[]]$rows
}

function Get-DemoGroupsForUser {
    param([string]$UserId)
    $user = $Script:Demo_Users | Where-Object { $_.id -eq $UserId } | Select-Object -First 1
    if (-not $user) { return @() }

    $dept = $user.department
    if ($dept -eq 'Staff') {
        return @($Script:Demo_Groups | Where-Object { $_.displayName -in @('All Staff','Office 365 A3','MFA Enabled','Global Users') })
    }
    $year = if ($dept -match '^10') { 'Year 10' } elseif ($dept -match '^11') { 'Year 11' } else { 'Year 12' }
    return @($Script:Demo_Groups | Where-Object { $_.displayName -in @('All Students',$year,'Office 365 A3','MFA Enabled','Intune Users') })
}

# ── Year Group Passwords demo loader ───────────────────────────────────────────
function Start-PwUserLoadDemo {
    $Script:PwReset_GraphUsers = @($Script:Demo_Users | Where-Object { $_.accountEnabled -and $_.department })

    $allGroups     = $Script:PwReset_GraphUsers | ForEach-Object { Get-DeptGroup $_.department } |
                     Where-Object { $_ -ne $null } | Sort-Object -Unique
    $numericGroups = @($allGroups | Where-Object { $_ -is [int] }    | Sort-Object)
    $namedGroups   = @($allGroups | Where-Object { $_ -is [string] } | Sort-Object)

    $Script:PwReset_UI.CboYear.Items.Clear()
    foreach ($g in ($numericGroups + $namedGroups)) {
        $cnt   = ($Script:PwReset_GraphUsers | Where-Object { (Get-DeptGroup $_.department) -eq $g }).Count
        $label = if ($g -is [int]) { "Year $g  -  $cnt students" } else { "$g  -  $cnt students" }
        $item  = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $label
        $item.Tag     = $g
        $Script:PwReset_UI.CboYear.Items.Add($item) | Out-Null
    }
    if ($Script:PwReset_UI.CboYear.Items.Count -gt 0) { $Script:PwReset_UI.CboYear.SelectedIndex = 0 }
    $Script:PwReset_UI.CboYear.IsEnabled = $true
    $Script:PwReset_UI.BtnLoad.IsEnabled = $true

    $n = $Script:PwReset_GraphUsers.Count
    Write-Log "Demo: PwReset loaded $n users" 'INFO'
    Write-PwLog "Loaded $n users (demo — Oakfield Academy)." '#22C55E'
    Set-MainStatus "Demo — $n users loaded." '#22C55E'
}

# ── Last Device demo loaders ───────────────────────────────────────────────────
function Start-LdUserLoadDemo {
    $Script:LD_AllUsers = @($Script:Demo_Users | Sort-Object { $_.displayName })
    Update-LdUserFilter
    $Script:LD_UI.UserSearch.IsEnabled = $true
    $Script:LD_UI.UserList.IsEnabled   = $true
    $n = $Script:LD_AllUsers.Count
    Write-Log "Demo: LastDevice loaded $n users" 'INFO'
    Write-LdLog "Loaded $n users (demo — Oakfield Academy)." '#22C55E'
    Set-MainStatus "Demo — $n users loaded." '#22C55E'
}

function Start-LdAllDevicesLoadDemo {
    $Script:LD_AllDevices = @($Script:Demo_Devices | Sort-Object { $_.deviceName })
    Write-Log "Demo: LastDevice loaded $($Script:LD_AllDevices.Count) devices" 'INFO'
    Write-LdLog "By Device: loaded $($Script:LD_AllDevices.Count) devices (demo)." '#22C55E'
    Update-LdDevBrowserFilter
    Update-LdStaleFilter
    $Script:LD_UI.DevBrowserSearch.IsEnabled = $true
    $Script:LD_UI.DevBrowserList.IsEnabled   = $true
}

function Start-LdDeviceLoadDemo {
    param([string]$UserId)

    $Script:LD_UI.DevList.Items.Clear()
    $Script:LD_UI.DevList.Visibility        = 'Collapsed'
    $Script:LD_UI.DevPlaceholder.Text       = 'Loading devices...'
    $Script:LD_UI.DevPlaceholder.Visibility = 'Visible'
    $Script:LD_UI.BtnCopy.IsEnabled         = $false

    $devices = @($Script:Demo_Devices | Where-Object {
        $_.usersLoggedOn | Where-Object { $_.userId -eq $UserId }
    } | Sort-Object {
        $entry = $_.usersLoggedOn | Where-Object { $_.userId -eq $UserId } | Select-Object -First 1
        if ($entry -and $entry.lastLogOnDateTime) { [datetime]$entry.lastLogOnDateTime }
        else { [datetime]::MinValue }
    } -Descending)

    if ($devices.Count -eq 0) {
        $Script:LD_UI.DevPlaceholder.Text       = 'No devices found for this user.'
        $Script:LD_UI.DevPlaceholder.Visibility = 'Visible'
        $Script:LD_UI.DevList.Visibility        = 'Collapsed'
        Set-MainStatus 'No devices found.' '#7878A0'
        return
    }

    foreach ($d in $devices) {
        $lbi         = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Content = $d.deviceName
        $lbi.Tag     = $d
        $entry = $d.usersLoggedOn | Where-Object { $_.userId -eq $UserId } | Select-Object -First 1
        if ($entry -and $entry.lastLogOnDateTime) {
            $lbi.ToolTip = "Last check-in: $([datetime]$entry.lastLogOnDateTime)"
        }
        [void]$Script:LD_UI.DevList.Items.Add($lbi)
    }
    $Script:LD_UI.DevPlaceholder.Visibility = 'Collapsed'
    $Script:LD_UI.DevList.Visibility        = 'Visible'
    Set-MainStatus "Loaded $($devices.Count) device$(if ($devices.Count -ne 1) { 's' })." '#22C55E'
}

# ── Sign-In Logs demo loaders ──────────────────────────────────────────────────
function Start-SlUserLoadDemo {
    $Script:SL_AllUsers = @($Script:Demo_Users | Sort-Object { $_.displayName })
    Update-SlUserFilter
    $Script:SL_UI.UserSearch.IsEnabled = $true
    $Script:SL_UI.UserList.IsEnabled   = $true
    $n = $Script:SL_AllUsers.Count
    Write-Log "Demo: SignInLogs loaded $n users" 'INFO'
    Write-SlLog "Loaded $n users (demo — Oakfield Academy)." '#22C55E'
    Set-MainStatus "Demo — $n users loaded." '#22C55E'
}

function Start-SlLogsLoadDemo {
    param([string]$UserId)

    $Script:SL_UI.LogsGrid.Visibility        = 'Collapsed'
    $Script:SL_UI.LogsPlaceholder.Text       = 'Loading sign-in logs...'
    $Script:SL_UI.LogsPlaceholder.Visibility = 'Visible'

    $rows = New-DemoSignInLogs -UserId $UserId
    $Script:SL_UI.LogsGrid.ItemsSource       = $rows
    $Script:SL_UI.LogsPlaceholder.Visibility = 'Collapsed'
    $Script:SL_UI.LogsGrid.Visibility        = 'Visible'
    $n = $rows.Count
    Write-SlLog "Loaded $n sign-in records (demo)." '#22C55E'
    Set-MainStatus "Sign-in logs loaded ($n records)." '#22C55E'
}

# ── User Password Reset demo loaders ──────────────────────────────────────────
function Start-UprUserLoadDemo {
    $Script:UPR_AllUsers = @($Script:Demo_Users | Sort-Object { $_.displayName })
    Update-UprUserFilter
    $Script:UPR_UI.UserSearch.IsEnabled = $true
    $Script:UPR_UI.UserList.IsEnabled   = $true
    $n = $Script:UPR_AllUsers.Count
    Write-Log "Demo: UPR loaded $n users" 'INFO'
    Write-UprLog "Loaded $n users (demo — Oakfield Academy)." '#22C55E'
    Set-MainStatus "Demo — $n users loaded." '#22C55E'
}

function Start-UprProfileLoadDemo {
    $Script:UPR_UI.PromptStatus.Text       = 'Currently: no prompt required'
    $Script:UPR_UI.PromptStatus.Foreground = '#22C55E'
    $Script:UPR_UI.BtnReset.IsEnabled      = $true
}

function Start-UprGroupLoadDemo {
    param([string]$UserId)

    $Script:UPR_AllGroups = @()
    $Script:UPR_UI.GrpList.Items.Clear()
    $Script:UPR_UI.GrpList.Visibility        = 'Collapsed'
    $Script:UPR_UI.GrpSearch.Visibility      = 'Collapsed'
    $Script:UPR_UI.GrpSearch.Text            = ''
    $Script:UPR_UI.GrpPlaceholder.Visibility = 'Visible'

    $groups = @(Get-DemoGroupsForUser -UserId $UserId | Sort-Object { $_.displayName })
    $Script:UPR_AllGroups = $groups
    $n = $groups.Count

    if ($n -eq 0) {
        $Script:UPR_UI.GrpPlaceholder.Text = 'No group memberships found.'
        return
    }

    $Script:UPR_UI.GrpHeader.Text            = "$n group membership$(if ($n -ne 1) { 's' })"
    $Script:UPR_UI.GrpPlaceholder.Visibility = 'Collapsed'
    $Script:UPR_UI.GrpSearch.Visibility      = 'Visible'
    Update-UprGroupFilter
    $Script:UPR_UI.GrpList.Visibility = 'Visible'
}
