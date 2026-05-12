<#
    Last Device tab for Entra Tools.
    Shows a searchable user list; selecting a user shows their Intune-managed devices.
    Dot-sourced by Start.ps1.
    Exposes Initialize-LastDeviceTool.

    Device lookup strategy: Intune OData does not support lambda filters on usersLoggedOn,
    so all devices are paged client-side and matched on usersLoggedOn[].userId.
#>

# ── Script-level state ─────────────────────────────────────────────────────────
$Script:LD_UI        = $null
$Script:LD_AllUsers  = @()
$Script:LD_UserRef   = $null
$Script:LD_UserTimer = $null
$Script:LD_DevRef    = $null
$Script:LD_DevTimer  = $null

# ── Log helper ─────────────────────────────────────────────────────────────────
function Write-LdLog {
    param([string]$Msg, [string]$Color = '#7878A0')
    $ts   = Get-Date -Format 'HH:mm:ss'
    $para = New-Object System.Windows.Documents.Paragraph
    $run  = New-Object System.Windows.Documents.Run "[$ts]  $Msg"
    $run.Foreground = $Color
    $para.Inlines.Add($run)
    $para.Margin = '0'
    $Script:LD_UI.LogBox.Document.Blocks.Add($para)
    $Script:LD_UI.LogBox.ScrollToEnd()
}

