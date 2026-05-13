<#
    Device Compliance tab for Art's Entra Toolbox.
    Flat single-table view: one row per failing compliance setting across all non-compliant devices.
    Dot-sourced by Start.ps1.
    Exposes Initialize-DeviceComplianceTool.
#>

$Script:DC_UI    = $null
$Script:DC_Ref   = $null
$Script:DC_Timer = $null

function Write-DcLog {
    param([string]$Msg, [string]$Color = 'TextDim')
    $ts   = Get-Date -Format 'HH:mm:ss'
    $para = New-Object System.Windows.Documents.Paragraph
    $run  = New-Object System.Windows.Documents.Run "[$ts]  $Msg"
    $run.Foreground = Get-ThemeHex $Color
    $para.Inlines.Add($run)
    $para.Margin = '0'
    $Script:DC_UI.LogBox.Document.Blocks.Add($para)
    $Script:DC_UI.LogBox.ScrollToEnd()
}

function Get-DcStateLabel([string]$state) {
    $s = ([string]$state).Trim()
    switch ($s) {
        'noncompliant'   { 'Non-compliant' }
        'nonCompliant'   { 'Non-compliant' }
        'error'          { 'Error' }
        'inGracePeriod'  { 'Grace period' }
        'conflict'       { 'Conflict' }
        'unknown'        { 'Unknown' }
        ''               { '(blank)' }
        default          { if ($s -match 'System\.|^@\{') { '(unknown)' } else { $s } }
    }
}

function Get-DcStateColor([string]$state) {
    $s = ([string]$state).Trim()
    switch ($s) {
        { $_ -in 'noncompliant','nonCompliant' } { (Get-ThemeHex 'Danger') }
        'error'         { (Get-ThemeHex 'Warning') }
        'inGracePeriod' { (Get-ThemeHex 'Warning') }
        'conflict'      { (Get-ThemeHex 'Accent') }
        default         { (Get-ThemeHex 'TextDim') }
    }
}

