<#
    Device Compliance tool for Art's Entra Toolbox.
    Dot-sourced by Start.ps1.
    Exposes Initialize-DeviceComplianceTool.

    Shows all Intune-managed devices with their compliance state. Selecting a
    non-compliant device loads and displays which policies are failing and why.
#>

$Script:DC_UI            = $null
$Script:DC_AllDevices    = @()
$Script:DC_LoadTimer     = $null
$Script:DC_DetailTimer   = $null

function Write-DcLog {
    param([string]$Msg, [string]$Color = 'TextDim')
    Write-AppLog $Msg $Color
}

function Get-DcFriendlyState([string]$State) {
    switch ($State) {
        'compliant'      { return 'Compliant' }
        'noncompliant'   { return 'Non-Compliant' }
        'inGracePeriod'  { return 'Grace Period' }
        'unknown'        { return 'Unknown' }
        'notApplicable'  { return 'Not Applicable' }
        'error'          { return 'Error' }
        'conflict'       { return 'Conflict' }
        default          { return $State }
    }
}

function Start-DcLoad {
    if ($Script:DemoMode) { Start-DcLoadDemo; return }

    $Script:DC_UI.RefreshBtn.IsEnabled    = $false
    $Script:DC_UI.FilterCombo.IsEnabled   = $false
    $Script:DC_UI.Grid.ItemsSource        = $null
    $Script:DC_UI.DetailPanel.Visibility  = 'Collapsed'
    $Script:DC_UI.SummaryCompliant.Text   = '—'
    $Script:DC_UI.SummaryNonComp.Text     = '—'
    $Script:DC_UI.SummaryOther.Text       = '—'
    $Script:DC_UI.Placeholder.Visibility  = 'Visible'
    $Script:DC_UI.Placeholder.Text        = 'Loading devices...'
    Write-DcLog 'Loading Intune managed devices...' 'TextDim'
    Set-MainStatus 'Loading devices...' 'TextDim'

    if ($Script:DC_LoadTimer) { $Script:DC_LoadTimer.Stop() }
    $Script:DC_LoadTimer = Start-AsyncWork -RefSeed @{ Devices = $null } -Script {
        $devices = [System.Collections.Generic.List[object]]::new()
        $url = 'https://graph.microsoft.com/beta/deviceManagement/managedDevices?$select=id,deviceName,complianceState,operatingSystem,osVersion,userDisplayName&$top=999'
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
            $Script:DC_UI.RefreshBtn.IsEnabled = $true
            if ($ref['Error'] -eq '401') {
                Write-DcLog 'Session expired — reconnect.' 'Danger'
                Set-MainStatus 'Session expired.' 'Danger'
                $Script:DC_UI.Placeholder.Text = 'Session expired — reconnect.'
                return
            }
            if ($ref['Error']) {
                Write-DcLog "Error loading devices: $($ref['Error'])" 'Danger'
                Set-MainStatus 'Failed to load devices.' 'Danger'
                $Script:DC_UI.Placeholder.Text = "Error: $($ref['Error'])"
                return
            }

            $Script:DC_AllDevices = @($ref['Devices'] | Sort-Object { $_.deviceName })
            $n = $Script:DC_AllDevices.Count
            Write-DcLog "Loaded $n devices." 'Success'
            Set-MainStatus "Loaded $n devices." 'Success'
            Update-DcGrid
            $Script:DC_UI.RefreshBtn.IsEnabled  = $true
            $Script:DC_UI.FilterCombo.IsEnabled = $true
        } catch {
            Write-Log "DC load timer error: $_" 'ERROR'
        }
    }
}