# ── Async user load ────────────────────────────────────────────────────────────
function Start-LdUserLoad {
    $Script:LD_UI.UserList.Items.Clear()
    $Script:LD_UI.UserSearch.Text      = ''
    $Script:LD_UI.UserSearch.IsEnabled = $false
    $Script:LD_UI.UserList.IsEnabled   = $false
    $Script:LD_UI.DevList.Items.Clear()
    $Script:LD_UI.DevList.Visibility         = 'Collapsed'
    $Script:LD_UI.DevPlaceholder.Text        = 'Select a user to see their devices'
    $Script:LD_UI.DevPlaceholder.Visibility  = 'Visible'
    $Script:LD_UI.BtnCopy.IsEnabled          = $false
    Set-MainStatus 'Loading users...' '#7878A0'
    Write-LdLog 'Fetching users from Entra ID...' '#7878A0'

    $Script:LD_UserRef = [hashtable]::Synchronized(@{ Done = $false; Users = $null; Error = $null })
    $token = $Script:AccessToken

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Ref',   $Script:LD_UserRef)
    $rs.SessionStateProxy.SetVariable('Token', $token)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        try {
            $users = [System.Collections.Generic.List[object]]::new()
            $url   = 'https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName&$top=999'
            do {
                $resp = Invoke-RestMethod -Uri $url `
                    -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
                foreach ($u in $resp.value) { $users.Add($u) }
                $url = $resp.'@odata.nextLink'
            } while ($url)
            $Ref['Users'] = $users.ToArray()
        } catch {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 401) {
                $Ref['Error'] = '401'
            } else { $Ref['Error'] = $_.Exception.Message }
        } finally { $Ref['Done'] = $true }
    })
    $ps.BeginInvoke() | Out-Null

    if ($Script:LD_UserTimer) { $Script:LD_UserTimer.Stop() }
    $Script:LD_UserTimer          = [System.Windows.Threading.DispatcherTimer]::new()
    $Script:LD_UserTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $Script:LD_UserTimer.Add_Tick({
        if (-not $Script:LD_UserRef['Done']) { return }
        $Script:LD_UserTimer.Stop()

        if ($Script:LD_UserRef['Error'] -eq '401') {
            Write-LdLog 'Session expired - reconnect via the tenant selector.' '#EF4444'
            Set-MainStatus 'Session expired.' '#EF4444'
            return
        }
        if ($Script:LD_UserRef['Error']) {
            Write-LdLog "Error loading users: $($Script:LD_UserRef['Error'])" '#EF4444'
            Set-MainStatus 'Failed to load users.' '#EF4444'
            return
        }

        $Script:LD_AllUsers = @($Script:LD_UserRef['Users'] | Sort-Object { $_.displayName })
        Update-LdUserFilter
        $Script:LD_UI.UserSearch.IsEnabled = $true
        $Script:LD_UI.UserList.IsEnabled   = $true
        $n = $Script:LD_AllUsers.Count
        Write-LdLog "Loaded $n users." '#22C55E'
        Set-MainStatus "Loaded $n users." '#22C55E'
    })
    $Script:LD_UserTimer.Start()
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

    $Script:LD_UI.DevList.Items.Clear()
    $Script:LD_UI.DevList.Visibility        = 'Collapsed'
    $Script:LD_UI.DevPlaceholder.Text       = 'Loading devices...'
    $Script:LD_UI.DevPlaceholder.Visibility = 'Visible'
    $Script:LD_UI.BtnCopy.IsEnabled         = $false
    Set-MainStatus 'Searching devices...' '#7878A0'

    $Script:LD_DevRef = [hashtable]::Synchronized(@{ Done = $false; Devices = $null; Error = $null })
    $token = $Script:AccessToken

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Ref',    $Script:LD_DevRef)
    $rs.SessionStateProxy.SetVariable('Token',  $token)
    $rs.SessionStateProxy.SetVariable('UserId', $UserId)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        try {
            # Intune OData does not support lambda filters on usersLoggedOn, so we page
            # all devices and match client-side.
            $matches = [System.Collections.Generic.List[object]]::new()
            $url = 'https://graph.microsoft.com/beta/deviceManagement/managedDevices?$select=id,deviceName,usersLoggedOn&$top=999'
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
        } catch {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 401) {
                $Ref['Error'] = '401'
            } else { $Ref['Error'] = $_.Exception.Message }
        } finally { $Ref['Done'] = $true }
    })
    $ps.BeginInvoke() | Out-Null

    if ($Script:LD_DevTimer) { $Script:LD_DevTimer.Stop() }
    $Script:LD_DevTimer          = [System.Windows.Threading.DispatcherTimer]::new()
    $Script:LD_DevTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $Script:LD_DevTimer.Add_Tick({
        if (-not $Script:LD_DevRef['Done']) { return }
        $Script:LD_DevTimer.Stop()

        if ($Script:LD_DevRef['Error'] -eq '401') {
            $Script:LD_UI.DevPlaceholder.Text = 'Session expired - reconnect.'
            Set-MainStatus 'Session expired.' '#EF4444'
            return
        }
        if ($Script:LD_DevRef['Error']) {
            $Script:LD_UI.DevPlaceholder.Text = 'Failed to load devices.'
            Set-MainStatus "Error: $($Script:LD_DevRef['Error'])" '#EF4444'
            return
        }

        $userId  = $Script:LD_UI.UserList.SelectedItem.Tag.id
        $devices = @($Script:LD_DevRef['Devices'] | Sort-Object {
            $entry = $_.usersLoggedOn | Where-Object { $_.userId -eq $userId } | Select-Object -First 1
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
            $entry = $d.usersLoggedOn | Where-Object { $_.userId -eq $userId } | Select-Object -First 1
            if ($entry -and $entry.lastLogOnDateTime) {
                $lbi.ToolTip = "Last check-in: $([datetime]$entry.lastLogOnDateTime)"
            }
            [void]$Script:LD_UI.DevList.Items.Add($lbi)
        }
        $Script:LD_UI.DevPlaceholder.Visibility = 'Collapsed'
        $Script:LD_UI.DevList.Visibility        = 'Visible'
        $n = $devices.Count
        Set-MainStatus "Loaded $n device$(if ($n -ne 1) { 's' })." '#22C55E'
    })
    $Script:LD_DevTimer.Start()
}

# ── XAML ───────────────────────────────────────────────────────────────────────
$Script:LastDeviceXaml = @'
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
      <Setter Property="Padding"                  Value="8,6"/>
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

    <Style TargetType="ListBox">
      <Setter Property="Background"      Value="Transparent"/>
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
        <Grid>
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

    <!-- Lookup tab -->
    <TabItem Header="Device Lookup">
      <Grid Background="#12121C">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*" MinWidth="200"/>
          <ColumnDefinition Width="8"/>
          <ColumnDefinition Width="*" MinWidth="200"/>
        </Grid.ColumnDefinitions>

        <!-- Users panel -->
        <Border Grid.Column="0" Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="0,0,1,0">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Padding="12,10" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
              <StackPanel>
                <TextBlock Text="USERS" Foreground="#50507A" FontSize="10" FontWeight="Bold" Margin="0,0,0,8"/>
                <TextBox x:Name="LdUserSearch" IsEnabled="False" Height="32"
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
            <Border Grid.Row="2" Background="#1C1C2A" Padding="10,8"
                    BorderBrush="#3C3C5A" BorderThickness="0,1,0,0">
              <Button x:Name="LdBtnCopy" Content="Copy Device Name" IsEnabled="False"
                      Style="{StaticResource PrimaryBtn}" Background="#6366F1" Padding="14,7"
                      HorizontalAlignment="Left"/>
            </Border>
          </Grid>
        </Border>
      </Grid>
    </TabItem>

    <!-- Log tab -->
    <TabItem Header="Log">
      <RichTextBox x:Name="LdLogBox" Background="#12121C" Foreground="#7878A0"
                   BorderThickness="0" IsReadOnly="True"
                   FontFamily="Consolas" FontSize="12" Padding="12"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
    </TabItem>

  </TabControl>
</Grid>
'@

# ── Initialize ─────────────────────────────────────────────────────────────────
function Initialize-LastDeviceTool {
    $reader  = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($Script:LastDeviceXaml))
    $content = [System.Windows.Markup.XamlReader]::Load($reader)

    $Script:LD_UI = @{
        UserSearch     = $content.FindName('LdUserSearch')
        UserList       = $content.FindName('LdUserList')
        DevPlaceholder = $content.FindName('LdDevPlaceholder')
        DevList        = $content.FindName('LdDevList')
        BtnCopy        = $content.FindName('LdBtnCopy')
        LogBox         = $content.FindName('LdLogBox')
    }

    # Search box
    $Script:LD_UI.UserSearch.Add_TextChanged({ Update-LdUserFilter })

    # User selection -> load devices
    $Script:LD_UI.UserList.Add_SelectionChanged({
        $sel = $Script:LD_UI.UserList.SelectedItem
        if (-not $sel) { return }
        Start-LdDeviceLoad -UserId $sel.Tag.id
    })

    # Device selection -> copy to clipboard
    $Script:LD_UI.DevList.Add_SelectionChanged({
        $sel = $Script:LD_UI.DevList.SelectedItem
        if (-not $sel) { $Script:LD_UI.BtnCopy.IsEnabled = $false; return }
        [System.Windows.Clipboard]::SetText($sel.Content)
        Set-MainStatus "Copied: $($sel.Content)" '#22C55E'
        $Script:LD_UI.BtnCopy.IsEnabled = $true
    })

    # Copy button re-copies selected device
    $Script:LD_UI.BtnCopy.Add_Click({
        $sel = $Script:LD_UI.DevList.SelectedItem
        if (-not $sel) { return }
        [System.Windows.Clipboard]::SetText($sel.Content)
        Set-MainStatus "Copied: $($sel.Content)" '#22C55E'
    })

    # Register with global connect/reset hooks
    $Script:ConnectCallbacks.Add({ Start-LdUserLoad })
    $Script:ResetCallbacks.Add({
        $Script:LD_AllUsers = @()
        $Script:LD_UI.UserList.Items.Clear()
        $Script:LD_UI.UserSearch.Text      = ''
        $Script:LD_UI.UserSearch.IsEnabled = $false
        $Script:LD_UI.UserList.IsEnabled   = $false
        $Script:LD_UI.DevList.Items.Clear()
        $Script:LD_UI.DevList.Visibility        = 'Collapsed'
        $Script:LD_UI.DevPlaceholder.Text       = 'Select a user to see their devices'
        $Script:LD_UI.DevPlaceholder.Visibility = 'Visible'
        $Script:LD_UI.BtnCopy.IsEnabled         = $false
    })

    Write-LdLog 'Last Device ready. Select a tenant to begin.' '#50507A'
    return $content
}
