<#
    Demo/showcase mode for Art's Entra Toolbox.
    Dot-sourced by Start.ps1 after Auth.ps1.
    Provides a fake Contoso Academy tenant so the app can be demonstrated
    without connecting to a real tenant or exposing any real data.
#>

$Script:DemoMode = $false

# ── Fake users ─────────────────────────────────────────────────────────────────
$Script:Demo_Users = @(
    # Year 10
    [PSCustomObject]@{ id='u-y10-01'; displayName='Amara Osei';         userPrincipalName='amara.osei@contoso.sch.uk';         department='10A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-02'; displayName='Callum Reid';        userPrincipalName='callum.reid@contoso.sch.uk';        department='10A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-03'; displayName='Priya Sharma';       userPrincipalName='priya.sharma@contoso.sch.uk';       department='10B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-04'; displayName='Jake Morrison';      userPrincipalName='jake.morrison@contoso.sch.uk';      department='10B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-05'; displayName='Sophie Chen';        userPrincipalName='sophie.chen@contoso.sch.uk';        department='10B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-06'; displayName='Liam Walsh';         userPrincipalName='liam.walsh@contoso.sch.uk';         department='10C'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-07'; displayName='Fatima Al-Hassan';   userPrincipalName='fatima.alhassan@contoso.sch.uk';    department='10C'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-08'; displayName='Noah Clarke';        userPrincipalName='noah.clarke@contoso.sch.uk';        department='10A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-09'; displayName='Aisha Patel';        userPrincipalName='aisha.patel@contoso.sch.uk';        department='10B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-10'; displayName='Dylan Roberts';      userPrincipalName='dylan.roberts@contoso.sch.uk';      department='10C'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-11'; displayName='Mia Thompson';       userPrincipalName='mia.thompson@contoso.sch.uk';       department='10A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-12'; displayName='Aaron Khan';         userPrincipalName='aaron.khan@contoso.sch.uk';         department='10C'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-13'; displayName='Emma Wilson';        userPrincipalName='emma.wilson@contoso.sch.uk';        department='10B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-14'; displayName='Joshua Okafor';      userPrincipalName='joshua.okafor@contoso.sch.uk';      department='10A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y10-15'; displayName='Isabelle Martin';    userPrincipalName='isabelle.martin@contoso.sch.uk';    department='10C'; accountEnabled=$true },
    # Year 11
    [PSCustomObject]@{ id='u-y11-01'; displayName='Tyler Hughes';       userPrincipalName='tyler.hughes@contoso.sch.uk';       department='11A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-02'; displayName='Zara Ahmed';         userPrincipalName='zara.ahmed@contoso.sch.uk';         department='11B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-03'; displayName='Connor Burke';       userPrincipalName='connor.burke@contoso.sch.uk';       department='11A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-04'; displayName='Leila Naseri';       userPrincipalName='leila.naseri@contoso.sch.uk';       department='11B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-05'; displayName='Marcus Johnson';     userPrincipalName='marcus.johnson@contoso.sch.uk';     department='11C'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-06'; displayName='Hannah Lee';         userPrincipalName='hannah.lee@contoso.sch.uk';         department='11A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-07'; displayName='Ethan Nguyen';       userPrincipalName='ethan.nguyen@contoso.sch.uk';       department='11C'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-08'; displayName='Chloe Dubois';       userPrincipalName='chloe.dubois@contoso.sch.uk';       department='11B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-09'; displayName='Ryan Cooper';        userPrincipalName='ryan.cooper@contoso.sch.uk';        department='11A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-10'; displayName='Nadia Kowalski';     userPrincipalName='nadia.kowalski@contoso.sch.uk';     department='11C'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-11'; displayName='Samuel Osei';        userPrincipalName='samuel.osei@contoso.sch.uk';        department='11B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-12'; displayName='Bethany Ellis';      userPrincipalName='bethany.ellis@contoso.sch.uk';      department='11A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-13'; displayName='Kieran Murphy';      userPrincipalName='kieran.murphy@contoso.sch.uk';      department='11C'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-14'; displayName='Anaya Singh';        userPrincipalName='anaya.singh@contoso.sch.uk';        department='11B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y11-15'; displayName='Leo Fernandez';      userPrincipalName='leo.fernandez@contoso.sch.uk';      department='11A'; accountEnabled=$true },
    # Year 12
    [PSCustomObject]@{ id='u-y12-01'; displayName='Olivia Bennett';     userPrincipalName='olivia.bennett@contoso.sch.uk';     department='12A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y12-02'; displayName='James Carter';       userPrincipalName='james.carter@contoso.sch.uk';       department='12A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y12-03'; displayName='Maya Ramachandran';  userPrincipalName='maya.ramachandran@contoso.sch.uk';  department='12B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y12-04'; displayName='William Scott';      userPrincipalName='william.scott@contoso.sch.uk';      department='12B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y12-05'; displayName='Aria Delgado';       userPrincipalName='aria.delgado@contoso.sch.uk';       department='12A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y12-06'; displayName='Daniel Park';        userPrincipalName='daniel.park@contoso.sch.uk';        department='12B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y12-07'; displayName='Freya Johansson';    userPrincipalName='freya.johansson@contoso.sch.uk';    department='12A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y12-08'; displayName='Alex Mitchell';      userPrincipalName='alex.mitchell@contoso.sch.uk';      department='12B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y12-09'; displayName='Serena Ibrahim';     userPrincipalName='serena.ibrahim@contoso.sch.uk';     department='12A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y12-10'; displayName='Luke Petrov';        userPrincipalName='luke.petrov@contoso.sch.uk';        department='12B'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y12-11'; displayName='Imogen Taylor';      userPrincipalName='imogen.taylor@contoso.sch.uk';      department='12A'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-y12-12'; displayName='Ravi Krishnamurthy'; userPrincipalName='ravi.krishnamurthy@contoso.sch.uk'; department='12B'; accountEnabled=$true },
    # Staff
    [PSCustomObject]@{ id='u-st-01'; displayName='Michael Graves';      userPrincipalName='m.graves@contoso.sch.uk';           department='Staff'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-st-02'; displayName='Sarah Nkosi';         userPrincipalName='s.nkosi@contoso.sch.uk';            department='Staff'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-st-03'; displayName='Tom Lawson';          userPrincipalName='t.lawson@contoso.sch.uk';           department='Staff'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-st-04'; displayName='Claire Atkins';       userPrincipalName='c.atkins@contoso.sch.uk';           department='Staff'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-st-05'; displayName='Paul Yeboah';         userPrincipalName='p.yeboah@contoso.sch.uk';           department='Staff'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-st-06'; displayName='Helen Marsh';         userPrincipalName='h.marsh@contoso.sch.uk';            department='Staff'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-st-07'; displayName='James Obrien';        userPrincipalName='j.obrien@contoso.sch.uk';           department='Staff'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-st-08'; displayName='Priya Mehta';         userPrincipalName='p.mehta@contoso.sch.uk';            department='Staff'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-st-09'; displayName='Dave Fowler';         userPrincipalName='d.fowler@contoso.sch.uk';           department='Staff'; accountEnabled=$true },
    [PSCustomObject]@{ id='u-st-10'; displayName='Rachel Green';        userPrincipalName='r.green@contoso.sch.uk';            department='Staff'; accountEnabled=$true }
)