function Update-DcGrid {
    $filterIdx = $Script:DC_UI.FilterCombo.SelectedIndex
    $rows = [System.Collections.Generic.List[PSObject]]::new()

    $nCompliant = 0; $nNonComp = 0; $nOther = 0

    foreach ($d in $Script:DC_AllDevices) {
        switch ($d.complianceState) {
            'compliant'    { $nCompliant++ }
            'noncompliant' { $nNonComp++ }
            default        { $nOther++ }
        }
        $include = switch ($filterIdx) {
            0 { $true }                                         # All
            1 { $d.complianceState -eq 'noncompliant' }        # Non-Compliant
            2 { $d.complianceState -eq 'compliant' }           # Compliant
            3 { $d.complianceState -notin @('compliant','noncompliant') } # Other
            default { $true }
        }
        if (-not $include) { continue }

        $os = "$($d.operatingSystem)$(if ($d.osVersion) { " $($d.osVersion)" })"
        $rows.Add([PSCustomObject]@{
            DeviceName      = $d.deviceName
            UserDisplayName = if ($d.userDisplayName) { $d.userDisplayName } else { '(none)' }
            OS              = $os
            Status          = Get-DcFriendlyState $d.complianceState
            ComplianceState = $d.complianceState
            DeviceId        = $d.id
        })
    }

    $Script:DC_UI.SummaryCompliant.Text = "$nCompliant"
    $Script:DC_UI.SummaryNonComp.Text   = "$nNonComp"
    $Script:DC_UI.SummaryOther.Text     = "$nOther"

    if ($rows.Count -eq 0) {
        $Script:DC_UI.Grid.ItemsSource       = $null
        $Script:DC_UI.Placeholder.Text       = 'No devices match the current filter.'
        $Script:DC_UI.Placeholder.Visibility = 'Visible'
    } else {
        $Script:DC_UI.Grid.ItemsSource       = $rows
        $Script:DC_UI.Placeholder.Visibility = 'Collapsed'
    }
    $Script:DC_UI.DetailPanel.Visibility = 'Collapsed'
}

function Start-DcLoadPolicyStates {
    param([string]$DeviceId, [string]$DeviceName)

    $Script:DC_UI.DetailHeader.Text        = "Loading compliance details for $DeviceName..."
    $Script:DC_UI.PolicyList.Items.Clear()
    $Script:DC_UI.DetailPanel.Visibility   = 'Visible'

    if ($Script:DC_DetailTimer) { $Script:DC_DetailTimer.Stop() }
    $Script:DC_DetailTimer = Start-AsyncWork `
        -Vars    @{ DeviceId = $DeviceId } `
        -RefSeed @{ RequestedId = $DeviceId; Policies = $null } `
        -Script {
            $Ref['Policies'] = @(Get-EtbGraphCollection `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$DeviceId/deviceCompliancePolicyStates?`$select=displayName,state,settingCount" `
                -Headers @{ Authorization = "Bearer $Token" })
        } -OnComplete {
            param($ref)
            if ($Script:DC_UI.Grid.SelectedItem.DeviceId -ne $ref.RequestedId) { return }
            try {
                if ($ref['Error']) {
                    $Script:DC_UI.DetailHeader.Text = "Could not load compliance details: $($ref['Error'])"
                    return
                }

                $policies = @($ref['Policies'] | Where-Object { $_.state -ne 'compliant' -and $_.state -ne 'notApplicable' })
                if ($policies.Count -eq 0) {
                    $Script:DC_UI.DetailHeader.Text = 'No failing policies found (may be in grace period).'
                    return
                }

                $Script:DC_UI.DetailHeader.Text = "$($policies.Count) failing polic$(if ($policies.Count -ne 1) { 'ies' } else { 'y' }):"
                $Script:DC_UI.PolicyList.Items.Clear()
                foreach ($p in $policies) {
                    $lbi         = [System.Windows.Controls.ListBoxItem]::new()
                    $stateLabel  = Get-DcFriendlyState $p.state
                    $settings    = if ($p.settingCount -gt 0) { " ($($p.settingCount) setting$(if ($p.settingCount -ne 1) { 's' }))" } else { '' }
                    $lbi.Content = "$($p.displayName) — $stateLabel$settings"
                    $lbi.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#EF4444')
                    [void]$Script:DC_UI.PolicyList.Items.Add($lbi)
                }
            } catch {
                Write-Log "DC detail timer error: $_" 'ERROR'
            }
        }
}

