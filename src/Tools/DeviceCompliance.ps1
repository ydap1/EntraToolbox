<#
    Device Compliance tab for Art's Entra Toolbox.
    Lists all Intune-managed devices not in a compliant state and shows
    the exact compliance policy settings that are failing.
    Dot-sourced by Start.ps1.
    Exposes Initialize-DeviceComplianceTool.
#>

# ── Script-level state ─────────────────────────────────────────────────────────
$Script:DC_UI         = $null
$Script:DC_AllDevices = @()
$Script:DC_DevRef     = $null
$Script:DC_DevTimer   = $null
$Script:DC_PolRef     = $null
$Script:DC_PolTimer   = $null

# ── Helpers ────────────────────────────────────────────────────────────────────
function Write-DcLog {
    param([string]$Msg, [string]$Color = '#7878A0')
    $ts   = Get-Date -Format 'HH:mm:ss'
    $para = New-Object System.Windows.Documents.Paragraph
    $run  = New-Object System.Windows.Documents.Run "[$ts]  $Msg"
    $run.Foreground = $Color
    $para.Inlines.Add($run)
    $para.Margin = '0'
    $Script:DC_UI.LogBox.Document.Blocks.Add($para)
    $Script:DC_UI.LogBox.ScrollToEnd()
}

function Get-DcStateLabel([string]$state) {
    switch ($state) {
        'noncompliant'   { 'Non-compliant' }
        'nonCompliant'   { 'Non-compliant' }
        'error'          { 'Error' }
        'inGracePeriod'  { 'Grace period' }
        'conflict'       { 'Conflict' }
        'unknown'        { 'Unknown' }
        default          { $state }
    }
}

function Get-DcStateColor([string]$state) {
    switch ($state) {
        { $_ -in 'noncompliant','nonCompliant' } { '#EF4444' }
        'error'         { '#F97316' }
        'inGracePeriod' { '#FBBF24' }
        'conflict'      { '#A855F7' }
        default         { '#7878A0' }
    }
}