# ── Fake devices ───────────────────────────────────────────────────────────────
# lastSyncDateTime strings are UTC (relative to 2026-05-13)
$Script:Demo_Devices = @(
    [PSCustomObject]@{ id='d-lt-001'; deviceName='CTX-LT-001'; model='Dell Latitude 5520'; serialNumber='SLT0001'; complianceState='compliant';    lastSyncDateTime='2026-05-12T09:14:00Z'
        usersLoggedOn=@( @{userId='u-y10-01';lastLogOnDateTime='2026-05-12T08:55:00Z'}, @{userId='u-y10-02';lastLogOnDateTime='2026-05-10T13:22:00Z'} ) },
    [PSCustomObject]@{ id='d-lt-002'; deviceName='CTX-LT-002'; model='Dell Latitude 5520'; serialNumber='SLT0002'; complianceState='compliant';    lastSyncDateTime='2026-05-10T11:30:00Z'
        usersLoggedOn=@( @{userId='u-y10-03';lastLogOnDateTime='2026-05-10T11:00:00Z'}, @{userId='u-y10-04';lastLogOnDateTime='2026-05-09T14:10:00Z'} ) },
    [PSCustomObject]@{ id='d-lt-003'; deviceName='CTX-LT-003'; model='Dell Latitude 5520'; serialNumber='SLT0003'; complianceState='compliant';    lastSyncDateTime='2026-05-08T08:00:00Z'
        usersLoggedOn=@( @{userId='u-y10-05';lastLogOnDateTime='2026-05-08T07:45:00Z'}, @{userId='u-y10-06';lastLogOnDateTime='2026-05-07T15:30:00Z'} ) },
    [PSCustomObject]@{ id='d-lt-004'; deviceName='CTX-LT-004'; model='Dell Latitude 5520'; serialNumber='SLT0004'; complianceState='noncompliant'; lastSyncDateTime='2026-04-25T14:00:00Z'
        usersLoggedOn=@( @{userId='u-y10-07';lastLogOnDateTime='2026-04-25T13:50:00Z'}, @{userId='u-y10-08';lastLogOnDateTime='2026-04-24T09:20:00Z'} ) },
    [PSCustomObject]@{ id='d-lt-005'; deviceName='CTX-LT-005'; model='Dell Latitude 5520'; serialNumber='SLT0005'; complianceState='compliant';    lastSyncDateTime='2026-04-20T10:45:00Z'
        usersLoggedOn=@( @{userId='u-y10-09';lastLogOnDateTime='2026-04-20T10:30:00Z'}, @{userId='u-y10-10';lastLogOnDateTime='2026-04-18T12:00:00Z'} ) },
    [PSCustomObject]@{ id='d-lt-006'; deviceName='CTX-LT-006'; model='Dell Latitude 5520'; serialNumber='SLT0006'; complianceState='compliant';    lastSyncDateTime='2026-05-02T09:00:00Z'
        usersLoggedOn=@( @{userId='u-y11-01';lastLogOnDateTime='2026-05-02T08:45:00Z'}, @{userId='u-y11-02';lastLogOnDateTime='2026-04-30T16:00:00Z'} ) },
    [PSCustomObject]@{ id='d-lt-007'; deviceName='CTX-LT-007'; model='Dell Latitude 5520'; serialNumber='SLT0007'; complianceState='noncompliant'; lastSyncDateTime='2026-03-30T08:30:00Z'
        usersLoggedOn=@( @{userId='u-y11-03';lastLogOnDateTime='2026-03-30T08:20:00Z'}, @{userId='u-y11-04';lastLogOnDateTime='2026-03-28T14:15:00Z'} ) },
    [PSCustomObject]@{ id='d-lt-008'; deviceName='CTX-LT-008'; model='Dell Latitude 5520'; serialNumber='SLT0008'; complianceState='compliant';    lastSyncDateTime='2026-03-15T12:00:00Z'
        usersLoggedOn=@( @{userId='u-y11-05';lastLogOnDateTime='2026-03-15T11:50:00Z'}, @{userId='u-y11-06';lastLogOnDateTime='2026-03-14T09:30:00Z'} ) },
    [PSCustomObject]@{ id='d-lt-009'; deviceName='CTX-LT-009'; model='Dell Latitude 5520'; serialNumber='SLT0009'; complianceState='noncompliant'; lastSyncDateTime='2026-02-20T09:00:00Z'
        usersLoggedOn=@( @{userId='u-y12-01';lastLogOnDateTime='2026-02-20T08:50:00Z'}, @{userId='u-y12-02';lastLogOnDateTime='2026-02-18T15:00:00Z'} ) },
    [PSCustomObject]@{ id='d-lt-010'; deviceName='CTX-LT-010'; model='Dell Latitude 5520'; serialNumber='SLT0010'; complianceState='noncompliant'; lastSyncDateTime='2025-11-10T10:00:00Z'
        usersLoggedOn=@( @{userId='u-y12-03';lastLogOnDateTime='2025-11-10T09:45:00Z'}, @{userId='u-y12-04';lastLogOnDateTime='2025-11-08T13:00:00Z'} ) },
    [PSCustomObject]@{ id='d-sp-001'; deviceName='CTX-SP-001'; model='Surface Pro 7'; serialNumber='SSP0001'; complianceState='compliant';    lastSyncDateTime='2026-05-13T07:30:00Z'
        usersLoggedOn=@( @{userId='u-st-01';lastLogOnDateTime='2026-05-13T07:20:00Z'}, @{userId='u-y12-05';lastLogOnDateTime='2026-05-12T16:00:00Z'} ) },
    [PSCustomObject]@{ id='d-sp-002'; deviceName='CTX-SP-002'; model='Surface Pro 7'; serialNumber='SSP0002'; complianceState='compliant';    lastSyncDateTime='2026-05-12T15:00:00Z'
        usersLoggedOn=@( @{userId='u-st-02';lastLogOnDateTime='2026-05-12T14:50:00Z'}, @{userId='u-y12-06';lastLogOnDateTime='2026-05-11T10:30:00Z'} ) },
    [PSCustomObject]@{ id='d-sp-003'; deviceName='CTX-SP-003'; model='Surface Pro 7'; serialNumber='SSP0003'; complianceState='compliant';    lastSyncDateTime='2026-05-11T11:00:00Z'
        usersLoggedOn=@( @{userId='u-st-03';lastLogOnDateTime='2026-05-11T10:45:00Z'}, @{userId='u-y11-07';lastLogOnDateTime='2026-05-09T14:00:00Z'} ) },
    [PSCustomObject]@{ id='d-sp-004'; deviceName='CTX-SP-004'; model='Surface Pro 7'; serialNumber='SSP0004'; complianceState='noncompliant'; lastSyncDateTime='2026-04-01T08:00:00Z'
        usersLoggedOn=@( @{userId='u-st-04';lastLogOnDateTime='2026-04-01T07:55:00Z'}, @{userId='u-y11-08';lastLogOnDateTime='2026-03-31T16:30:00Z'} ) },
    [PSCustomObject]@{ id='d-sp-005'; deviceName='CTX-SP-005'; model='Surface Pro 7'; serialNumber='SSP0005'; complianceState='compliant';    lastSyncDateTime='2026-05-13T08:45:00Z'
        usersLoggedOn=@( @{userId='u-st-05';lastLogOnDateTime='2026-05-13T08:40:00Z'}, @{userId='u-y12-07';lastLogOnDateTime='2026-05-12T12:00:00Z'} ) },
    [PSCustomObject]@{ id='d-sp-006'; deviceName='CTX-SP-006'; model='Surface Pro 7'; serialNumber='SSP0006'; complianceState='noncompliant'; lastSyncDateTime='2026-03-01T09:00:00Z'
        usersLoggedOn=@( @{userId='u-st-06';lastLogOnDateTime='2026-03-01T08:55:00Z'}, @{userId='u-y10-11';lastLogOnDateTime='2026-02-28T15:00:00Z'} ) },
    [PSCustomObject]@{ id='d-sp-007'; deviceName='CTX-SP-007'; model='Surface Pro 7'; serialNumber='SSP0007'; complianceState='compliant';    lastSyncDateTime='2026-05-12T13:00:00Z'
        usersLoggedOn=@( @{userId='u-st-07';lastLogOnDateTime='2026-05-12T12:55:00Z'}, @{userId='u-y12-08';lastLogOnDateTime='2026-05-11T09:00:00Z'} ) },
    [PSCustomObject]@{ id='d-sp-008'; deviceName='CTX-SP-008'; model='Surface Pro 7'; serialNumber='SSP0008'; complianceState='compliant';    lastSyncDateTime='2026-05-09T10:00:00Z'
        usersLoggedOn=@( @{userId='u-st-08';lastLogOnDateTime='2026-05-09T09:50:00Z'}, @{userId='u-y11-09';lastLogOnDateTime='2026-05-08T14:00:00Z'} ) },
    [PSCustomObject]@{ id='d-cb-001'; deviceName='CTX-CB-001'; model='HP Chromebook 14'; serialNumber='SCB0001'; complianceState='compliant';    lastSyncDateTime='2026-05-10T08:00:00Z'
        usersLoggedOn=@( @{userId='u-y10-12';lastLogOnDateTime='2026-05-10T07:50:00Z'} ) },
    [PSCustomObject]@{ id='d-cb-002'; deviceName='CTX-CB-002'; model='HP Chromebook 14'; serialNumber='SCB0002'; complianceState='compliant';    lastSyncDateTime='2026-05-07T09:30:00Z'
        usersLoggedOn=@( @{userId='u-y10-13';lastLogOnDateTime='2026-05-07T09:20:00Z'} ) },
    [PSCustomObject]@{ id='d-cb-003'; deviceName='CTX-CB-003'; model='HP Chromebook 14'; serialNumber='SCB0003'; complianceState='compliant';    lastSyncDateTime='2026-04-28T08:15:00Z'
        usersLoggedOn=@( @{userId='u-y10-14';lastLogOnDateTime='2026-04-28T08:05:00Z'} ) },
    [PSCustomObject]@{ id='d-cb-004'; deviceName='CTX-CB-004'; model='HP Chromebook 14'; serialNumber='SCB0004'; complianceState='noncompliant'; lastSyncDateTime='2025-12-15T10:00:00Z'
        usersLoggedOn=@( @{userId='u-y10-15';lastLogOnDateTime='2025-12-15T09:45:00Z'} ) },
    [PSCustomObject]@{ id='d-cb-005'; deviceName='CTX-CB-005'; model='HP Chromebook 14'; serialNumber='SCB0005'; complianceState='compliant';    lastSyncDateTime='2026-05-05T11:00:00Z'
        usersLoggedOn=@( @{userId='u-y11-10';lastLogOnDateTime='2026-05-05T10:50:00Z'} ) },
    [PSCustomObject]@{ id='d-cb-006'; deviceName='CTX-CB-006'; model='HP Chromebook 14'; serialNumber='SCB0006'; complianceState='noncompliant'; lastSyncDateTime='2026-01-08T09:00:00Z'
        usersLoggedOn=@( @{userId='u-y11-11';lastLogOnDateTime='2026-01-08T08:55:00Z'} ) },
    [PSCustomObject]@{ id='d-cb-007'; deviceName='CTX-CB-007'; model='HP Chromebook 14'; serialNumber='SCB0007'; complianceState='unknown';      lastSyncDateTime=$null
        usersLoggedOn=@() }
)