function Start-DcLoadDemo {
    $Script:DC_AllDevices = @(
        [PSCustomObject]@{ id='dev-1'; deviceName='LAPTOP-Y11-01'; complianceState='compliant';    operatingSystem='Windows'; osVersion='10.0.19045'; userDisplayName='Tyler Hughes' }
        [PSCustomObject]@{ id='dev-2'; deviceName='LAPTOP-Y10-04'; complianceState='noncompliant'; operatingSystem='Windows'; osVersion='10.0.22621'; userDisplayName='Jake Morrison' }
        [PSCustomObject]@{ id='dev-3'; deviceName='IPAD-Y10-01';   complianceState='compliant';    operatingSystem='iOS';     osVersion='17.2';      userDisplayName='Amara Osei' }
        [PSCustomObject]@{ id='dev-4'; deviceName='LAPTOP-STAFF-1';complianceState='noncompliant'; operatingSystem='Windows'; osVersion='10.0.19044'; userDisplayName='Ms. Thompson' }
        [PSCustomObject]@{ id='dev-5'; deviceName='IPAD-Y12-02';   complianceState='unknown';      operatingSystem='iOS';     osVersion='16.7';      userDisplayName='James Carter' }
        [PSCustomObject]@{ id='dev-6'; deviceName='LAPTOP-Y12-03'; complianceState='compliant';    operatingSystem='Windows'; osVersion='10.0.22621'; userDisplayName='Maya Ramachandran' }
        [PSCustomObject]@{ id='dev-7'; deviceName='LAPTOP-Y11-07'; complianceState='inGracePeriod';operatingSystem='Windows'; osVersion='10.0.19045'; userDisplayName='Ethan Nguyen' }
    )
    Update-DcGrid
    $Script:DC_UI.RefreshBtn.IsEnabled  = $true
    $Script:DC_UI.FilterCombo.IsEnabled = $true
    Write-DcLog 'Demo: loaded 7 devices.' 'Success'
}

