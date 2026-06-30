<#
    Last Device tab for Art's Entra Toolbox.
    Shows a searchable user list; selecting a user shows their Intune-managed devices.
    Dot-sourced by Start.ps1.
    Exposes Initialize-LastDeviceTool.

    Device lookup strategy: Intune OData does not support lambda filters on usersLoggedOn,
    so all devices are paged client-side and matched on usersLoggedOn[].userId.
#>

# ── Script-level state ─────────────────────────────────────────────────────────
$Script:LD_UI          = $null
$Script:LD_AllUsers    = @()
$Script:LD_UserTimer   = $null
$Script:LD_DevTimer    = $null
$Script:LD_AllDevices  = @()
$Script:LD_AllDevTimer = $null

# ── Log helper ─────────────────────────────────────────────────────────────────
function Write-LdLog {
    param([string]$Msg, [string]$Color = 'TextDim')
    Write-AppLog $Msg $Color
}

# ── Async user load ────────────────────────────────────────────────────────────
function Start-LdUserLoad {
    if ($Script:DemoMode) { Start-LdUserLoadDemo; return }
    $Script:LD_UI.UserList.Items.Clear()
    $Script:LD_UI.UserSearch.Text      = ''
    $Script:LD_UI.UserSearch.IsEnabled = $false
    $Script:LD_UI.UserList.IsEnabled   = $false
    $Script:LD_UI.DevList.Items.Clear()
    $Script:LD_UI.DevList.Visibility         = 'Collapsed'
    $Script:LD_UI.DevPlaceholder.Text        = 'Select a user to see their devices'
    $Script:LD_UI.DevPlaceholder.Visibility  = 'Visible'
    $Script:LD_UI.BtnCopy.IsEnabled          = $false
    Set-MainStatus 'Loading users...' 'TextDim'
    Write-LdLog 'Fetching users from Entra ID...' 'TextDim'

    if ($Script:LD_UserTimer) { $Script:LD_UserTimer.Stop() }
    $Script:LD_UserTimer = Start-AsyncWork -RefSeed @{ Users = $null } -Script {
        $users = [System.Collections.Generic.List[object]]::new()
        $url   = 'https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName&$top=999'
        do {
            $resp = Invoke-RestMethod -Uri $url `
                -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
            foreach ($u in $resp.value) { $users.Add($u) }
            $url = $resp.'@odata.nextLink'
        } while ($url)
        $Ref['Users'] = $users.ToArray()
    } -OnComplete {
        param($ref)
        try {
            if ($ref['Error'] -eq '401') {
                Write-Log 'LastDevice: user load 401 - session expired' 'ERROR'
                Write-LdLog 'Session expired - reconnect via the tenant selector.' 'Danger'
                Set-MainStatus 'Session expired.' 'Danger'
                return
            }
            if ($ref['Error']) {
                Write-Log "LastDevice: user load failed - $($ref['Error'])" 'ERROR'
                Write-LdLog "Error loading users: $($ref['Error'])" 'Danger'
                Set-MainStatus 'Failed to load users.' 'Danger'
                return
            }

            $Script:LD_AllUsers = @($ref['Users'] | Sort-Object { $_.displayName })
            Update-LdUserFilter
            $Script:LD_UI.UserSearch.IsEnabled = $true
            $Script:LD_UI.UserList.IsEnabled   = $true
            $n = $Script:LD_AllUsers.Count
            Write-Log "LastDevice: loaded $n users" 'INFO'
            Write-LdLog "Loaded $n users." 'Success'
            Set-MainStatus "Loaded $n users." 'Success'
        } catch {
            Write-Log "LastDevice user-load timer error: $_" 'ERROR'
        }
    }
}

function Update-LdUserFilter {
    $filter = $Script:LD_UI.UserSearch.Text.Trim()
    $Script:LD_UI.UserList.Items.Clear()
    $list = if ([string]::IsNullOrWhiteSpace($filter)) {
        $Script:LD_AllUsers
    } else {
        $Script:LD_AllUsers | Where-Object {
            $_.displayName       -like "*$filter*" -or
            $_.userPrincipalName -like "*$filter*"
        }
    }
    foreach ($u in $list) {
        $lbi         = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Content = $u.displayName
        $lbi.Tag     = $u
        $lbi.ToolTip = $u.userPrincipalName
        [void]$Script:LD_UI.UserList.Items.Add($lbi)
    }
}

# ── Async device load ──────────────────────────────────────────────────────────
function Start-LdDeviceLoad {
    param([string]$UserId)
    if ($Script:DemoMode) { Start-LdDeviceLoadDemo -UserId $UserId; return }

    $Script:LD_UI.DevList.Items.Clear()
    $Script:LD_UI.DevList.Visibility        = 'Collapsed'
    $Script:LD_UI.DevPlaceholder.Text       = 'Loading devices...'
    $Script:LD_UI.DevPlaceholder.Visibility = 'Visible'
    $Script:LD_UI.BtnCopy.IsEnabled         = $false
    Set-MainStatus 'Searching devices...' 'TextDim'

    if ($Script:LD_DevTimer) { $Script:LD_DevTimer.Stop() }
    $Script:LD_DevTimer = Start-AsyncWork `
        -Vars    @{ UserId  = $UserId } `
        -RefSeed @{ Devices = $null } `
        -Script {
            # Intune OData does not support lambda filters on usersLoggedOn, so we page
            # all devices and match client-side.
            $matches = [System.Collections.Generic.List[object]]::new()
            $url = 'https://graph.microsoft.com/beta/deviceManagement/managedDevices?$select=id,deviceName,model,usersLoggedOn&$top=999'
            do {
                $resp = Invoke-RestMethod -Uri $url `
                    -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
                foreach ($d in $resp.value) {
                    if ($d.usersLoggedOn | Where-Object { $_.userId -eq $UserId }) {
                        [void]$matches.Add($d)
                    }
                }
                $url = $resp.'@odata.nextLink'
            } while ($url)
            $Ref['Devices'] = $matches.ToArray()
        } -OnComplete {
            param($ref)
            try {
                if ($ref['Error'] -eq '401') {
                    Write-Log 'LastDevice: device load 401 - session expired' 'ERROR'
                    $Script:LD_UI.DevPlaceholder.Text = 'Session expired - reconnect.'
                    Set-MainStatus 'Session expired.' 'Danger'
                    return
                }
                if ($ref['Error']) {
                    Write-Log "LastDevice: device load failed - $($ref['Error'])" 'ERROR'
                    $Script:LD_UI.DevPlaceholder.Text = 'Failed to load devices.'
                    Set-MainStatus "Error: $($ref['Error'])" 'Danger'
                    return
                }

                $userId  = $Script:LD_UI.UserList.SelectedItem.Tag.id
                $devices = @($ref['Devices'] | Sort-Object {
                    $entry = $_.usersLoggedOn | Where-Object { $_.userId -eq $userId } | Select-Object -First 1
                    if ($entry -and $entry.lastLogOnDateTime) { [datetime]$entry.lastLogOnDateTime }
                    else { [datetime]::MinValue }
                } -Descending)

                Write-Log "LastDevice: $($devices.Count) device(s) found for user $userId" 'INFO'

                if ($devices.Count -eq 0) {
                    $Script:LD_UI.DevPlaceholder.Text       = 'No devices found for this user.'
                    $Script:LD_UI.DevPlaceholder.Visibility = 'Visible'
                    $Script:LD_UI.DevList.Visibility        = 'Collapsed'
                    Set-MainStatus 'No devices found.' 'TextDim'
                    return
                }

                foreach ($d in $devices) {
                    $lbi         = [System.Windows.Controls.ListBoxItem]::new()
                    $lbi.Content = $d.deviceName
                    $lbi.Tag     = $d
                    $entry = $d.usersLoggedOn | Where-Object { $_.userId -eq $userId } | Select-Object -First 1
                    if ($entry -and $entry.lastLogOnDateTime) {
                        $lbi.ToolTip = "Last check-in: $([datetime]$entry.lastLogOnDateTime)"
                    }
                    [void]$Script:LD_UI.DevList.Items.Add($lbi)
                }
                $Script:LD_UI.DevPlaceholder.Visibility = 'Collapsed'
                $Script:LD_UI.DevList.Visibility        = 'Visible'
                $n = $devices.Count
                Set-MainStatus "Loaded $n device$(if ($n -ne 1) { 's' })." 'Success'
            } catch {
                Write-Log "LastDevice device-load timer error: $_" 'ERROR'
            }
        }
}

# ── Async all-devices load (for "By Device" tab) ──────────────────────────────
function Start-LdAllDevicesLoad {
    if ($Script:DemoMode) { Start-LdAllDevicesLoadDemo; return }
    $Script:LD_UI.DevBrowserSearch.IsEnabled = $false
    $Script:LD_UI.DevBrowserList.IsEnabled   = $false
    $Script:LD_UI.DevBrowserList.Items.Clear()
    Write-LdLog 'By Device: fetching all Intune devices...' 'TextDim'

    if ($Script:LD_AllDevTimer) { $Script:LD_AllDevTimer.Stop() }
    $Script:LD_AllDevTimer = Start-AsyncWork -RefSeed @{ Devices = $null } -Script {
        $devices = [System.Collections.Generic.List[object]]::new()
        $url = 'https://graph.microsoft.com/beta/deviceManagement/managedDevices?$select=id,deviceName,model,serialNumber,usersLoggedOn,lastSyncDateTime&$top=999'
        do {
            $resp = Invoke-RestMethod -Uri $url `
                -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
            foreach ($d in $resp.value) { $devices.Add($d) }
            $url = $resp.'@odata.nextLink'
        } while ($url)
        $Ref['Devices'] = $devices.ToArray()
    } -OnComplete {
        param($ref)
        try {
            if ($ref['Error'] -eq '401') {
                Write-Log 'LastDevice/ByDevice: device load 401 - session expired' 'ERROR'
                Write-LdLog 'By Device: session expired - reconnect.' 'Danger'
                return
            }
            if ($ref['Error']) {
                Write-Log "LastDevice/ByDevice: device load failed - $($ref['Error'])" 'ERROR'
                Write-LdLog "By Device: failed to load devices - $($ref['Error'])" 'Danger'
                return
            }

            $Script:LD_AllDevices = @($ref['Devices'] | Sort-Object { $_.deviceName })
            Write-Log "LastDevice/ByDevice: loaded $($Script:LD_AllDevices.Count) devices" 'INFO'
            Write-LdLog "By Device: loaded $($Script:LD_AllDevices.Count) devices." 'Success'
            Update-LdDevBrowserFilter
            Update-LdStaleFilter
            $Script:LD_UI.DevBrowserSearch.IsEnabled = $true
            $Script:LD_UI.DevBrowserList.IsEnabled   = $true
        } catch {
            Write-Log "LastDevice all-devices timer error: $_" 'ERROR'
        }
    }
}

function Update-LdDevBrowserFilter {
    $filter = $Script:LD_UI.DevBrowserSearch.Text.Trim()
    $Script:LD_UI.DevBrowserList.Items.Clear()
    $list = if ([string]::IsNullOrWhiteSpace($filter)) {
        $Script:LD_AllDevices
    } else {
        $Script:LD_AllDevices | Where-Object { $_.deviceName -like "*$filter*" }
    }
    foreach ($d in $list) {
        $lbi         = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Content = $d.deviceName
        $lbi.Tag     = $d
        [void]$Script:LD_UI.DevBrowserList.Items.Add($lbi)
    }
}

function Update-LdStaleFilter {
    if (-not $Script:LD_UI -or -not $Script:LD_UI.StaleGrid) { return }
    $thresholdMap = @{ 0 = 7; 1 = 30; 2 = 60; 3 = 90 }
    $days   = $thresholdMap[$Script:LD_UI.StaleDays.SelectedIndex]
    $now    = [datetime]::Now
    $cutoff = $now.AddDays(-$days)
    $rows   = [System.Collections.Generic.List[PSObject]]::new()

    foreach ($d in $Script:LD_AllDevices) {
        # lastSyncDateTime is when the device last checked in with Intune (UTC string ending in Z)
        $syncDate = $null
        if ($d.lastSyncDateTime) {
            try {
                $parsed = [datetime]::Parse($d.lastSyncDateTime,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind)
                # Convert to local time; treat Intune sentinel 0001-01-01 as "never synced"
                if ($parsed.Year -gt 1) { $syncDate = $parsed.ToLocalTime() }
            } catch {}
        }
        if ($syncDate -and $syncDate -gt $cutoff) { continue }

        # Derive last user from usersLoggedOn (separate from check-in date)
        $lastEntry = $d.usersLoggedOn |
            Sort-Object {
                if ($_.lastLogOnDateTime) { [datetime]$_.lastLogOnDateTime } else { [datetime]::MinValue }
            } -Descending |
            Select-Object -First 1
        $lastUser = if ($lastEntry) {
            $u = $Script:LD_AllUsers | Where-Object { $_.id -eq $lastEntry.userId } | Select-Object -First 1
            if ($u) { $u.displayName } else { $lastEntry.userId }
        } else { '(none)' }

        $checkinStr = if ($syncDate) { $syncDate.ToString('yyyy-MM-dd HH:mm') } else { 'Never' }
        $sortNum    = if ($syncDate) { [int]($now - $syncDate).TotalDays } else { [int]::MaxValue }

        $rows.Add([PSCustomObject]@{
            DeviceName  = $d.deviceName
            LastUser    = $lastUser
            LastCheckin = $checkinStr
            DaysSince   = if ($sortNum -eq [int]::MaxValue) { 'Never' } else { "$sortNum" }
            _Sort       = $sortNum
        })
    }

    $sorted = [object[]]($rows | Sort-Object { $_._Sort } -Descending)
    $Script:LD_UI.StaleGrid.ItemsSource = $sorted
    $n = $rows.Count
    $Script:LD_UI.StaleCount.Text = "$n device$(if ($n -ne 1) { 's' }) stale"
}

function Show-LdDeviceUsers {
    param($Device)
    $Script:LD_UI.DevUserList.Items.Clear()
    $Script:LD_UI.DevUserList.Visibility        = 'Collapsed'
    $Script:LD_UI.DevUserPlaceholder.Visibility = 'Visible'

    $logons = @($Device.usersLoggedOn | Sort-Object {
        if ($_.lastLogOnDateTime) { [datetime]$_.lastLogOnDateTime } else { [datetime]::MinValue }
    } -Descending)

    if ($logons.Count -eq 0) {
        $Script:LD_UI.DevUserPlaceholder.Text = 'No sign-in records for this device.'
        return
    }

    foreach ($logon in $logons) {
        $user = $Script:LD_AllUsers | Where-Object { $_.id -eq $logon.userId } | Select-Object -First 1
        $lbi         = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Content = if ($user) { $user.displayName } else { $logon.userId }
        $lbi.ToolTip = if ($user) {
            "$($user.userPrincipalName)$(if ($logon.lastLogOnDateTime) { " — last sign-in: $([datetime]$logon.lastLogOnDateTime)" })"
        } else { $logon.userId }
        $lbi.Tag     = $logon
        [void]$Script:LD_UI.DevUserList.Items.Add($lbi)
    }

    $Script:LD_UI.DevUserPlaceholder.Visibility = 'Collapsed'
    $Script:LD_UI.DevUserList.Visibility        = 'Visible'
}

# ── CSV reports: devices + the users who signed in over the past 3 months ───────
$Script:LD_ReportMonths = 3

# Collect (user, sign-in) pairs for a device within the cutoff window, newest
# first and one entry per user (a user can appear multiple times in usersLoggedOn).
function Get-LdRecentLogons {
    param($Device, [datetime]$Cutoff)
    $result = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($logon in $Device.usersLoggedOn) {
        if (-not $logon.lastLogOnDateTime) { continue }
        try { $signIn = ([datetime]$logon.lastLogOnDateTime).ToLocalTime() } catch { continue }
        if ($signIn -lt $Cutoff) { continue }
        $user = $Script:LD_AllUsers | Where-Object { $_.id -eq $logon.userId } | Select-Object -First 1
        $result.Add([PSCustomObject]@{
            UserId      = $logon.userId
            DisplayName = if ($user) { $user.displayName } else { $logon.userId }
            UPN         = if ($user) { $user.userPrincipalName } else { '' }
            SignIn      = $signIn
        })
    }
    # newest first, then keep only the most recent sign-in per user
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    @($result | Sort-Object SignIn -Descending | Where-Object { $seen.Add([string]$_.UserId) })
}

# Format a device's Intune lastSyncDateTime as local time (blank if never synced).
function Get-LdCheckinString {
    param($Device)
    if (-not $Device.lastSyncDateTime) { return '' }
    try {
        $parsed = [datetime]::Parse($Device.lastSyncDateTime,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind)
        if ($parsed.Year -gt 1) { return $parsed.ToLocalTime().ToString('yyyy-MM-dd HH:mm') }
    } catch {}
    return ''
}

# Prompt for a path and write rows to CSV. Returns $true if saved.
function Save-LdReportCsv {
    param([object[]]$Rows, [string]$BaseName)
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter   = 'CSV files (*.csv)|*.csv'
    $dlg.FileName = "${BaseName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    if (-not $dlg.ShowDialog()) { return $false }
    $Rows | Export-Csv -Path $dlg.FileName -NoTypeInformation -Encoding UTF8
    Write-Log "LastDevice: exported $($Rows.Count) rows to $($dlg.FileName)" 'INFO'
    Write-LdLog "Report exported: $($dlg.FileName) ($($Rows.Count) rows)" 'Success'
    Set-MainStatus "Saved: $($dlg.FileName)" 'Success'
    [System.Windows.MessageBox]::Show("Saved to:`n$($dlg.FileName)", 'Report Complete', 'OK', 'Information') | Out-Null
    return $true
}

# By User: one row per device/user sign-in within the past 3 months.
function Export-LdByUserReport {
    if (-not $Script:LD_AllDevices -or $Script:LD_AllDevices.Count -eq 0) {
        Write-LdLog 'Report: no device data loaded yet — connect a tenant first.' 'Warning'
        Set-MainStatus 'No device data loaded yet.' 'Warning'
        return
    }
    $cutoff = [datetime]::Now.AddMonths(-$Script:LD_ReportMonths)
    $rows   = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($d in $Script:LD_AllDevices) {
        foreach ($logon in (Get-LdRecentLogons -Device $d -Cutoff $cutoff)) {
            $rows.Add([PSCustomObject]@{
                DeviceName        = $d.deviceName
                User              = $logon.DisplayName
                UserPrincipalName = $logon.UPN
                LastSignIn        = $logon.SignIn.ToString('yyyy-MM-dd HH:mm')
            })
        }
    }
    if ($rows.Count -eq 0) {
        Write-LdLog 'Report: no sign-ins in the past 3 months.' 'TextDim'
        Set-MainStatus 'No sign-ins in the past 3 months.' 'TextDim'
        return
    }
    $sorted = $rows | Sort-Object `
        @{ Expression = 'DeviceName' }, `
        @{ Expression = { [datetime]$_.LastSignIn }; Descending = $true }
    [void](Save-LdReportCsv -Rows ([object[]]$sorted) -BaseName 'DeviceUserReport')
}

# By Device: one row per Intune device, listing the users that signed in over the past 3 months.
function Export-LdByDeviceReport {
    if (-not $Script:LD_AllDevices -or $Script:LD_AllDevices.Count -eq 0) {
        Write-LdLog 'Report: no device data loaded yet — connect a tenant first.' 'Warning'
        Set-MainStatus 'No device data loaded yet.' 'Warning'
        return
    }
    $cutoff = [datetime]::Now.AddMonths(-$Script:LD_ReportMonths)
    $rows   = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($d in $Script:LD_AllDevices) {
        $logons = Get-LdRecentLogons -Device $d -Cutoff $cutoff
        # One user per line keeps the cell readable when 20+ users share a device
        # (Excel shows each on its own line with wrap-text).
        $rows.Add([PSCustomObject]@{
            DeviceName   = $d.deviceName
            Users        = (($logons | ForEach-Object { $_.DisplayName }) -join "`r`n")
            Model        = $d.model
            SerialNumber = $d.serialNumber
            UserCount    = $logons.Count
            LastSignIn   = if ($logons.Count) { $logons[0].SignIn.ToString('yyyy-MM-dd HH:mm') } else { '' }
            LastCheckIn  = (Get-LdCheckinString -Device $d)
        })
    }
    $sorted = $rows | Sort-Object DeviceName
    [void](Save-LdReportCsv -Rows ([object[]]$sorted) -BaseName 'DeviceReport')
}

# ── XAML ───────────────────────────────────────────────────────────────────────
$Script:LastDeviceXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
      Background="#12121C">
  <Grid.Resources>

    <SolidColorBrush x:Key="Bg"      Color="#12121C"/>
    <SolidColorBrush x:Key="Surface" Color="#1C1C2A"/>
    <SolidColorBrush x:Key="Card"    Color="#242436"/>
    <SolidColorBrush x:Key="Border"  Color="#3C3C5A"/>
    <SolidColorBrush x:Key="Accent"  Color="#6366F1"/>
    <SolidColorBrush x:Key="Text"    Color="#E2E2F0"/>
    <SolidColorBrush x:Key="TextDim" Color="#7878A0"/>
    <SolidColorBrush x:Key="Muted"   Color="#50507A"/>

    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Foreground"      Value="White"/>
      <Setter Property="FontWeight"      Value="SemiBold"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor"          Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.85"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="#242436"/>
                <Setter Property="Foreground" Value="#3C3C5A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background"               Value="#242436"/>
      <Setter Property="Foreground"               Value="#E2E2F0"/>
      <Setter Property="BorderBrush"              Value="#3C3C5A"/>
      <Setter Property="BorderThickness"          Value="1"/>
      <Setter Property="Padding"                  Value="8,4"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="CaretBrush"               Value="#E2E2F0"/>
      <Setter Property="FocusVisualStyle"         Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="4">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                            Background="{TemplateBinding Background}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="#1C1C2A"/>
                <Setter Property="Foreground" Value="#3C3C5A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBox">
      <Setter Property="Background"        Value="#242436"/>
      <Setter Property="Foreground"        Value="#E2E2F0"/>
      <Setter Property="BorderBrush"       Value="#3C3C5A"/>
      <Setter Property="BorderThickness"   Value="1"/>
      <Setter Property="Height"            Value="32"/>
      <Setter Property="Padding"           Value="8,0"/>
      <Setter Property="MaxDropDownHeight" Value="220"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <Border x:Name="bd" CornerRadius="4"
                      Background="{TemplateBinding Background}"
                      BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="{TemplateBinding BorderThickness}"/>
              <ContentPresenter Margin="{TemplateBinding Padding}"
                                VerticalAlignment="Center" HorizontalAlignment="Left"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentStringFormat="{TemplateBinding SelectionBoxItemStringFormat}"
                                IsHitTestVisible="False"/>
              <Path x:Name="arrow" Data="M0,0 L4,4 L8,0 Z" Fill="#7878A0"
                    HorizontalAlignment="Right" VerticalAlignment="Center"
                    Margin="0,0,10,0" IsHitTestVisible="False"/>
              <ToggleButton Focusable="False" Cursor="Hand"
                            IsChecked="{Binding IsDropDownOpen,
                                        RelativeSource={RelativeSource TemplatedParent},
                                        Mode=TwoWay}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Rectangle Fill="Transparent"/>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <Popup x:Name="PART_Popup" AllowsTransparency="True"
                     IsOpen="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}}"
                     Placement="Bottom" PopupAnimation="Slide">
                <Border Background="#242436" BorderBrush="#3C3C5A" BorderThickness="1"
                        CornerRadius="0,0,4,4"
                        MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <ScrollViewer><ItemsPresenter/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#6366F1"/>
              </Trigger>
              <Trigger Property="IsDropDownOpen" Value="True">
                <Setter TargetName="bd"    Property="CornerRadius" Value="4,4,0,0"/>
                <Setter TargetName="arrow" Property="Fill"         Value="#E2E2F0"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="#1C1C2A"/>
                <Setter Property="Foreground" Value="#3C3C5A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ListBox">
      <Setter Property="Background"      Value="#12121C"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding"         Value="0"/>
    </Style>

    <Style TargetType="ListBoxItem">
      <Setter Property="Foreground"                 Value="#E2E2F0"/>
      <Setter Property="Background"                 Value="Transparent"/>
      <Setter Property="Padding"                    Value="12,7"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Cursor"                     Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1E1E38"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#2A2A50"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="DataGrid">
      <Setter Property="Background"               Value="#12121C"/>
      <Setter Property="Foreground"               Value="#E2E2F0"/>
      <Setter Property="BorderThickness"          Value="0"/>
      <Setter Property="GridLinesVisibility"      Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#1E1E32"/>
      <Setter Property="RowBackground"            Value="#12121C"/>
      <Setter Property="AlternatingRowBackground" Value="#181826"/>
      <Setter Property="ColumnHeaderHeight"       Value="34"/>
      <Setter Property="RowHeight"                Value="28"/>
      <Setter Property="AutoGenerateColumns"      Value="False"/>
      <Setter Property="CanUserAddRows"           Value="False"/>
      <Setter Property="CanUserDeleteRows"        Value="False"/>
      <Setter Property="IsReadOnly"               Value="True"/>
      <Setter Property="SelectionMode"            Value="Single"/>
      <Setter Property="SelectionUnit"            Value="FullRow"/>
      <Setter Property="FontSize"                 Value="12"/>
    </Style>

    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background"      Value="#1C1C2A"/>
      <Setter Property="Foreground"      Value="#7878A0"/>
      <Setter Property="FontWeight"      Value="SemiBold"/>
      <Setter Property="Padding"         Value="12,0"/>
      <Setter Property="BorderBrush"     Value="#3C3C5A"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="FontSize"        Value="11"/>
    </Style>

    <Style TargetType="DataGridRow">
      <Setter Property="Background" Value="Transparent"/>
      <Style.Triggers>
        <Trigger Property="IsSelected"  Value="True">
          <Setter Property="Background" Value="#2A2A50"/>
        </Trigger>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#1E1E38"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding"         Value="12,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Padding="{TemplateBinding Padding}" Background="{TemplateBinding Background}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TabControl">
      <Setter Property="Background"      Value="#12121C"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>

    <Style TargetType="TabItem">
      <Setter Property="Foreground"      Value="#7878A0"/>
      <Setter Property="Background"      Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding"         Value="14,8"/>
      <Setter Property="FontWeight"      Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border Padding="{TemplateBinding Padding}" Cursor="Hand">
              <Border x:Name="ind" BorderThickness="0,0,0,2" BorderBrush="Transparent" Padding="0,0,0,3">
                <ContentPresenter ContentSource="Header"/>
              </Border>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter Property="Foreground" Value="#E2E2F0"/>
                <Setter TargetName="ind" Property="BorderBrush" Value="#6366F1"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

  </Grid.Resources>

  <Grid.RowDefinitions>
    <RowDefinition Height="*"/>
  </Grid.RowDefinitions>

  <TabControl>
    <TabControl.Template>
      <ControlTemplate TargetType="TabControl">
        <Grid Background="#12121C">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Border Grid.Row="0" Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
            <TabPanel IsItemsHost="True" Margin="8,0"/>
          </Border>
          <ContentPresenter Grid.Row="1" ContentSource="SelectedContent"/>
        </Grid>
      </ControlTemplate>
    </TabControl.Template>

    <!-- By User tab: pick a user, see their devices -->
    <TabItem Header="By User">
      <Grid Background="#12121C">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*" MinWidth="200"/>
          <ColumnDefinition Width="5"/>
          <ColumnDefinition Width="*" MinWidth="200"/>
        </Grid.ColumnDefinitions>

        <GridSplitter Grid.Column="1" Width="5" HorizontalAlignment="Stretch"
                      Background="#3C3C5A" Cursor="SizeWE" ResizeBehavior="PreviousAndNext"/>

        <!-- Users panel -->
        <Border Grid.Column="0" Background="#1C1C2A">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Padding="12,10" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
              <StackPanel>
                <TextBlock Text="USERS" Foreground="#50507A" FontSize="10" FontWeight="Bold" Margin="0,0,0,8"/>
                <TextBox x:Name="LdUserSearch" IsEnabled="False" Height="34"
                         Tag="Search by name or UPN..."/>
              </StackPanel>
            </Border>
            <ListBox x:Name="LdUserList" Grid.Row="1" IsEnabled="False"
                     ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                     VirtualizingPanel.IsVirtualizing="True"
                     VirtualizingPanel.VirtualizationMode="Recycling"
                     Margin="0,2,0,2"/>
          </Grid>
        </Border>

        <!-- Devices panel -->
        <Border Grid.Column="2" Background="#12121C">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Background="#1C1C2A" Padding="12,10"
                    BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
              <TextBlock Text="DEVICES" Foreground="#50507A" FontSize="10" FontWeight="Bold"/>
            </Border>
            <TextBlock x:Name="LdDevPlaceholder" Grid.Row="1"
                       Text="Select a user to see their devices"
                       Foreground="#50507A" FontStyle="Italic" FontSize="12"
                       HorizontalAlignment="Center" VerticalAlignment="Center"
                       Visibility="Visible"/>
            <ListBox x:Name="LdDevList" Grid.Row="1"
                     ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                     VirtualizingPanel.IsVirtualizing="True"
                     VirtualizingPanel.VirtualizationMode="Recycling"
                     Margin="0,2,0,2" Visibility="Collapsed"/>
            <Border x:Name="LdDevDetailPanel" Grid.Row="2" Background="#1C1C2A" Padding="10,6"
                    BorderBrush="#3C3C5A" BorderThickness="0,1,0,0" Visibility="Collapsed">
              <TextBlock x:Name="LdDevDetail" Foreground="#7878A0" FontSize="11" TextWrapping="Wrap"/>
            </Border>
            <Border Grid.Row="3" Background="#1C1C2A" Padding="10,8"
                    BorderBrush="#3C3C5A" BorderThickness="0,1,0,0">
              <StackPanel Orientation="Horizontal">
                <Button x:Name="LdBtnCopy" Content="Copy Device Name" IsEnabled="False"
                        Style="{StaticResource PrimaryBtn}" Background="#6366F1" Padding="14,7"
                        HorizontalAlignment="Left"/>
                <Button x:Name="LdBtnReport" Content="Export Report (CSV)"
                        Style="{StaticResource PrimaryBtn}" Background="#242436" Padding="14,7"
                        Margin="8,0,0,0" HorizontalAlignment="Left"
                        ToolTip="Export all devices and the users that signed into them in the past 3 months"/>
              </StackPanel>
            </Border>
          </Grid>
        </Border>
      </Grid>
    </TabItem>

    <!-- By Device tab: pick a device, see who signed into it -->
    <TabItem Header="By Device">
      <Grid Background="#12121C">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*" MinWidth="200"/>
          <ColumnDefinition Width="5"/>
          <ColumnDefinition Width="*" MinWidth="200"/>
        </Grid.ColumnDefinitions>

        <GridSplitter Grid.Column="1" Width="5" HorizontalAlignment="Stretch"
                      Background="#3C3C5A" Cursor="SizeWE" ResizeBehavior="PreviousAndNext"/>

        <!-- Devices panel (left) -->
        <Border Grid.Column="0" Background="#1C1C2A">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Padding="12,10" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
              <StackPanel>
                <TextBlock Text="DEVICES" Foreground="#50507A" FontSize="10" FontWeight="Bold" Margin="0,0,0,8"/>
                <TextBox x:Name="LdDevBrowserSearch" IsEnabled="False" Height="34"
                         Tag="Search by device name..."/>
              </StackPanel>
            </Border>
            <ListBox x:Name="LdDevBrowserList" Grid.Row="1" IsEnabled="False"
                     ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                     VirtualizingPanel.IsVirtualizing="True"
                     VirtualizingPanel.VirtualizationMode="Recycling"
                     Margin="0,2,0,2"/>
          </Grid>
        </Border>

        <!-- Users panel (right) -->
        <Border Grid.Column="2" Background="#12121C">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Background="#1C1C2A" Padding="12,10"
                    BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
              <TextBlock Text="SIGNED-IN USERS" Foreground="#50507A" FontSize="10" FontWeight="Bold"/>
            </Border>
            <TextBlock x:Name="LdDevUserPlaceholder" Grid.Row="1"
                       Text="Select a device to see who signed into it"
                       Foreground="#50507A" FontStyle="Italic" FontSize="12"
                       HorizontalAlignment="Center" VerticalAlignment="Center"
                       Visibility="Visible"/>
            <ListBox x:Name="LdDevUserList" Grid.Row="1"
                     ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                     VirtualizingPanel.IsVirtualizing="True"
                     VirtualizingPanel.VirtualizationMode="Recycling"
                     Margin="0,2,0,2" Visibility="Collapsed"/>
            <Border x:Name="LdDevUserDetailPanel" Grid.Row="2" Background="#1C1C2A" Padding="10,6"
                    BorderBrush="#3C3C5A" BorderThickness="0,1,0,0" Visibility="Collapsed">
              <TextBlock x:Name="LdDevUserDetail" Foreground="#7878A0" FontSize="11" TextWrapping="Wrap"/>
            </Border>
            <Border Grid.Row="3" Background="#1C1C2A" Padding="10,8"
                    BorderBrush="#3C3C5A" BorderThickness="0,1,0,0">
              <Button x:Name="LdBtnDeviceReport" Content="Export Report (CSV)"
                      Style="{StaticResource PrimaryBtn}" Background="#242436" Padding="14,7"
                      HorizontalAlignment="Left"
                      ToolTip="Export every Intune device and the users that signed into it in the past 3 months"/>
            </Border>
          </Grid>
        </Border>
      </Grid>
    </TabItem>

    <!-- Stale Devices tab: devices not checked in for N days -->
    <TabItem Header="Stale Devices">
      <Grid Background="#12121C">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Border Grid.Row="0" Background="#1C1C2A" Padding="12,10"
                BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock Text="Not checked in for:" Foreground="#7878A0"
                       FontSize="12" VerticalAlignment="Center" Margin="0,0,10,0"/>
            <ComboBox x:Name="LdStaleDays" Width="130"/>
            <TextBlock x:Name="LdStaleCount" Foreground="#7878A0"
                       FontSize="12" VerticalAlignment="Center" Margin="16,0,0,0"/>
          </StackPanel>
        </Border>
        <DataGrid x:Name="LdStaleGrid" Grid.Row="1" CanUserSortColumns="False"
                  VirtualizingPanel.IsVirtualizing="True"
                  VirtualizingPanel.VirtualizationMode="Recycling">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Device Name"   Binding="{Binding DeviceName}"  Width="*"/>
            <DataGridTextColumn Header="Last User"     Binding="{Binding LastUser}"    Width="*"/>
            <DataGridTextColumn Header="Last Check-In" Binding="{Binding LastCheckin}" Width="140"/>
            <DataGridTextColumn Header="Days Since"    Binding="{Binding DaysSince}"   Width="90"/>
          </DataGrid.Columns>
        </DataGrid>
      </Grid>
    </TabItem>

    <!-- Log tab removed — use the global Log pane -->

  </TabControl>
  </Grid>
'@

# ── Initialize ─────────────────────────────────────────────────────────────────
function Initialize-LastDeviceTool {
    $reader  = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new((Invoke-ThemeXaml $Script:LastDeviceXaml)))
    $content = [System.Windows.Markup.XamlReader]::Load($reader)

    $Script:LD_UI = @{
        UserSearch        = $content.FindName('LdUserSearch')
        UserList          = $content.FindName('LdUserList')
        DevPlaceholder    = $content.FindName('LdDevPlaceholder')
        DevList           = $content.FindName('LdDevList')
        DevDetail         = $content.FindName('LdDevDetail')
        DevDetailPanel    = $content.FindName('LdDevDetailPanel')
        BtnCopy           = $content.FindName('LdBtnCopy')
        BtnReport         = $content.FindName('LdBtnReport')
        BtnDeviceReport   = $content.FindName('LdBtnDeviceReport')
        DevBrowserSearch  = $content.FindName('LdDevBrowserSearch')
        DevBrowserList    = $content.FindName('LdDevBrowserList')
        DevUserList       = $content.FindName('LdDevUserList')
        DevUserDetail     = $content.FindName('LdDevUserDetail')
        DevUserDetailPanel= $content.FindName('LdDevUserDetailPanel')
        DevUserPlaceholder= $content.FindName('LdDevUserPlaceholder')
        # LogBox removed — use Write-AppLog to the global Log pane
        StaleDays         = $content.FindName('LdStaleDays')
        StaleGrid         = $content.FindName('LdStaleGrid')
        StaleCount        = $content.FindName('LdStaleCount')
    }

    '7 days','30 days','60 days','90 days' | ForEach-Object {
        $Script:LD_UI.StaleDays.Items.Add($_) | Out-Null
    }
    $Script:LD_UI.StaleDays.SelectedIndex = 1
    $Script:LD_UI.StaleDays.Add_SelectionChanged({
        try { Update-LdStaleFilter }
        catch { Write-Log "StaleDays SelectionChanged error: $_" 'ERROR' }
    })

    # Search box
    $Script:LD_UI.UserSearch.Add_TextChanged({
        try { Update-LdUserFilter }
        catch { Write-Log "UserSearch TextChanged error: $_" 'ERROR' }
    })

    # User selection -> load devices
    $Script:LD_UI.UserList.Add_SelectionChanged({
        try {
            $sel = $Script:LD_UI.UserList.SelectedItem
            if (-not $sel) { return }
            Write-Log "LastDevice: selected user '$($sel.Content)' ($($sel.Tag.id))" 'DEBUG'
            Start-LdDeviceLoad -UserId $sel.Tag.id
        } catch {
            Write-Log "UserList SelectionChanged error: $_" 'ERROR'
        }
    })

    # Device selection -> copy to clipboard + show timestamp
    $Script:LD_UI.DevList.Add_SelectionChanged({
        try {
            $sel = $Script:LD_UI.DevList.SelectedItem
            if (-not $sel) { 
                $Script:LD_UI.BtnCopy.IsEnabled = $false
                $Script:LD_UI.DevDetailPanel.Visibility = 'Collapsed'
                return 
            }
            Write-Log "LastDevice: device selected '$($sel.Content)'" 'DEBUG'
            [System.Windows.Clipboard]::SetText($sel.Content)
            Set-MainStatus "Copied: $($sel.Content)" 'Success'
            $Script:LD_UI.BtnCopy.IsEnabled = $true

            $parts = [System.Collections.Generic.List[string]]::new()
            if ($sel.Tag.model) { $parts.Add("Model: $($sel.Tag.model)") }

            $userSel = $Script:LD_UI.UserList.SelectedItem
            if ($userSel) {
                $userId = $userSel.Tag.id
                $entry = $sel.Tag.usersLoggedOn | Where-Object { $_.userId -eq $userId } | Select-Object -First 1
                if ($entry -and $entry.lastLogOnDateTime) {
                    $dt = ([datetime]$entry.lastLogOnDateTime).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
                    $parts.Add("Last used by $($userSel.Content): $dt")
                }
            }

            if ($parts.Count -gt 0) {
                $Script:LD_UI.DevDetail.Text = $parts -join '  ·  '
                $Script:LD_UI.DevDetailPanel.Visibility = 'Visible'
            } else {
                $Script:LD_UI.DevDetailPanel.Visibility = 'Collapsed'
            }
        } catch {
            Write-Log "DevList SelectionChanged error: $_" 'ERROR'
        }
    })

    # Copy button re-copies selected device
    $Script:LD_UI.BtnCopy.Add_Click({
        try {
            $sel = $Script:LD_UI.DevList.SelectedItem
            if (-not $sel) { return }
            Write-Log "LastDevice: BtnCopy clicked for '$($sel.Content)'" 'DEBUG'
            [System.Windows.Clipboard]::SetText($sel.Content)
            Set-MainStatus "Copied: $($sel.Content)" 'Success'
        } catch {
            Write-Log "BtnCopy click error: $_" 'ERROR'
        }
    })

    # Export By-User report (one row per device/user sign-in, past 3 months)
    $Script:LD_UI.BtnReport.Add_Click({
        try { Export-LdByUserReport }
        catch { Write-Log "BtnReport click error: $_" 'ERROR' }
    })

    # Export By-Device report (one row per device, past 3 months)
    $Script:LD_UI.BtnDeviceReport.Add_Click({
        try { Export-LdByDeviceReport }
        catch { Write-Log "BtnDeviceReport click error: $_" 'ERROR' }
    })

    # By Device: device search filter
    $Script:LD_UI.DevBrowserSearch.Add_TextChanged({
        try { Update-LdDevBrowserFilter }
        catch { Write-Log "DevBrowserSearch TextChanged error: $_" 'ERROR' }
    })

    # By Device: device selected -> show users
    $Script:LD_UI.DevBrowserList.Add_SelectionChanged({
        try {
            $sel = $Script:LD_UI.DevBrowserList.SelectedItem
            if (-not $sel) { 
                $Script:LD_UI.DevUserDetailPanel.Visibility = 'Collapsed'
                return 
            }
            Write-Log "LastDevice/ByDevice: selected device '$($sel.Content)'" 'DEBUG'
            Show-LdDeviceUsers -Device $sel.Tag
            Set-MainStatus "Device: $($sel.Content)" 'TextDim'
        } catch {
            Write-Log "DevBrowserList SelectionChanged error: $_" 'ERROR'
        }
    })

    # By Device: user selected -> show timestamp
    $Script:LD_UI.DevUserList.Add_SelectionChanged({
        try {
            $sel = $Script:LD_UI.DevUserList.SelectedItem
            if (-not $sel) { 
                $Script:LD_UI.DevUserDetailPanel.Visibility = 'Collapsed'
                return 
            }
            $logon = $sel.Tag
            if ($logon -and $logon.lastLogOnDateTime) {
                $dt = ([datetime]$logon.lastLogOnDateTime).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
                $Script:LD_UI.DevUserDetail.Text = "Last sign-in on this device: $dt"
                $Script:LD_UI.DevUserDetailPanel.Visibility = 'Visible'
            } else {
                $Script:LD_UI.DevUserDetailPanel.Visibility = 'Collapsed'
            }
        } catch {
            Write-Log "DevUserList SelectionChanged error: $_" 'ERROR'
        }
    })

    # Register with global connect/reset hooks
    Register-ConnectCallback 'Start-LdUserLoad'
    Register-ConnectCallback 'Start-LdAllDevicesLoad'
    $Script:ResetCallbacks.Add({
        $Script:LD_AllUsers   = @()
        $Script:LD_AllDevices = @()

        $Script:LD_UI.UserList.Items.Clear()
        $Script:LD_UI.UserSearch.Text      = ''
        $Script:LD_UI.UserSearch.IsEnabled = $false
        $Script:LD_UI.UserList.IsEnabled   = $false
        $Script:LD_UI.DevList.Items.Clear()
        $Script:LD_UI.DevList.Visibility        = 'Collapsed'
        $Script:LD_UI.DevPlaceholder.Text       = 'Select a user to see their devices'
        $Script:LD_UI.DevPlaceholder.Visibility = 'Visible'
        $Script:LD_UI.BtnCopy.IsEnabled         = $false

        $Script:LD_UI.DevBrowserSearch.Text      = ''
        $Script:LD_UI.DevBrowserSearch.IsEnabled = $false
        $Script:LD_UI.DevBrowserList.Items.Clear()
        $Script:LD_UI.DevBrowserList.IsEnabled   = $false
        $Script:LD_UI.DevUserList.Items.Clear()
        $Script:LD_UI.DevUserList.Visibility         = 'Collapsed'
        $Script:LD_UI.DevUserPlaceholder.Text        = 'Select a device to see who signed into it'
        $Script:LD_UI.DevUserPlaceholder.Visibility  = 'Visible'
        $Script:LD_UI.DevUserDetailPanel.Visibility   = 'Collapsed'
        $Script:LD_UI.StaleGrid.ItemsSource = $null
        $Script:LD_UI.StaleCount.Text = ''
        $Script:LD_UI.DevDetailPanel.Visibility = 'Collapsed'
    })

    Write-LdLog 'Last Device ready. Select a tenant to begin.' 'Muted'
    return $content
}