# ── Fake groups ────────────────────────────────────────────────────────────────
$Script:Demo_Groups = @(
    [PSCustomObject]@{ id='g-all-students'; displayName='All Students';      '@odata.type'='#microsoft.graph.group' },
    [PSCustomObject]@{ id='g-all-staff';    displayName='All Staff';         '@odata.type'='#microsoft.graph.group' },
    [PSCustomObject]@{ id='g-year-10';      displayName='Year 10';           '@odata.type'='#microsoft.graph.group' },
    [PSCustomObject]@{ id='g-year-11';      displayName='Year 11';           '@odata.type'='#microsoft.graph.group' },
    [PSCustomObject]@{ id='g-year-12';      displayName='Year 12';           '@odata.type'='#microsoft.graph.group' },
    [PSCustomObject]@{ id='g-o365-a3';      displayName='Office 365 A3';     '@odata.type'='#microsoft.graph.group' },
    [PSCustomObject]@{ id='g-mfa';          displayName='MFA Enabled';       '@odata.type'='#microsoft.graph.group' },
    [PSCustomObject]@{ id='g-intune';       displayName='Intune Users';      '@odata.type'='#microsoft.graph.group' },
    [PSCustomObject]@{ id='g-global';       displayName='Global Users';      '@odata.type'='#microsoft.graph.directoryRole' }
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
        [System.Windows.Media.ColorConverter]::ConvertFromString((Get-ThemeHex 'Success')))
    $redBrush   = [System.Windows.Media.SolidColorBrush]::new(
        [System.Windows.Media.ColorConverter]::ConvertFromString((Get-ThemeHex 'Danger')))
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
    Write-PwLog "Loaded $n users (demo — Contoso Academy)." 'Success'
    Set-MainStatus "Demo — $n users loaded." 'Success'
}