$Script:DcXaml = @'
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

    <Style x:Key="FlatBtn" TargetType="Button">
      <Setter Property="Foreground"      Value="White"/>
      <Setter Property="FontWeight"      Value="SemiBold"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor"          Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    CornerRadius="5" Padding="{TemplateBinding Padding}">
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

    <Style TargetType="ComboBox">
      <Setter Property="Background"        Value="#242436"/>
      <Setter Property="Foreground"        Value="#E2E2F0"/>
      <Setter Property="BorderBrush"       Value="#3C3C5A"/>
      <Setter Property="BorderThickness"   Value="1"/>
      <Setter Property="Height"            Value="30"/>
      <Setter Property="Padding"           Value="8,0"/>
      <Setter Property="MaxDropDownHeight" Value="180"/>
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
                                IsHitTestVisible="False"/>
              <Path Data="M0,0 L4,4 L8,0 Z" Fill="#7878A0"
                    HorizontalAlignment="Right" VerticalAlignment="Center"
                    Margin="0,0,10,0" IsHitTestVisible="False"/>
              <ToggleButton Focusable="False" Cursor="Hand"
                            IsChecked="{Binding IsDropDownOpen,
                                        RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Rectangle Fill="Transparent"/>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <Popup AllowsTransparency="True"
                     IsOpen="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}}"
                     Placement="Bottom" PopupAnimation="Slide">
                <Border Background="#242436" BorderBrush="#3C3C5A" BorderThickness="1" CornerRadius="0,0,4,4"
                        MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <ScrollViewer><ItemsPresenter/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#E2E2F0"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding"    Value="10,6"/>
      <Setter Property="Cursor"     Value="Hand"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#2E2E48"/>
        </Trigger>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#6366F1"/>
          <Setter Property="Foreground" Value="White"/>
        </Trigger>
      </Style.Triggers>
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

    <Style TargetType="ListBox">
      <Setter Property="Background"      Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding"         Value="0"/>
    </Style>

    <Style TargetType="ListBoxItem">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding"    Value="0,3"/>
    </Style>

  </Grid.Resources>

  <Grid.RowDefinitions>
    <RowDefinition Height="Auto"/>
    <RowDefinition Height="*"/>
    <RowDefinition Height="Auto"/>
  </Grid.RowDefinitions>

  <!-- Top bar: summary + filter + refresh -->
  <Border Grid.Row="0" Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1" Padding="16,10">
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>

      <!-- Summary cards -->
      <Border Grid.Column="0" Background="#0D2218" CornerRadius="5" Padding="12,6" Margin="0,0,8,0">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock x:Name="DcSummaryCompliant" Text="—" Foreground="#22C55E"
                     FontSize="16" FontWeight="Bold" Margin="0,0,6,0"/>
          <TextBlock Text="Compliant" Foreground="#22C55E" FontSize="11" VerticalAlignment="Center"/>
        </StackPanel>
      </Border>

      <Border Grid.Column="1" Background="#200E0E" CornerRadius="5" Padding="12,6" Margin="0,0,8,0">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock x:Name="DcSummaryNonComp" Text="—" Foreground="#EF4444"
                     FontSize="16" FontWeight="Bold" Margin="0,0,6,0"/>
          <TextBlock Text="Non-Compliant" Foreground="#EF4444" FontSize="11" VerticalAlignment="Center"/>
        </StackPanel>
      </Border>

      <Border Grid.Column="2" Background="#242436" CornerRadius="5" Padding="12,6" Margin="0,0,16,0">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock x:Name="DcSummaryOther" Text="—" Foreground="#7878A0"
                     FontSize="16" FontWeight="Bold" Margin="0,0,6,0"/>
          <TextBlock Text="Other" Foreground="#7878A0" FontSize="11" VerticalAlignment="Center"/>
        </StackPanel>
      </Border>

      <!-- Filter -->
      <StackPanel Grid.Column="4" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,8,0">
        <TextBlock Text="Show:" Foreground="#7878A0" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
        <ComboBox x:Name="DcFilterCombo" Width="150" IsEnabled="False"/>
      </StackPanel>

      <!-- Refresh -->
      <Button x:Name="DcRefreshBtn" Grid.Column="5" Content="Refresh"
              Style="{StaticResource FlatBtn}" Background="#3C3C5A"
              Padding="12,6" IsEnabled="False"/>
    </Grid>
  </Border>

  <!-- Device grid -->
  <Grid Grid.Row="1">
    <TextBlock x:Name="DcPlaceholder" Text="Select a tenant to load devices."
               Foreground="#50507A" FontStyle="Italic" FontSize="13"
               HorizontalAlignment="Center" VerticalAlignment="Center"
               Visibility="Visible"/>
    <DataGrid x:Name="DcGrid" CanUserSortColumns="True"
              VirtualizingPanel.IsVirtualizing="True"
              VirtualizingPanel.VirtualizationMode="Recycling">
      <DataGrid.RowStyle>
        <Style TargetType="DataGridRow">
          <Setter Property="Background" Value="Transparent"/>
          <Style.Triggers>
            <DataTrigger Binding="{Binding ComplianceState}" Value="noncompliant">
              <Setter Property="Background" Value="#180808"/>
            </DataTrigger>
            <DataTrigger Binding="{Binding ComplianceState}" Value="error">
              <Setter Property="Background" Value="#180808"/>
            </DataTrigger>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter Property="Background" Value="#1E1E38"/>
            </Trigger>
            <Trigger Property="IsSelected" Value="True">
              <Setter Property="Background" Value="#2A2A50"/>
            </Trigger>
          </Style.Triggers>
        </Style>
      </DataGrid.RowStyle>
      <DataGrid.Columns>
        <DataGridTextColumn Header="Device Name" Binding="{Binding DeviceName}"      Width="*"   MinWidth="120"/>
        <DataGridTextColumn Header="User"        Binding="{Binding UserDisplayName}" Width="*"   MinWidth="120"/>
        <DataGridTextColumn Header="OS"          Binding="{Binding OS}"              Width="190" MinWidth="100"/>
        <DataGridTextColumn Header="Status"      Binding="{Binding Status}"          Width="130" MinWidth="100"/>
      </DataGrid.Columns>
    </DataGrid>
  </Grid>

  <!-- Detail panel: failing policies -->
  <Border x:Name="DcDetailPanel" Grid.Row="2" Background="#1C1C2A"
          BorderBrush="#3C3C5A" BorderThickness="0,1,0,0"
          Padding="16,10" Visibility="Collapsed" MaxHeight="180">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <TextBlock x:Name="DcDetailHeader" Grid.Row="0"
                 Foreground="#7878A0" FontSize="11" FontWeight="SemiBold" Margin="0,0,0,6"/>
      <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
        <ListBox x:Name="DcPolicyList" ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
      </ScrollViewer>
    </Grid>
  </Border>

