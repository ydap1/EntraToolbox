<#
    Sign-In Log Viewer tab for Art's Entra Toolbox.
    Dot-sourced by Start.ps1.
    Exposes Initialize-SignInLogsTool.

    Shows the last 50 sign-ins for a selected user. Requires AuditLog.Read.All.
#>

# ── Script-level state ─────────────────────────────────────────────────────────
$Script:SL_UI        = $null
$Script:SL_AllUsers  = @()
$Script:SL_LogsTimer = $null

# ── Log helper ─────────────────────────────────────────────────────────────────
function Write-SlLog {
    param([string]$Msg, [string]$Color = 'TextDim')
    Write-AppLog $Msg $Color
}

# ── Async user load ────────────────────────────────────────────────────────────
function Start-SlUserLoad {
    if ($Script:DemoMode) { Start-SlUserLoadDemo; return }
    $Script:SL_UI.UserSearch.IsEnabled = $false
    $Script:SL_UI.UserList.IsEnabled   = $false
    Clear-EtbList $Script:SL_UI.UserList
    Set-MainStatus 'Loading users...' 'TextDim'
    Write-SlLog 'Fetching users from Entra ID...' 'TextDim'

    Request-EtbUsers -OnReady 'Complete-SlUserLoad'
}

function Complete-SlUserLoad {
    try {
        if ($Script:UserCache.Error -eq '401') {
            Write-Log 'SignInLogs: user load 401 - session expired' 'ERROR'
            Write-SlLog 'Session expired - reconnect via the tenant selector.' 'Danger'
            Set-MainStatus 'Session expired.' 'Danger'
            return
        }
        if ($Script:UserCache.Error) {
            Write-Log "SignInLogs: user load failed - $($Script:UserCache.Error)" 'ERROR'
            Write-SlLog "Error loading users: $($Script:UserCache.Error)" 'Danger'
            Set-MainStatus 'Failed to load users.' 'Danger'
            return
        }

        $Script:SL_AllUsers = @($Script:UserCache.Users |
            Where-Object { $_.accountEnabled } | Sort-Object { $_.displayName })
        Update-SlUserFilter
        $Script:SL_UI.UserSearch.IsEnabled = $true
        $Script:SL_UI.UserList.IsEnabled   = $true
        $n = $Script:SL_AllUsers.Count
        Write-Log "SignInLogs: loaded $n users" 'INFO'
        Write-SlLog "Loaded $n users." 'Success'
        Set-MainStatus "Loaded $n users." 'Success'
    } catch {
        Write-Log "SignInLogs user-load error: $_" 'ERROR'
    }
}

function Update-SlUserFilter {
    $filter = $Script:SL_UI.UserSearch.Text.Trim()
    Clear-EtbList $Script:SL_UI.UserList
    $list = if ([string]::IsNullOrWhiteSpace($filter)) {
        $Script:SL_AllUsers
    } else {
        $Script:SL_AllUsers | Where-Object {
            $_.displayName       -like "*$filter*" -or
            $_.userPrincipalName -like "*$filter*"
        }
    }
    Set-EtbListItems -List $Script:SL_UI.UserList -Items @(foreach ($u in $list) {
        [pscustomobject]@{ Content = $u.displayName; Tag = $u; ToolTip = $u.userPrincipalName }
    })
}