# ── Last Device demo loaders ───────────────────────────────────────────────────
function Start-LdUserLoadDemo {
    $Script:LD_AllUsers = @($Script:Demo_Users | Sort-Object { $_.displayName })
    Update-LdUserFilter
    $Script:LD_UI.UserSearch.IsEnabled = $true
    $Script:LD_UI.UserList.IsEnabled   = $true
    $n = $Script:LD_AllUsers.Count
    Write-Log "Demo: LastDevice loaded $n users" 'INFO'
    Write-LdLog "Loaded $n users (demo — Contoso Academy)." 'Success'
    Set-MainStatus "Demo — $n users loaded." 'Success'
}

function Start-LdAllDevicesLoadDemo {
    $Script:LD_AllDevices = @($Script:Demo_Devices | Sort-Object { $_.deviceName })
    Write-Log "Demo: LastDevice loaded $($Script:LD_AllDevices.Count) devices" 'INFO'
    Write-LdLog "By Device: loaded $($Script:LD_AllDevices.Count) devices (demo)." 'Success'
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
    $Script:LD_UI.BtnSync.IsEnabled         = $false

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
        Set-MainStatus 'No devices found.' 'TextDim'
        return
    }

    foreach ($d in $devices) {
        $lbi     = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Tag = $d

        $panel = [System.Windows.Controls.StackPanel]::new()
        $panel.Orientation = 'Horizontal'

        $dot = [System.Windows.Controls.TextBlock]::new()
        $dot.Text              = '●'
        $dot.FontSize          = 10
        $dot.VerticalAlignment = 'Center'
        $dot.Margin            = [System.Windows.Thickness]::new(0, 0, 6, 0)
        $dotColor = switch ($d.complianceState) {
            'compliant'    { '#22C55E' }
            'noncompliant' { '#EF4444' }
            default        { '#50507A' }
        }
        $dot.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($dotColor)

        $nameText = [System.Windows.Controls.TextBlock]::new()
        $nameText.Text              = $d.deviceName
        $nameText.VerticalAlignment = 'Center'

        [void]$panel.Children.Add($dot)
        [void]$panel.Children.Add($nameText)
        $lbi.Content = $panel

        $entry = $d.usersLoggedOn | Where-Object { $_.userId -eq $UserId } | Select-Object -First 1
        if ($entry -and $entry.lastLogOnDateTime) {
            $lbi.ToolTip = "Last check-in: $([datetime]$entry.lastLogOnDateTime)"
        }
        [void]$Script:LD_UI.DevList.Items.Add($lbi)
    }
    $Script:LD_UI.DevPlaceholder.Visibility = 'Collapsed'
    $Script:LD_UI.DevList.Visibility        = 'Visible'
    Set-MainStatus "Loaded $($devices.Count) device$(if ($devices.Count -ne 1) { 's' })." 'Success'
}