</Grid>
'@

function Initialize-DeviceComplianceTool {
    $reader  = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new((Invoke-ThemeXaml $Script:DcXaml)))
    $content = [System.Windows.Markup.XamlReader]::Load($reader)

    $Script:DC_UI = @{
        Grid             = $content.FindName('DcGrid')
        Placeholder      = $content.FindName('DcPlaceholder')
        FilterCombo      = $content.FindName('DcFilterCombo')
        RefreshBtn       = $content.FindName('DcRefreshBtn')
        SummaryCompliant = $content.FindName('DcSummaryCompliant')
        SummaryNonComp   = $content.FindName('DcSummaryNonComp')
        SummaryOther     = $content.FindName('DcSummaryOther')
        DetailPanel      = $content.FindName('DcDetailPanel')
        DetailHeader     = $content.FindName('DcDetailHeader')
        PolicyList       = $content.FindName('DcPolicyList')
    }

    'All', 'Non-Compliant', 'Compliant', 'Other' | ForEach-Object {
        [void]$Script:DC_UI.FilterCombo.Items.Add($_)
    }
    $Script:DC_UI.FilterCombo.SelectedIndex = 0

    $Script:DC_UI.FilterCombo.Add_SelectionChanged({
        try {
            if ($Script:DC_AllDevices.Count -gt 0) { Update-DcGrid }
        } catch { Write-Log "DC FilterCombo error: $_" 'ERROR' }
    })

    $Script:DC_UI.RefreshBtn.Add_Click({
        try { Start-DcLoad }
        catch { Write-Log "DC RefreshBtn error: $_" 'ERROR' }
    })

    $Script:DC_UI.Grid.Add_SelectionChanged({
        try {
            $row = $Script:DC_UI.Grid.SelectedItem
            if ($null -eq $row) {
                $Script:DC_UI.DetailPanel.Visibility = 'Collapsed'
                return
            }
            if ($row.ComplianceState -in @('noncompliant', 'error', 'conflict', 'inGracePeriod')) {
                Start-DcLoadPolicyStates -DeviceId $row.DeviceId -DeviceName $row.DeviceName
            } else {
                $Script:DC_UI.DetailPanel.Visibility = 'Collapsed'
            }
        } catch { Write-Log "DC Grid SelectionChanged error: $_" 'ERROR' }
    })

    Register-ConnectCallback 'Start-DcLoad'
    $Script:ResetCallbacks.Add({
        $Script:DC_AllDevices = @()
        if ($Script:DC_LoadTimer)   { $Script:DC_LoadTimer.Stop() }
        if ($Script:DC_DetailTimer) { $Script:DC_DetailTimer.Stop() }
        $Script:DC_UI.Grid.ItemsSource        = $null
        $Script:DC_UI.Placeholder.Text        = 'Select a tenant to load devices.'
        $Script:DC_UI.Placeholder.Visibility  = 'Visible'
        $Script:DC_UI.FilterCombo.IsEnabled   = $false
        $Script:DC_UI.FilterCombo.SelectedIndex = 0
        $Script:DC_UI.RefreshBtn.IsEnabled    = $false
        $Script:DC_UI.SummaryCompliant.Text   = '—'
        $Script:DC_UI.SummaryNonComp.Text     = '—'
        $Script:DC_UI.SummaryOther.Text       = '—'
        $Script:DC_UI.DetailPanel.Visibility  = 'Collapsed'
        $Script:DC_UI.PolicyList.Items.Clear()
    })

    Write-DcLog 'Device Compliance ready. Select a tenant to begin.' 'Muted'
    return $content
}