# ── Async flat load ─────────────────────────────────────────────────────────────
function Start-DcLoad {
    if ($Script:DemoMode) { Start-DcLoadDemo; return }

    if ($Script:DC_Timer) { $Script:DC_Timer.Stop() }
    $Script:DC_UI.IssuesGrid.ItemsSource        = $null
    $Script:DC_UI.IssuesGrid.Visibility         = 'Collapsed'
    $Script:DC_UI.Placeholder.Text              = 'Loading...'
    $Script:DC_UI.Placeholder.Visibility        = 'Visible'
    $Script:DC_UI.Status.Text                   = ''
    $Script:DC_UI.BtnRefresh.IsEnabled          = $false
    $Script:DC_UI.LogBox.Document.Blocks.Clear()
    Set-MainStatus 'Loading non-compliant devices...' 'TextDim'
    Write-DcLog 'Fetching non-compliant devices from Intune...' 'TextDim'

    $Script:DC_Ref = [hashtable]::Synchronized(@{
        Done = $false; Rows = $null; Error = $null; Progress = ''
    })
    $token = $Script:AccessToken

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Ref',   $Script:DC_Ref)
    $rs.SessionStateProxy.SetVariable('Token', $token)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        try {
            # ── Phase 1: fetch non-compliant device list ──
            $devices = [System.Collections.Generic.List[object]]::new()
            $url = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices" +
                   "?`$filter=complianceState ne 'compliant'" +
                   "&`$select=id,deviceName,complianceState,userDisplayName,operatingSystem,osVersion" +
                   "&`$top=999"
            do {
                $resp = Invoke-RestMethod -Uri $url `
                    -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
                foreach ($d in $resp.value) { $devices.Add($d) }
                $url = $resp.'@odata.nextLink'
            } while ($url)

            if ($devices.Count -eq 0) {
                $Ref['Rows'] = @()
                $Ref['Done'] = $true
                return
            }

            $Ref['Progress'] = "$($devices.Count) non-compliant device(s). Fetching policy states (up to 10 in parallel)..."

            # ── Phase 2: fetch all policy states in parallel ──
            $devicePolicies = $devices | ForEach-Object -ThrottleLimit 10 -Parallel {
                $d = $_
                try {
                    $pUrl = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($d.id)/deviceCompliancePolicyStates?`$select=id,displayName,state"
                    $pResp = Invoke-RestMethod -Uri $pUrl `
                        -Headers @{ Authorization = "Bearer $using:Token" } -Method GET -ErrorAction Stop
                    [PSCustomObject]@{
                        Device   = $d
                        Policies = $pResp.value
                        Error    = $null
                    }
                } catch {
                    [PSCustomObject]@{
                        Device   = $d
                        Policies = $null
                        Error    = $_.Exception.Message
                    }
                }
            }

            # ── Phase 3: collect non-compliant policy queries ──
            $rows = [System.Collections.Generic.List[object]]::new()
            $settingsQueries = [System.Collections.Generic.List[object]]::new()
            $totalPolicies = 0

            foreach ($dp in $devicePolicies) {
                if ($dp.Error) {
                    $user  = if ($dp.Device.userDisplayName) { $dp.Device.userDisplayName } else { '' }
                    $osStr = "$($dp.Device.operatingSystem) $($dp.Device.osVersion)".Trim()
                    $rows.Add([PSCustomObject]@{
                        DeviceName = $dp.Device.deviceName; User = $user; OS = $osStr
                        Policy = '(error fetching policies)'; Setting = ''
                        State = 'error'; Detail = $dp.Error
                    })
                    continue
                }
                if (-not $dp.Policies) { continue }
                foreach ($policy in $dp.Policies) {
                    if ([string]$policy.state -in @('compliant','notApplicable')) { continue }
                    $totalPolicies++
                    $settingsQueries.Add([PSCustomObject]@{ Device = $dp.Device; Policy = $policy })
                }
            }

            $Ref['Progress'] = "$totalPolicies failing policy(ies). Fetching setting details (up to 15 in parallel)..."

            # ── Phase 4: fetch all setting states in parallel ──
            $settingResults = if ($settingsQueries.Count -gt 0) {
                $settingsQueries | ForEach-Object -ThrottleLimit 15 -Parallel {
                    $sq = $_
                    try {
                        $sUrl = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($sq.Device.id)/deviceCompliancePolicyStates/$($sq.Policy.id)/settingStates"
                        $sResp = Invoke-RestMethod -Uri $sUrl `
                            -Headers @{ Authorization = "Bearer $using:Token" } -Method GET -ErrorAction Stop
                        [PSCustomObject]@{
                            Device   = $sq.Device
                            Policy   = $sq.Policy
                            Settings = $sResp.value
                            Error    = $null
                        }
                    } catch {
                        [PSCustomObject]@{
                            Device   = $sq.Device
                            Policy   = $sq.Policy
                            Settings = $null
                            Error    = $_.Exception.Message
                        }
                    }
                }
            } else { @() }

            # ── Phase 5: build flat rows ──
            foreach ($sr in $settingResults) {
                $d      = $sr.Device
                $policy = $sr.Policy
                $user   = if ($d.userDisplayName) { $d.userDisplayName } else { '' }
                $osStr  = "$($d.operatingSystem) $($d.osVersion)".Trim()

                if ($sr.Error) {
                    $rows.Add([PSCustomObject]@{
                        DeviceName = $d.deviceName; User = $user; OS = $osStr
                        Policy = [string]$policy.displayName; Setting = '(details unavailable)'
                        State = [string]$policy.state; Detail = $sr.Error
                    })
                    continue
                }

                $addedSetting = $false
                if ($sr.Settings) {
                    foreach ($s in $sr.Settings) {
                        if ([string]$s.state -in @('compliant','notApplicable','notEvaluated','remediated')) { continue }
                        $rows.Add([PSCustomObject]@{
                            DeviceName = $d.deviceName; User = $user; OS = $osStr
                            Policy = [string]$policy.displayName; Setting = [string]$s.settingName
                            State = [string]$s.state; Detail = if ($s.message) { [string]$s.message } else { '' }
                        })
                        $addedSetting = $true
                    }
                }
                if (-not $addedSetting) {
                    $rows.Add([PSCustomObject]@{
                        DeviceName = $d.deviceName; User = $user; OS = $osStr
                        Policy = [string]$policy.displayName; Setting = '(policy level)'
                        State = [string]$policy.state; Detail = ''
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

    $Script:DC_Timer = [System.Windows.Threading.DispatcherTimer]::new()
    $Script:DC_Timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $Script:DC_Timer.Add_Tick({
        try {
            $prog = $Script:DC_Ref['Progress']
            if ($prog) { $Script:DC_UI.Status.Text = $prog }

            if (-not $Script:DC_Ref['Done']) { return }
            $Script:DC_Timer.Stop()
            $Script:DC_UI.Status.Text      = ''
            $Script:DC_UI.BtnRefresh.IsEnabled = $true

            if ($Script:DC_Ref['Error'] -eq '401') {
                $Script:DC_UI.Placeholder.Text = 'Session expired — reconnect via the tenant selector.'
                Write-DcLog 'Session expired.' 'Danger'
                Set-MainStatus 'Session expired.' 'Danger'
                return
            }
            if ($Script:DC_Ref['Error']) {
                Write-Log "DevCompliance: load failed - $($Script:DC_Ref['Error'])" 'ERROR'
                $Script:DC_UI.Placeholder.Text = "Error: $($Script:DC_Ref['Error'])"
                Write-DcLog "Error: $($Script:DC_Ref['Error'])" 'Danger'
                Set-MainStatus 'Failed to load compliance data.' 'Danger'
                return
            }

            $rawRows = $Script:DC_Ref['Rows']
            if (-not $rawRows -or $rawRows.Count -eq 0) {
                $Script:DC_UI.Placeholder.Text = 'All managed devices are compliant.'
                Write-DcLog 'No non-compliant devices found.' 'Success'
                Set-MainStatus 'All devices are compliant.' 'Success'
                return
            }

            $displayRows = foreach ($r in $rawRows) {
                $brush = [System.Windows.Media.SolidColorBrush]::new(
                    [System.Windows.Media.ColorConverter]::ConvertFromString((Get-DcStateColor $r.State)))
                $brush.Freeze()
                [PSCustomObject]@{
                    DeviceName = $r.DeviceName; User = $r.User; OS = $r.OS
                    Policy = $r.Policy; Setting = $r.Setting
                    StateLabel = Get-DcStateLabel $r.State; StateColor = $brush; Detail = $r.Detail
                }
            }

            $Script:DC_UI.IssuesGrid.ItemsSource      = [object[]]$displayRows
            $Script:DC_UI.Placeholder.Visibility      = 'Collapsed'
            $Script:DC_UI.IssuesGrid.Visibility       = 'Visible'
            $n  = $rawRows.Count
            $nd = ($rawRows | Select-Object -ExpandProperty DeviceName -Unique).Count
            Write-Log "DevCompliance: $n issue(s) across $nd device(s)" 'INFO'
            Write-DcLog "Found $n issue$(if ($n -ne 1) {'s'}) across $nd device$(if ($nd -ne 1) {'s'})." 'Success'
            Set-MainStatus "$n compliance issue$(if ($n -ne 1) {'s'}) across $nd device$(if ($nd -ne 1) {'s'})." 'Warning'
        } catch {
            Write-Log "DevCompliance load timer error: $_" 'ERROR'
        }
    })
    $Script:DC_Timer.Start()
}

# ── XAML ───────────────────────────────────────────────────────────────────────
$Script:DcXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid.Resources>

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

  <Grid.RowDefinitions>
    <RowDefinition Height="Auto"/>
    <RowDefinition Height="*"/>
    <RowDefinition Height="80"/>
  </Grid.RowDefinitions>

  <!-- Header bar -->
  <Border Grid.Row="0" Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1" Padding="16,10">
    <Grid>
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <TextBlock Text="DEVICE COMPLIANCE" Foreground="#50507A" FontSize="10" FontWeight="Bold"
                   VerticalAlignment="Center"/>
        <TextBlock x:Name="DcStatus" Foreground="#7878A0" FontSize="11" Margin="12,0,0,0"
                   VerticalAlignment="Center"/>
      </StackPanel>
      <Button x:Name="DcBtnRefresh" Content="Refresh" HorizontalAlignment="Right"
              Style="{StaticResource SmallBtn}" Background="#3C3C5A" Padding="10,5" IsEnabled="False"/>
    </Grid>
  </Border>

  <!-- Content -->
  <Grid Grid.Row="1" Background="#12121C">
    <TextBlock x:Name="DcPlaceholder"
               Text="Select a tenant to view compliance data."
               Foreground="#50507A" FontSize="14"
               HorizontalAlignment="Center" VerticalAlignment="Center"/>
    <DataGrid x:Name="DcIssuesGrid" Visibility="Collapsed">
      <DataGrid.Columns>
        <DataGridTextColumn Header="Device"   Binding="{Binding DeviceName}" Width="150"/>
        <DataGridTextColumn Header="User"     Binding="{Binding User}"       Width="150"/>
        <DataGridTextColumn Header="OS"       Binding="{Binding OS}"         Width="130"/>
        <DataGridTextColumn Header="Policy"   Binding="{Binding Policy}"     Width="200"/>
        <DataGridTextColumn Header="Setting"  Binding="{Binding Setting}"    Width="180"/>
        <DataGridTemplateColumn Header="Status" Width="110" SortMemberPath="StateLabel">
          <DataGridTemplateColumn.CellTemplate>
            <DataTemplate>
              <TextBlock Text="{Binding StateLabel}" Foreground="{Binding StateColor}"
                         FontWeight="SemiBold" Margin="12,0"/>
            </DataTemplate>
          </DataGridTemplateColumn.CellTemplate>
        </DataGridTemplateColumn>
        <DataGridTextColumn Header="Detail"   Binding="{Binding Detail}"     Width="*"/>
      </DataGrid.Columns>
    </DataGrid>
  </Grid>

  <!-- Log box -->
  <Border Grid.Row="2" Background="#12121C" BorderBrush="#3C3C5A" BorderThickness="0,1,0,0">
    <RichTextBox x:Name="DcLogBox" Background="Transparent" BorderThickness="0"
                 IsReadOnly="True" Padding="8,4" FontSize="11" FontFamily="Consolas"
                 ScrollViewer.VerticalScrollBarVisibility="Auto"/>
  </Border>

</Grid>
'@

# ── Initialize ─────────────────────────────────────────────────────────────────
function Initialize-DeviceComplianceTool {
    Write-Log 'DevCompliance: parsing XAML' 'DEBUG'
    $reader  = New-Object System.Xml.XmlNodeReader ([xml](Invoke-ThemeXaml $Script:DcXaml))
    $content = [System.Windows.Markup.XamlReader]::Load($reader)

    $Script:DC_UI = @{
        Status     = $content.FindName('DcStatus')
        BtnRefresh = $content.FindName('DcBtnRefresh')
        Placeholder= $content.FindName('DcPlaceholder')
        IssuesGrid = $content.FindName('DcIssuesGrid')
        LogBox     = $content.FindName('DcLogBox')
    }

    $Script:DC_UI.BtnRefresh.Add_Click({
        try { Start-DcLoad }
        catch { Write-Log "DC BtnRefresh click error: $_" 'ERROR' }
    })

    $Script:ConnectCallbacks.Add({ Start-DcLoad })
    $Script:ResetCallbacks.Add({
        if ($Script:DC_Timer) { $Script:DC_Timer.Stop() }
        $Script:DC_UI.IssuesGrid.ItemsSource     = $null
        $Script:DC_UI.IssuesGrid.Visibility      = 'Collapsed'
        $Script:DC_UI.Placeholder.Text           = 'Select a tenant to view compliance data.'
        $Script:DC_UI.Placeholder.Visibility     = 'Visible'
        $Script:DC_UI.Status.Text                = ''
        $Script:DC_UI.BtnRefresh.IsEnabled       = $false
        $Script:DC_UI.LogBox.Document.Blocks.Clear()
    })

    Write-Log 'DevCompliance: tool initialized' 'DEBUG'
    return $content
}