# ── Sign-In Logs demo loaders ──────────────────────────────────────────────────
function Start-SlUserLoadDemo {
    $Script:SL_AllUsers = @($Script:Demo_Users | Sort-Object { $_.displayName })
    Update-SlUserFilter
    $Script:SL_UI.UserSearch.IsEnabled = $true
    $Script:SL_UI.UserList.IsEnabled   = $true
    $n = $Script:SL_AllUsers.Count
    Write-Log "Demo: SignInLogs loaded $n users" 'INFO'
    Write-SlLog "Loaded $n users (demo — Contoso Academy)." 'Success'
    Set-MainStatus "Demo — $n users loaded." 'Success'
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
    Write-SlLog "Loaded $n sign-in records (demo)." 'Success'
    Set-MainStatus "Sign-in logs loaded ($n records)." 'Success'
}

# ── User Password Reset demo loaders ──────────────────────────────────────────
function Start-UprUserLoadDemo {
    $Script:UPR_AllUsers = @($Script:Demo_Users | Sort-Object { $_.displayName })
    Update-UprUserFilter
    $Script:UPR_UI.UserSearch.IsEnabled = $true
    $Script:UPR_UI.UserList.IsEnabled   = $true
    $n = $Script:UPR_AllUsers.Count
    Write-Log "Demo: UPR loaded $n users" 'INFO'
    Write-UprLog "Loaded $n users (demo — Contoso Academy)." 'Success'
    Set-MainStatus "Demo — $n users loaded." 'Success'
}