# ── Async sign-in log load ─────────────────────────────────────────────────────
function Start-SlLogsLoad {
    param([string]$UserId)
    if ($Script:DemoMode) { Start-SlLogsLoadDemo -UserId $UserId; return }

    $Script:SL_UI.LogsGrid.Visibility        = 'Collapsed'
    $Script:SL_UI.LogsPlaceholder.Text       = 'Loading sign-in logs...'
    $Script:SL_UI.LogsPlaceholder.Visibility = 'Visible'
    Set-MainStatus 'Fetching sign-in logs...' 'TextDim'

    if ($Script:SL_LogsTimer) { $Script:SL_LogsTimer.Stop() }
    $Script:SL_LogsTimer = Start-AsyncWork `
        -Vars    @{ UserId = $UserId } `
        -RefSeed @{ Logs   = $null } `
        -Script {
            # 403 (missing AuditLog.Read.All consent) is handled inline because the
            # shared helper only auto-classifies 401. Anything else falls through to
            # the helper's outer catch and surfaces as $Ref['Error'] = message.
            try {
                $url = 'https://graph.microsoft.com/v1.0/auditLogs/signIns' +
                       "?`$filter=userId eq '$UserId'" +
                       '&$top=50&$orderby=createdDateTime desc' +
                       '&$select=createdDateTime,appDisplayName,status,ipAddress,location,deviceDetail'
                $resp = Invoke-RestMethod -Uri $url `
                    -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
                $Ref['Logs'] = $resp.value
            } catch {
                if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode.value__ -eq 403) {
                    $Ref['Error'] = '403'
                } else { throw }
            }
        } -OnComplete {
            param($ref)
            try {
                if ($ref['Error'] -eq '403') {
                    Write-Log 'SignInLogs: 403 - AuditLog.Read.All not consented' 'ERROR'
                    Write-SlLog 'Permission denied. Reconnect the tenant to grant AuditLog.Read.All access.' 'Danger'
                    $Script:SL_UI.LogsPlaceholder.Text = 'Permission denied - reconnect the tenant to grant AuditLog.Read.All access.'
                    Set-MainStatus 'Permission denied.' 'Danger'
                    return
                }
                if ($ref['Error'] -eq '401') {
                    Write-Log 'SignInLogs: 401 - session expired' 'ERROR'
                    $Script:SL_UI.LogsPlaceholder.Text = 'Session expired - reconnect via the tenant selector.'
                    Set-MainStatus 'Session expired.' 'Danger'
                    return
                }
                if ($ref['Error']) {
                    Write-Log "SignInLogs: log load failed - $($ref['Error'])" 'ERROR'
                    Write-SlLog "Error fetching logs: $($ref['Error'])" 'Danger'
                    $Script:SL_UI.LogsPlaceholder.Text = "Error: $($ref['Error'])"
                    Set-MainStatus 'Failed to load sign-in logs.' 'Danger'
                    return
                }

                $logs = $ref['Logs']
                Write-Log "SignInLogs: loaded $($logs.Count) sign-in records" 'INFO'

                if (-not $logs -or $logs.Count -eq 0) {
                    $Script:SL_UI.LogsPlaceholder.Text = 'No sign-in records found for this user.'
                    Set-MainStatus 'No sign-in records found.' 'TextDim'
                    return
                }

                $greenBrush = [System.Windows.Media.SolidColorBrush]::new(
                    [System.Windows.Media.ColorConverter]::ConvertFromString((Get-ThemeHex 'Success')))
                $redBrush   = [System.Windows.Media.SolidColorBrush]::new(
                    [System.Windows.Media.ColorConverter]::ConvertFromString((Get-ThemeHex 'Danger')))
                $mutedBrush = [System.Windows.Media.SolidColorBrush]::new(
                    [System.Windows.Media.ColorConverter]::ConvertFromString((Get-ThemeHex 'TextDim')))
                $greenBrush.Freeze(); $redBrush.Freeze(); $mutedBrush.Freeze()

                $rows = foreach ($entry in $logs) {
                    $isSuccess  = $entry.status.errorCode -eq 0
                    $resultText = if ($isSuccess) { 'Success' } else { "Failure ($($entry.status.errorCode))" }
                    $resultBrush = if ($isSuccess) { $greenBrush } else { $redBrush }
                    $locParts = @($entry.location.city, $entry.location.countryOrRegion) | Where-Object { $_ }
                    [PSCustomObject]@{
                        DateTime    = if ($entry.createdDateTime) {
                                          ([datetime]$entry.createdDateTime).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
                                      } else { '' }
                        Application = $entry.appDisplayName
                        Result      = $resultText
                        ResultColor = $resultBrush
                        IpAddress   = $entry.ipAddress
                        Location    = $locParts -join ', '
                        Device      = $entry.deviceDetail.displayName
                    }
                }

                $Script:SL_UI.LogsGrid.ItemsSource    = [object[]]$rows
                $Script:SL_UI.LogsPlaceholder.Visibility = 'Collapsed'
                $Script:SL_UI.LogsGrid.Visibility        = 'Visible'
                $n = $logs.Count
                Write-SlLog "Loaded $n sign-in record$(if ($n -ne 1) { 's' })." 'Success'
                Set-MainStatus "Sign-in logs loaded ($n records)." 'Success'
            } catch {
                Write-Log "SignInLogs logs-load timer error: $_" 'ERROR'
            }
        }
}

# ── XAML ───────────────────────────────────────────────────────────────────────
$Script:SlXaml = @'
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

  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="260" MinWidth="200"/>
    <ColumnDefinition Width="5"/>
    <ColumnDefinition Width="*"/>
  </Grid.ColumnDefinitions>

  <GridSplitter Grid.Column="1" Width="5" HorizontalAlignment="Stretch"
                Background="#3C3C5A" Cursor="SizeWE" ResizeBehavior="PreviousAndNext"/>

  <!-- Left sidebar: user search + list -->
  <Border Grid.Column="0" Background="#1C1C2A">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <Border Grid.Row="0" Padding="12,10" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
        <StackPanel>
          <TextBlock Text="USERS" Foreground="#50507A" FontSize="10" FontWeight="Bold" Margin="0,0,0,8"/>
          <TextBox x:Name="SlUserSearch" IsEnabled="False" Height="34"/>
        </StackPanel>
      </Border>
      <ListBox x:Name="SlUserList" Grid.Row="1" IsEnabled="False"
               ScrollViewer.HorizontalScrollBarVisibility="Disabled"
               VirtualizingPanel.IsVirtualizing="True"
               VirtualizingPanel.VirtualizationMode="Recycling"
               Margin="0,2,0,2"/>
    </Grid>
  </Border>

  <!-- Right panel: tabs -->
  <TabControl Grid.Column="2">
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

    <!-- Sign-Ins tab -->
    <TabItem Header="Sign-Ins">
      <Grid Background="#12121C">
        <TextBlock x:Name="SlLogsPlaceholder"
                   Text="Select a user on the left to view their sign-in history"
                   Foreground="#50507A" FontStyle="Italic" FontSize="13"
                   HorizontalAlignment="Center" VerticalAlignment="Center"
                   Visibility="Visible"/>
        <DataGrid x:Name="SlLogsGrid" Visibility="Collapsed"
                  VirtualizingPanel.IsVirtualizing="True"
                  VirtualizingPanel.VirtualizationMode="Recycling">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Date / Time"  Binding="{Binding DateTime}"    Width="130"/>
            <DataGridTextColumn Header="Application"  Binding="{Binding Application}" Width="*"/>
            <DataGridTemplateColumn Header="Result" Width="130" SortMemberPath="Result">
              <DataGridTemplateColumn.CellTemplate>
                <DataTemplate>
                  <TextBlock Text="{Binding Result}" Foreground="{Binding ResultColor}"
                             VerticalAlignment="Center" Padding="12,0"/>
                </DataTemplate>
              </DataGridTemplateColumn.CellTemplate>
            </DataGridTemplateColumn>
            <DataGridTextColumn Header="IP Address"   Binding="{Binding IpAddress}"   Width="120"/>
            <DataGridTextColumn Header="Location"     Binding="{Binding Location}"    Width="140"/>
            <DataGridTextColumn Header="Device"       Binding="{Binding Device}"      Width="*"/>
          </DataGrid.Columns>
        </DataGrid>
      </Grid>
    </TabItem>

    <!-- Log tab removed — use the global Log pane -->

  </TabControl>
</Grid>
'@

# ── Initialize ─────────────────────────────────────────────────────────────────
function Initialize-SignInLogsTool {
    $reader  = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new((Invoke-ThemeXaml $Script:SlXaml)))
    $content = [System.Windows.Markup.XamlReader]::Load($reader)

    $Script:SL_UI = @{
        UserSearch      = $content.FindName('SlUserSearch')
        UserList        = $content.FindName('SlUserList')
        LogsPlaceholder = $content.FindName('SlLogsPlaceholder')
        LogsGrid        = $content.FindName('SlLogsGrid')
        # LogBox removed — use Write-AppLog to the global Log pane
    }

    $Script:SL_UI.UserSearch.Add_TextChanged({
        try { Invoke-EtbDebounced -Key 'SL_User' -Command 'Update-SlUserFilter' }
        catch { Write-Log "SL UserSearch TextChanged error: $_" 'ERROR' }
    })

    $Script:SL_UI.UserList.Add_SelectionChanged({
        try {
            $sel = $Script:SL_UI.UserList.SelectedItem
            if (-not $sel) { return }
            Write-Log "SignInLogs: selected user '$($sel.Content)' ($($sel.Tag.id))" 'DEBUG'
            Start-SlLogsLoad -UserId $sel.Tag.id
        } catch {
            Write-Log "SL UserList SelectionChanged error: $_" 'ERROR'
        }
    })

    Register-ConnectCallback 'Start-SlUserLoad'
    $Script:ResetCallbacks.Add({
        $Script:SL_AllUsers = @()
        Clear-EtbList $Script:SL_UI.UserList
        $Script:SL_UI.UserSearch.Text      = ''
        $Script:SL_UI.UserSearch.IsEnabled = $false
        $Script:SL_UI.UserList.IsEnabled   = $false
        $Script:SL_UI.LogsGrid.Visibility        = 'Collapsed'
        $Script:SL_UI.LogsPlaceholder.Text       = 'Select a user on the left to view their sign-in history'
        $Script:SL_UI.LogsPlaceholder.Visibility = 'Visible'
    })

    Write-SlLog 'Sign-In Logs ready. Select a tenant to begin.' 'Muted'
    return $content
}