# ── Async device load ──────────────────────────────────────────────────────────
function Start-DcDeviceLoad {
    if ($Script:DemoMode) { Start-DcDeviceLoadDemo; return }

    $Script:DC_UI.DevList.Items.Clear()
    $Script:DC_UI.DevSearch.IsEnabled   = $false
    $Script:DC_UI.DevList.IsEnabled     = $false
    $Script:DC_UI.BtnRefresh.IsEnabled  = $false
    $Script:DC_UI.DevCount.Text         = ''
    $Script:DC_UI.Placeholder.Text      = 'Select a device to view compliance details'
    $Script:DC_UI.Placeholder.Visibility  = 'Visible'
    $Script:DC_UI.DetailPanel.Visibility  = 'Collapsed'
    Set-MainStatus 'Loading non-compliant devices...' '#7878A0'
    Write-DcLog 'Fetching non-compliant devices from Intune...' '#7878A0'

    $Script:DC_DevRef = [hashtable]::Synchronized(@{ Done = $false; Devices = $null; Error = $null })
    $token = $Script:AccessToken

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Ref',   $Script:DC_DevRef)
    $rs.SessionStateProxy.SetVariable('Token', $token)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        try {
            $devices = [System.Collections.Generic.List[object]]::new()
            $url = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices" +
                   "?`$filter=complianceState ne 'compliant'" +
                   "&`$select=id,deviceName,complianceState,userDisplayName,userPrincipalName,lastSyncDateTime,operatingSystem,osVersion" +
                   "&`$top=999"
            do {
                $resp = Invoke-RestMethod -Uri $url `
                    -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
                foreach ($d in $resp.value) { $devices.Add($d) }
                $url = $resp.'@odata.nextLink'
            } while ($url)
            $Ref['Devices'] = $devices.ToArray()
        } catch {
            $sc = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode.value__ } else { 0 }
            $Ref['Error'] = if ($sc -eq 401) { '401' } else { $_.Exception.Message }
        } finally { $Ref['Done'] = $true }
    })
    $ps.BeginInvoke() | Out-Null

    if ($Script:DC_DevTimer) { $Script:DC_DevTimer.Stop() }
    $Script:DC_DevTimer          = [System.Windows.Threading.DispatcherTimer]::new()
    $Script:DC_DevTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $Script:DC_DevTimer.Add_Tick({
        try {
            if (-not $Script:DC_DevRef['Done']) { return }
            $Script:DC_DevTimer.Stop()

            if ($Script:DC_DevRef['Error'] -eq '401') {
                Write-Log 'DevCompliance: 401 - session expired' 'ERROR'
                Write-DcLog 'Session expired - reconnect via the tenant selector.' '#EF4444'
                Set-MainStatus 'Session expired.' '#EF4444'
                return
            }
            if ($Script:DC_DevRef['Error']) {
                Write-Log "DevCompliance: device load failed - $($Script:DC_DevRef['Error'])" 'ERROR'
                Write-DcLog "Error: $($Script:DC_DevRef['Error'])" '#EF4444'
                Set-MainStatus 'Failed to load devices.' '#EF4444'
                return
            }

            $Script:DC_AllDevices = @($Script:DC_DevRef['Devices'] | Sort-Object { $_.deviceName })
            Update-DcFilter
            $Script:DC_UI.DevSearch.IsEnabled  = $true
            $Script:DC_UI.DevList.IsEnabled    = $true
            $Script:DC_UI.BtnRefresh.IsEnabled = $true
            $n = $Script:DC_AllDevices.Count
            Write-Log "DevCompliance: loaded $n non-compliant devices" 'INFO'
            Write-DcLog "Loaded $n non-compliant device$(if ($n -ne 1) { 's' })." '#22C55E'
            Set-MainStatus "$(if ($n -eq 0) { 'All devices are compliant.' } else { "$n non-compliant device$(if ($n -ne 1) { 's' }) found." })" $(if ($n -eq 0) { '#22C55E' } else { '#FBBF24' })
        } catch {
            Write-Log "DevCompliance device-load timer error: $_" 'ERROR'
        }
    })
    $Script:DC_DevTimer.Start()
}

function Update-DcFilter {
    $filter = $Script:DC_UI.DevSearch.Text.Trim()
    $Script:DC_UI.DevList.Items.Clear()
    $list = if ([string]::IsNullOrWhiteSpace($filter)) {
        $Script:DC_AllDevices
    } else {
        $Script:DC_AllDevices | Where-Object {
            $_.deviceName        -like "*$filter*" -or
            $_.userDisplayName   -like "*$filter*" -or
            $_.userPrincipalName -like "*$filter*"
        }
    }
    foreach ($d in $list) {
        $lbi     = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Tag = $d

        $sp  = [System.Windows.Controls.StackPanel]::new()
        $sp.Orientation = 'Vertical'
        $sp.Margin = '0,2,0,2'

        $row = [System.Windows.Controls.StackPanel]::new()
        $row.Orientation = 'Horizontal'

        $dot = [System.Windows.Shapes.Ellipse]::new()
        $dot.Width  = 6; $dot.Height = 6
        $dot.Fill   = Get-DcStateColor $d.complianceState
        $dot.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
        $dot.VerticalAlignment = 'Center'

        $nameTb = [System.Windows.Controls.TextBlock]::new()
        $nameTb.Text       = $d.deviceName
        $nameTb.Foreground = '#E2E2F0'
        $nameTb.FontWeight = 'SemiBold'

        $row.Children.Add($dot)   | Out-Null
        $row.Children.Add($nameTb)| Out-Null

        $userTb = [System.Windows.Controls.TextBlock]::new()
        $userTb.Text       = if ($d.userDisplayName) { $d.userDisplayName } else { 'No user' }
        $userTb.Foreground = '#7878A0'
        $userTb.FontSize   = 11

        $sp.Children.Add($row)   | Out-Null
        $sp.Children.Add($userTb)| Out-Null

        $lbi.Content = $sp
        $lbi.ToolTip = "$($d.userPrincipalName)  |  State: $(Get-DcStateLabel $d.complianceState)"
        [void]$Script:DC_UI.DevList.Items.Add($lbi)
    }
    $n = $list.Count
    $Script:DC_UI.DevCount.Text = if ($n -gt 0) { "$n device$(if ($n -ne 1) { 's' })" } else { 'No devices found' }
}

# ── Async compliance detail load ───────────────────────────────────────────────
function Start-DcDetailLoad {
    param([string]$DeviceId)
    if ($Script:DemoMode) { Start-DcDetailLoadDemo -DeviceId $DeviceId; return }

    $Script:DC_UI.IssuesGrid.ItemsSource      = $null
    $Script:DC_UI.IssuesPlaceholder.Text      = 'Loading compliance details...'
    $Script:DC_UI.IssuesPlaceholder.Visibility = 'Visible'
    $Script:DC_UI.IssuesGrid.Visibility        = 'Collapsed'
    Set-MainStatus 'Fetching compliance details...' '#7878A0'

    $Script:DC_PolRef = [hashtable]::Synchronized(@{ Done = $false; Rows = $null; Error = $null })
    $token = $Script:AccessToken

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Ref',      $Script:DC_PolRef)
    $rs.SessionStateProxy.SetVariable('Token',    $token)
    $rs.SessionStateProxy.SetVariable('DeviceId', $DeviceId)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        try {
            $rows = [System.Collections.Generic.List[object]]::new()

            # Fetch all policy states for this device
            $pUrl  = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$DeviceId/deviceCompliancePolicyStates"
            $pResp = Invoke-RestMethod -Uri $pUrl `
                -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop

            foreach ($policy in $pResp.value) {
                # Skip compliant and not-applicable policies
                if ($policy.state -in @('compliant', 'notApplicable')) { continue }

                # Fetch per-setting states for this policy
                $sUrl = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$DeviceId" +
                        "/deviceCompliancePolicyStates/$($policy.id)/settingStates"
                try {
                    $sResp = Invoke-RestMethod -Uri $sUrl `
                        -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop

                    $addedSetting = $false
                    foreach ($s in $sResp.value) {
                        if ($s.state -in @('compliant', 'notApplicable', 'notEvaluated', 'remediated')) { continue }
                        $rows.Add([PSCustomObject]@{
                            PolicyName = $policy.displayName
                            Setting    = $s.settingName
                            State      = $s.state
                            Detail     = $s.message
                        })
                        $addedSetting = $true
                    }
                    # If policy is non-compliant but all settings passed filter, add a policy-level row
                    if (-not $addedSetting) {
                        $rows.Add([PSCustomObject]@{
                            PolicyName = $policy.displayName
                            Setting    = '(policy level)'
                            State      = $policy.state
                            Detail     = ''
                        })
                    }
                } catch {
                    # Could not fetch setting states — add policy-level row
                    $rows.Add([PSCustomObject]@{
                        PolicyName = $policy.displayName
                        Setting    = '(details unavailable)'
                        State      = $policy.state
                        Detail     = $_.Exception.Message
                    })
                }
            }

            $Ref['Rows'] = $rows.ToArray()
        } catch {
            $sc = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode.value__ } else { 0 }
            $Ref['Error'] = if ($sc -eq 401) { '401' } else { $_.Exception.Message }
        } finally { $Ref['Done'] = $true }
    })
    $ps.BeginInvoke() | Out-Null

    if ($Script:DC_PolTimer) { $Script:DC_PolTimer.Stop() }
    $Script:DC_PolTimer          = [System.Windows.Threading.DispatcherTimer]::new()
    $Script:DC_PolTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $Script:DC_PolTimer.Add_Tick({
        try {
            if (-not $Script:DC_PolRef['Done']) { return }
            $Script:DC_PolTimer.Stop()

            if ($Script:DC_PolRef['Error'] -eq '401') {
                $Script:DC_UI.IssuesPlaceholder.Text = 'Session expired - reconnect via the tenant selector.'
                Set-MainStatus 'Session expired.' '#EF4444'
                return
            }
            if ($Script:DC_PolRef['Error']) {
                Write-Log "DevCompliance: detail load failed - $($Script:DC_PolRef['Error'])" 'ERROR'
                $Script:DC_UI.IssuesPlaceholder.Text = "Error: $($Script:DC_PolRef['Error'])"
                Set-MainStatus 'Failed to load compliance details.' '#EF4444'
                return
            }

            $rawRows = $Script:DC_PolRef['Rows']
            if (-not $rawRows -or $rawRows.Count -eq 0) {
                $Script:DC_UI.IssuesPlaceholder.Text = 'No failing settings found. The device may have recently become compliant.'
                Set-MainStatus 'No compliance issues found.' '#22C55E'
                return
            }

            # Create display rows with coloured state labels (must happen on UI thread)
            $displayRows = foreach ($r in $rawRows) {
                $brush = [System.Windows.Media.SolidColorBrush]::new(
                    [System.Windows.Media.ColorConverter]::ConvertFromString((Get-DcStateColor $r.State)))
                $brush.Freeze()
                [PSCustomObject]@{
                    PolicyName = $r.PolicyName
                    Setting    = $r.Setting
                    StateLabel = Get-DcStateLabel $r.State
                    StateColor = $brush
                    Detail     = $r.Detail
                }
            }

            $Script:DC_UI.IssuesGrid.ItemsSource       = [object[]]$displayRows
            $Script:DC_UI.IssuesPlaceholder.Visibility = 'Collapsed'
            $Script:DC_UI.IssuesGrid.Visibility        = 'Visible'
            $n = $rawRows.Count
            Write-DcLog "Loaded $n failing setting$(if ($n -ne 1) { 's' })." '#22C55E'
            Set-MainStatus "$n compliance issue$(if ($n -ne 1) { 's' }) found." '#FBBF24'
        } catch {
            Write-Log "DevCompliance detail-load timer error: $_" 'ERROR'
        }
    })
    $Script:DC_PolTimer.Start()
}

# ── XAML ───────────────────────────────────────────────────────────────────────
$Script:DcXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid.Resources>

    <SolidColorBrush x:Key="Bg"      Color="#12121C"/>
    <SolidColorBrush x:Key="Surface" Color="#1C1C2A"/>
    <SolidColorBrush x:Key="Card"    Color="#242436"/>
    <SolidColorBrush x:Key="Border"  Color="#3C3C5A"/>
    <SolidColorBrush x:Key="Accent"  Color="#6366F1"/>
    <SolidColorBrush x:Key="Text"    Color="#E2E2F0"/>
    <SolidColorBrush x:Key="TextDim" Color="#7878A0"/>
    <SolidColorBrush x:Key="Muted"   Color="#50507A"/>

    <Style TargetType="TextBox">
      <Setter Property="Background"               Value="#242436"/>
      <Setter Property="Foreground"               Value="#E2E2F0"/>
      <Setter Property="BorderBrush"              Value="#3C3C5A"/>
      <Setter Property="BorderThickness"          Value="1"/>
      <Setter Property="Padding"                  Value="8,4"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="4">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SmallBtn" TargetType="Button">
      <Setter Property="Foreground"      Value="White"/>
      <Setter Property="FontSize"        Value="11"/>
      <Setter Property="FontWeight"      Value="SemiBold"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor"          Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.82"/>
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

    <Style TargetType="ListBox">
      <Setter Property="Background"      Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding"         Value="0"/>
    </Style>

    <Style TargetType="ListBoxItem">
      <Setter Property="Foreground"                 Value="#E2E2F0"/>
      <Setter Property="Background"                 Value="Transparent"/>
      <Setter Property="Padding"                    Value="12,6"/>
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
      <Setter Property="CanUserSortColumns"       Value="True"/>
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

  </Grid.Resources>

  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="260" MinWidth="200"/>
    <ColumnDefinition Width="5"/>
    <ColumnDefinition Width="*"/>
  </Grid.ColumnDefinitions>

  <GridSplitter Grid.Column="1" Width="5" HorizontalAlignment="Stretch"
                Background="#3C3C5A" Cursor="SizeWE" ResizeBehavior="PreviousAndNext"/>

  <!-- Left sidebar -->
  <Border Grid.Column="0" Background="#1C1C2A">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="80"/>
      </Grid.RowDefinitions>

      <!-- Search + Refresh header -->
      <Border Grid.Row="0" Padding="12,10" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
        <StackPanel>
          <Grid Margin="0,0,0,8">
            <TextBlock Text="NON-COMPLIANT DEVICES" Foreground="#50507A" FontSize="10" FontWeight="Bold"
                       VerticalAlignment="Center"/>
            <Button x:Name="DcBtnRefresh" Content="Refresh" HorizontalAlignment="Right"
                    Style="{StaticResource SmallBtn}" Background="#3C3C5A"
                    Padding="8,4" IsEnabled="False"/>
          </Grid>
          <TextBox x:Name="DcDevSearch" Height="34" IsEnabled="False"/>
        </StackPanel>
      </Border>

      <!-- Device list -->
      <ListBox x:Name="DcDevList" Grid.Row="1" IsEnabled="False"
               ScrollViewer.HorizontalScrollBarVisibility="Disabled"
               VirtualizingPanel.IsVirtualizing="True"
               VirtualizingPanel.VirtualizationMode="Recycling"
               Margin="0,2,0,2"/>

      <!-- Count footer -->
      <Border Grid.Row="2" Padding="12,6" BorderBrush="#3C3C5A" BorderThickness="0,1,0,0">
        <TextBlock x:Name="DcDevCount" Foreground="#50507A" FontSize="11"/>
      </Border>

      <!-- Log box -->
      <Border Grid.Row="3" Background="#12121C" BorderBrush="#3C3C5A" BorderThickness="0,1,0,0">
        <RichTextBox x:Name="DcLogBox" Background="Transparent" BorderThickness="0"
                     IsReadOnly="True" Padding="8,4" FontSize="11" FontFamily="Consolas"
                     ScrollViewer.VerticalScrollBarVisibility="Auto"/>
      </Border>
    </Grid>
  </Border>

  <!-- Right panel -->
  <Grid Grid.Column="2" Background="#12121C">
    <!-- Placeholder -->
    <TextBlock x:Name="DcPlaceholder"
               Text="Select a device to view compliance details"
               Foreground="#50507A" FontSize="14"
               HorizontalAlignment="Center" VerticalAlignment="Center"/>

    <!-- Detail panel (hidden until device selected) -->
    <Grid x:Name="DcDetailPanel" Visibility="Collapsed">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <!-- Device info card -->
      <Border Grid.Row="0" Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1" Padding="20,14">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel Grid.Column="0">
            <TextBlock x:Name="DcDevName" Foreground="#E2E2F0" FontSize="16" FontWeight="Bold" Margin="0,0,0,4"/>
            <TextBlock x:Name="DcDevUser" Foreground="#7878A0" FontSize="12" Margin="0,0,0,2"/>
            <StackPanel Orientation="Horizontal" Margin="0,2,0,0">
              <TextBlock x:Name="DcDevOS"   Foreground="#50507A" FontSize="11"/>
              <TextBlock Text="  ·  "        Foreground="#50507A" FontSize="11"/>
              <TextBlock x:Name="DcDevSync" Foreground="#50507A" FontSize="11"/>
            </StackPanel>
          </StackPanel>
          <!-- State badge -->
          <Border Grid.Column="1" x:Name="DcStateBadge" CornerRadius="4" Padding="10,4" VerticalAlignment="Center">
            <TextBlock x:Name="DcStateLabel" FontSize="12" FontWeight="SemiBold" Foreground="White"/>
          </Border>
        </Grid>
      </Border>

      <!-- Issues header -->
      <Border Grid.Row="1" Background="#1A1A2C" Padding="20,8" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
        <TextBlock Text="COMPLIANCE ISSUES" Foreground="#50507A" FontSize="10" FontWeight="Bold"/>
      </Border>

      <!-- Issues grid / placeholder -->
      <Grid Grid.Row="2">
        <TextBlock x:Name="DcIssuesPlaceholder"
                   Foreground="#50507A" FontSize="13"
                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
        <DataGrid x:Name="DcIssuesGrid" Visibility="Collapsed">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Policy"   Binding="{Binding PolicyName}" Width="220"
                                ElementStyle="{StaticResource {x:Type TextBlock}}"/>
            <DataGridTextColumn Header="Setting"  Binding="{Binding Setting}"    Width="200"
                                ElementStyle="{StaticResource {x:Type TextBlock}}"/>
            <DataGridTemplateColumn Header="Status" Width="110" SortMemberPath="StateLabel">
              <DataGridTemplateColumn.CellTemplate>
                <DataTemplate>
                  <TextBlock Text="{Binding StateLabel}" Foreground="{Binding StateColor}"
                             FontWeight="SemiBold" Margin="12,0"/>
                </DataTemplate>
              </DataGridTemplateColumn.CellTemplate>
            </DataGridTemplateColumn>
            <DataGridTextColumn Header="Detail" Binding="{Binding Detail}" Width="*"
                                ElementStyle="{StaticResource {x:Type TextBlock}}"/>
          </DataGrid.Columns>
        </DataGrid>
      </Grid>

    </Grid>
  </Grid>

</Grid>
'@

# ── Initialize ─────────────────────────────────────────────────────────────────
function Initialize-DeviceComplianceTool {
    Write-Log 'DevCompliance: parsing XAML' 'DEBUG'
    $reader  = New-Object System.Xml.XmlNodeReader ([xml]$Script:DcXaml)
    $content = [System.Windows.Markup.XamlReader]::Load($reader)

    $Script:DC_UI = @{
        DevSearch      = $content.FindName('DcDevSearch')
        DevList        = $content.FindName('DcDevList')
        DevCount       = $content.FindName('DcDevCount')
        BtnRefresh     = $content.FindName('DcBtnRefresh')
        LogBox         = $content.FindName('DcLogBox')
        Placeholder    = $content.FindName('DcPlaceholder')
        DetailPanel    = $content.FindName('DcDetailPanel')
        DevName        = $content.FindName('DcDevName')
        DevUser        = $content.FindName('DcDevUser')
        DevOS          = $content.FindName('DcDevOS')
        DevSync        = $content.FindName('DcDevSync')
        StateBadge     = $content.FindName('DcStateBadge')
        StateLabel     = $content.FindName('DcStateLabel')
        IssuesGrid     = $content.FindName('DcIssuesGrid')
        IssuesPlaceholder = $content.FindName('DcIssuesPlaceholder')
    }

    # Search filter
    $Script:DC_UI.DevSearch.Add_TextChanged({
        try { Update-DcFilter }
        catch { Write-Log "DC DevSearch TextChanged error: $_" 'ERROR' }
    })

    # Refresh button
    $Script:DC_UI.BtnRefresh.Add_Click({
        try { Start-DcDeviceLoad }
        catch { Write-Log "DC BtnRefresh click error: $_" 'ERROR' }
    })

    # Device selected
    $Script:DC_UI.DevList.Add_SelectionChanged({
        try {
            $sel = $Script:DC_UI.DevList.SelectedItem
            if (-not $sel) { return }
            $d = $sel.Tag
            Write-Log "DevCompliance: selected '$($d.deviceName)'" 'DEBUG'

            # Populate info card
            $Script:DC_UI.DevName.Text = $d.deviceName
            $Script:DC_UI.DevUser.Text = if ($d.userDisplayName) {
                "$($d.userDisplayName)  ($($d.userPrincipalName))"
            } else { 'No assigned user' }
            $Script:DC_UI.DevOS.Text   = "$($d.operatingSystem) $($d.osVersion)".Trim()
            $Script:DC_UI.DevSync.Text = if ($d.lastSyncDateTime) {
                "Last sync: $(([datetime]$d.lastSyncDateTime).ToLocalTime().ToString('yyyy-MM-dd HH:mm'))"
            } else { 'Never synced' }

            $badgeBrush = [System.Windows.Media.SolidColorBrush]::new(
                [System.Windows.Media.ColorConverter]::ConvertFromString((Get-DcStateColor $d.complianceState)))
            $badgeBrush.Freeze()
            $Script:DC_UI.StateBadge.Background = $badgeBrush
            $Script:DC_UI.StateLabel.Text       = Get-DcStateLabel $d.complianceState

            $Script:DC_UI.Placeholder.Visibility  = 'Collapsed'
            $Script:DC_UI.DetailPanel.Visibility  = 'Visible'

            Start-DcDetailLoad -DeviceId $d.id
        } catch {
            Write-Log "DC DevList SelectionChanged error: $_" 'ERROR'
        }
    })

    # Register callbacks
    $Script:ConnectCallbacks.Add({ Start-DcDeviceLoad })
    $Script:ResetCallbacks.Add({
        $Script:DC_AllDevices = @()
        $Script:DC_UI.DevList.Items.Clear()
        $Script:DC_UI.DevSearch.Text       = ''
        $Script:DC_UI.DevSearch.IsEnabled  = $false
        $Script:DC_UI.DevList.IsEnabled    = $false
        $Script:DC_UI.BtnRefresh.IsEnabled = $false
        $Script:DC_UI.DevCount.Text        = ''
        $Script:DC_UI.Placeholder.Text     = 'Select a device to view compliance details'
        $Script:DC_UI.Placeholder.Visibility = 'Visible'
        $Script:DC_UI.DetailPanel.Visibility = 'Collapsed'
        $Script:DC_UI.IssuesGrid.ItemsSource = $null
        $Script:DC_UI.LogBox.Document.Blocks.Clear()
    })

    Write-Log 'DevCompliance: tool initialized' 'DEBUG'
    return $content
}