function Start-UprProfileLoadDemo {
    $Script:UPR_UI.PromptStatus.Text       = 'Currently: no prompt required'
    $Script:UPR_UI.PromptStatus.Foreground = (Get-ThemeHex 'Success')
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

# ── Group Copy demo loaders ────────────────────────────────────────────────────
function Start-GcUserLoadDemo {
    $Script:GC_AllUsers = @($Script:Demo_Users | Sort-Object { $_.displayName })
    Update-GcSrcFilter
    Update-GcTgtFilter
    $Script:GC_UI.SrcSearch.IsEnabled = $true
    $Script:GC_UI.SrcList.IsEnabled   = $true
    $Script:GC_UI.TgtSearch.IsEnabled = $true
    $Script:GC_UI.TgtList.IsEnabled   = $true
    $n = $Script:GC_AllUsers.Count
    Write-Log "Demo: GC loaded $n users" 'INFO'
    Write-GcLog "Loaded $n users (demo — Contoso Academy)." 'Success'
    Set-MainStatus "Demo — $n users loaded." 'Success'
}

function Start-GcSourceGroupLoadDemo {
    param([string]$UserId)

    $Script:GC_SourceGroups = @()
    $Script:GC_UI.GrpList.Items.Clear()
    $Script:GC_UI.GrpList.Visibility        = 'Collapsed'
    $Script:GC_UI.GrpPlaceholder.Visibility = 'Visible'

    $groups = @(Get-DemoGroupsForUser -UserId $UserId |
        Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' } |
        Sort-Object { $_.displayName })
    $Script:GC_SourceGroups = $groups
    $n = $groups.Count

    if ($n -eq 0) {
        $Script:GC_UI.GrpHeader.Text      = 'Source user has no group memberships'
        $Script:GC_UI.GrpPlaceholder.Text = 'No groups to copy.'
        return
    }

    $Script:GC_UI.GrpHeader.Text            = "$n group$(if ($n -ne 1) { 's' }) on source user"
    $Script:GC_UI.GrpPlaceholder.Visibility = 'Collapsed'
    foreach ($g in $groups) {
        $lbi         = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Content = $g.displayName
        $lbi.Tag     = $g
        [void]$Script:GC_UI.GrpList.Items.Add($lbi)
    }
    $Script:GC_UI.GrpList.Visibility = 'Visible'
    Update-GcCopyButton
}

function Start-GcCopyDemo {
    $srcUser   = $Script:GC_SourceUser
    $tgtUser   = $Script:GC_TargetUser
    $srcGroups = $Script:GC_SourceGroups

    $Script:GC_UI.BtnCopy.IsEnabled = $false
    Write-GcLog "Starting (demo): '$($srcUser.displayName)' -> '$($tgtUser.displayName)'" 'TextDim'

    $tgtGroups   = @(Get-DemoGroupsForUser -UserId $tgtUser.id |
        Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' })
    $tgtGroupIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($g in $tgtGroups) { [void]$tgtGroupIds.Add($g.id) }

    $added   = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()

    foreach ($g in $srcGroups) {
        if ($tgtGroupIds.Contains($g.id)) { $skipped.Add($g.displayName) }
        else                              { $added.Add($g.displayName)   }
    }

    foreach ($g in $added)   { Write-GcLog "Added:   $g" 'Success' }
    foreach ($g in $skipped) { Write-GcLog "Skipped: $g (already a member)" 'TextDim' }

    $summary = "Done (demo) — added: $($added.Count)  skipped: $($skipped.Count)  failed: 0"
    Write-GcLog $summary 'Text'
    Set-MainStatus $summary 'Success'
    Write-Log "GC demo: $summary" 'INFO'
    Update-GcCopyButton
}

# ── Teams Provisioning demo loader ─────────────────────────────────────────────
function Start-TpUserLoadDemo {
    $Script:TP_AllUsers = @($Script:Demo_Users | Sort-Object { $_.displayName })

    $allGroups     = $Script:TP_AllUsers | ForEach-Object { Get-DeptGroup $_.department } |
                     Where-Object { $_ -ne $null } | Sort-Object -Unique
    $numericGroups = @($allGroups | Where-Object { $_ -is [int] }    | Sort-Object)
    $namedGroups   = @($allGroups | Where-Object { $_ -is [string] } | Sort-Object)

    $Script:TP_UI.CboYear.Items.Clear()
    foreach ($g in ($numericGroups + $namedGroups)) {
        $cnt   = ($Script:TP_AllUsers | Where-Object { (Get-DeptGroup $_.department) -eq $g }).Count
        $label = if ($g -is [int]) { "Year $g  -  $cnt users" } else { "$g  -  $cnt users" }
        $item  = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $label
        $item.Tag     = $g
        $Script:TP_UI.CboYear.Items.Add($item) | Out-Null
    }
    if ($Script:TP_UI.CboYear.Items.Count -gt 0) { $Script:TP_UI.CboYear.SelectedIndex = 0 }
    $Script:TP_UI.CboYear.IsEnabled = $true
    $Script:TP_UI.BtnLoad.IsEnabled = $true

    $n = $Script:TP_AllUsers.Count
    Write-Log "Demo: TP loaded $n users" 'INFO'
    Write-TpLog "Loaded $n users (demo — Contoso Academy)." 'Success'
    Set-MainStatus "Demo — $n users loaded." 'Success'
}

function Start-TpCreateDemo {
    $Script:TP_Creating                    = $true
    $Script:TP_UI.BtnCreate.IsEnabled      = $false
    $Script:TP_UI.BtnLoad.IsEnabled        = $false
    $Script:TP_UI.BtnSelectAll.IsEnabled   = $false
    $Script:TP_UI.BtnSelectNone.IsEnabled  = $false
    $Script:TP_UI.PnlStats.Visibility      = 'Collapsed'

    $teamName   = $Script:TP_UI.TeamName.Text.Trim()
    $isClass    = $Script:TP_UI.RbClass.IsChecked
    $type       = if ($isClass) { 'Class' } else { 'Standard' }
    $memberSnap = @($Script:TP_Rows | ForEach-Object {
        @{ DisplayName = $_.DisplayName; IsOwner = [bool]$_.IsOwner }
    })

    Write-TpLog "Creating $type team: '$teamName' (demo)" 'TextDim'
    Set-MainStatus "Creating team '$teamName' (demo)..." 'TextDim'

    $demoTimer          = [System.Windows.Threading.DispatcherTimer]::new()
    $demoTimer.Interval = [TimeSpan]::FromSeconds(3)
    $demoTimer.Add_Tick({
        try {
            $demoTimer.Stop()
            $fakeId = Get-Random -Maximum 99999
            Write-TpLog "Team '$teamName' created (demo). ID: demo-team-$fakeId" 'TextDim'
            foreach ($m in $memberSnap) {
                $role = if ($m.IsOwner) { 'Owner' } else { 'Member' }
                Write-TpLog "Added: $($m.DisplayName)  [$role]" 'Success'
            }
            $ok = $memberSnap.Count
            Write-TpLog "Done (demo) — $ok members added, 0 failed." 'Success'
            Set-MainStatus "Team created (demo): $ok members added." 'Success'

            $Script:TP_Creating                        = $false
            $Script:TP_UI.LblTeamStatus.Text           = 'Team   Created'
            $Script:TP_UI.LblTeamStatus.Foreground     = (Get-ThemeHex 'Success')
            $Script:TP_UI.LblAdded.Text                = "Added  $ok"
            $Script:TP_UI.LblFailed.Text               = 'Failed 0'
            $Script:TP_UI.LblFailed.Foreground         = (Get-ThemeHex 'TextDim')
            $Script:TP_UI.PnlStats.Visibility          = 'Visible'
            $Script:TP_UI.BtnLoad.IsEnabled            = $true
            $Script:TP_UI.BtnSelectAll.IsEnabled       = $true
            $Script:TP_UI.BtnSelectNone.IsEnabled      = $true
            Update-TpCreateButton
        } catch { Write-Log "TP demo timer error: $_" 'ERROR' }
    })
    $demoTimer.Start()
}
