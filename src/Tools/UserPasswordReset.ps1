<#
    User Password Reset tab for Art's Entra Toolbox.
    Dot-sourced by Start.ps1.
    Exposes Initialize-UserPasswordResetTool.

    Allows searching for any user and resetting their password, with control
    over whether they are forced to change it on next sign-in.
    Reads current forceChangePasswordNextSignIn status from Graph before reset.
#>

# ── Script-level state ─────────────────────────────────────────────────────────
$Script:UPR_UI         = $null
$Script:UPR_AllUsers   = @()
$Script:UPR_AllGroups  = @()
$Script:UPR_UserRef    = $null
$Script:UPR_UserTimer  = $null
$Script:UPR_ProfRef    = $null
$Script:UPR_ProfTimer  = $null
$Script:UPR_GrpRef     = $null
$Script:UPR_GrpTimer   = $null

# ── Log helper ─────────────────────────────────────────────────────────────────
function Write-UprLog {
    param([string]$Msg, [string]$Color = 'TextDim')
    $ts   = Get-Date -Format 'HH:mm:ss'
    $para = New-Object System.Windows.Documents.Paragraph
    $run  = New-Object System.Windows.Documents.Run "[$ts]  $Msg"
    $run.Foreground = Get-ThemeHex $Color
    $para.Inlines.Add($run)
    $para.Margin = '0'
    $Script:UPR_UI.LogBox.Document.Blocks.Add($para)
    $Script:UPR_UI.LogBox.ScrollToEnd()
}

# ── Async user load ────────────────────────────────────────────────────────────
function Start-UprUserLoad {
    if ($Script:DemoMode) { Start-UprUserLoadDemo; return }
    $Script:UPR_UI.UserSearch.IsEnabled = $false
    $Script:UPR_UI.UserList.IsEnabled   = $false
    $Script:UPR_UI.UserList.Items.Clear()
    Set-MainStatus 'Loading users...' 'TextDim'
    Write-UprLog 'Fetching users from Entra ID...' 'TextDim'

    $Script:UPR_UserRef = [hashtable]::Synchronized(@{ Done = $false; Users = $null; Error = $null })
    $token = $Script:AccessToken

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Ref',   $Script:UPR_UserRef)
    $rs.SessionStateProxy.SetVariable('Token', $token)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        try {
            $users = [System.Collections.Generic.List[object]]::new()
            $url   = 'https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName&$top=999&$filter=accountEnabled eq true'
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

    if ($Script:UPR_UserTimer) { $Script:UPR_UserTimer.Stop() }
    $Script:UPR_UserTimer          = [System.Windows.Threading.DispatcherTimer]::new()
    $Script:UPR_UserTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $Script:UPR_UserTimer.Add_Tick({
        try {
            if (-not $Script:UPR_UserRef['Done']) { return }
            $Script:UPR_UserTimer.Stop()

            if ($Script:UPR_UserRef['Error'] -eq '401') {
                Write-Log 'UPR: user load 401 - session expired' 'ERROR'
                Write-UprLog 'Session expired - reconnect via the tenant selector.' 'Danger'
                Set-MainStatus 'Session expired.' 'Danger'
                return
            }
            if ($Script:UPR_UserRef['Error']) {
                Write-Log "UPR: user load failed - $($Script:UPR_UserRef['Error'])" 'ERROR'
                Write-UprLog "Error loading users: $($Script:UPR_UserRef['Error'])" 'Danger'
                Set-MainStatus 'Failed to load users.' 'Danger'
                return
            }

            $Script:UPR_AllUsers = @($Script:UPR_UserRef['Users'] | Sort-Object { $_.displayName })
            Update-UprUserFilter
            $Script:UPR_UI.UserSearch.IsEnabled = $true
            $Script:UPR_UI.UserList.IsEnabled   = $true
            $n = $Script:UPR_AllUsers.Count
            Write-Log "UPR: loaded $n users" 'INFO'
            Write-UprLog "Loaded $n users." 'Success'
            Set-MainStatus "Loaded $n users." 'Success'
        } catch {
            Write-Log "UPR user-load timer error: $_" 'ERROR'
        }
    })
    $Script:UPR_UserTimer.Start()
}

function Update-UprUserFilter {
    $filter = $Script:UPR_UI.UserSearch.Text.Trim()
    $Script:UPR_UI.UserList.Items.Clear()
    $list = if ([string]::IsNullOrWhiteSpace($filter)) {
        $Script:UPR_AllUsers
    } else {
        $Script:UPR_AllUsers | Where-Object {
            $_.displayName       -like "*$filter*" -or
            $_.userPrincipalName -like "*$filter*"
        }
    }
    foreach ($u in $list) {
        $lbi         = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Content = $u.displayName
        $lbi.Tag     = $u
        $lbi.ToolTip = $u.userPrincipalName
        [void]$Script:UPR_UI.UserList.Items.Add($lbi)
    }
}

# ── Async passwordProfile fetch ────────────────────────────────────────────────
function Start-UprProfileLoad {
    param([string]$UserId)
    if ($Script:DemoMode) { Start-UprProfileLoadDemo; return }

    $Script:UPR_UI.PromptStatus.Text       = 'Checking...'
    $Script:UPR_UI.PromptStatus.Foreground = (Get-ThemeHex 'TextDim')
    $Script:UPR_UI.BtnReset.IsEnabled      = $false

    $Script:UPR_ProfRef = [hashtable]::Synchronized(@{ Done = $false; Force = $null; Error = $null })
    $token = $Script:AccessToken

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Ref',    $Script:UPR_ProfRef)
    $rs.SessionStateProxy.SetVariable('Token',  $token)
    $rs.SessionStateProxy.SetVariable('UserId', $UserId)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        try {
            $resp = Invoke-RestMethod `
                -Uri "https://graph.microsoft.com/v1.0/users/$UserId`?`$select=passwordProfile" `
                -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
            $Ref['Force'] = $resp.passwordProfile.forceChangePasswordNextSignIn
        } catch {
            $Ref['Error'] = $_.Exception.Message
        } finally { $Ref['Done'] = $true }
    })
    $ps.BeginInvoke() | Out-Null

    if ($Script:UPR_ProfTimer) { $Script:UPR_ProfTimer.Stop() }
    $Script:UPR_ProfTimer          = [System.Windows.Threading.DispatcherTimer]::new()
    $Script:UPR_ProfTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $Script:UPR_ProfTimer.Add_Tick({
        try {
            if (-not $Script:UPR_ProfRef['Done']) { return }
            $Script:UPR_ProfTimer.Stop()
            $Script:UPR_UI.BtnReset.IsEnabled = $true

            if ($Script:UPR_ProfRef['Error']) {
                Write-Log "UPR: passwordProfile fetch failed - $($Script:UPR_ProfRef['Error'])" 'WARN'
                $Script:UPR_UI.PromptStatus.Text       = 'Could not read current status'
                $Script:UPR_UI.PromptStatus.Foreground = (Get-ThemeHex 'TextDim')
                return
            }

            $force = $Script:UPR_ProfRef['Force']
            if ($force -eq $true) {
                $Script:UPR_UI.PromptStatus.Text       = 'Currently: will prompt on next sign-in'
                $Script:UPR_UI.PromptStatus.Foreground = (Get-ThemeHex 'Warning')
            } else {
                $Script:UPR_UI.PromptStatus.Text       = 'Currently: no prompt required'
                $Script:UPR_UI.PromptStatus.Foreground = (Get-ThemeHex 'Success')
            }
        } catch {
            Write-Log "UPR profile timer error: $_" 'ERROR'
        }
    })
    $Script:UPR_ProfTimer.Start()
}

# ── Group membership ───────────────────────────────────────────────────────────
function Update-UprGroupFilter {
    $filter = $Script:UPR_UI.GrpSearch.Text.Trim()
    $Script:UPR_UI.GrpList.Items.Clear()
    $list = if ([string]::IsNullOrWhiteSpace($filter)) {
        $Script:UPR_AllGroups
    } else {
        $Script:UPR_AllGroups | Where-Object { $_.displayName -like "*$filter*" }
    }
    foreach ($g in $list) {
        $lbi         = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Content = $g.displayName
        $lbi.ToolTip = switch ($g.'@odata.type') {
            '#microsoft.graph.group'         { 'Group' }
            '#microsoft.graph.directoryRole' { 'Directory Role' }
            default { $g.'@odata.type' -replace '#microsoft\.graph\.', '' }
        }
        [void]$Script:UPR_UI.GrpList.Items.Add($lbi)
    }
}

function Start-UprGroupLoad {
    param([string]$UserId)
    if ($Script:DemoMode) { Start-UprGroupLoadDemo -UserId $UserId; return }
    $Script:UPR_AllGroups = @()
    $Script:UPR_UI.GrpList.Items.Clear()
    $Script:UPR_UI.GrpList.Visibility        = 'Collapsed'
    $Script:UPR_UI.GrpSearch.Visibility      = 'Collapsed'
    $Script:UPR_UI.GrpSearch.Text            = ''
    $Script:UPR_UI.GrpPlaceholder.Text       = 'Loading groups...'
    $Script:UPR_UI.GrpPlaceholder.Visibility = 'Visible'
    $Script:UPR_UI.GrpHeader.Text            = 'Select a user to view their group memberships'

    $Script:UPR_GrpRef = [hashtable]::Synchronized(@{ Done = $false; Groups = $null; Error = $null })
    $token = $Script:AccessToken

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Ref',    $Script:UPR_GrpRef)
    $rs.SessionStateProxy.SetVariable('Token',  $token)
    $rs.SessionStateProxy.SetVariable('UserId', $UserId)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        try {
            $groups = [System.Collections.Generic.List[object]]::new()
            $url = "https://graph.microsoft.com/v1.0/users/$UserId/transitiveMemberOf?`$select=displayName,groupTypes&`$top=999"
            do {
                $resp = Invoke-RestMethod -Uri $url `
                    -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
                foreach ($g in $resp.value) { $groups.Add($g) }
                $url = $resp.'@odata.nextLink'
            } while ($url)
            $Ref['Groups'] = $groups.ToArray()
        } catch {
            $sc = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode.value__ } else { 0 }
            if ($sc -eq 401) { $Ref['Error'] = '401' }
            else { $Ref['Error'] = $_.Exception.Message }
        } finally { $Ref['Done'] = $true }
    })
    $ps.BeginInvoke() | Out-Null

    if ($Script:UPR_GrpTimer) { $Script:UPR_GrpTimer.Stop() }
    $Script:UPR_GrpTimer          = [System.Windows.Threading.DispatcherTimer]::new()
    $Script:UPR_GrpTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $Script:UPR_GrpTimer.Add_Tick({
        try {
            if (-not $Script:UPR_GrpRef['Done']) { return }
            $Script:UPR_GrpTimer.Stop()

            if ($Script:UPR_GrpRef['Error'] -eq '401') {
                $Script:UPR_UI.GrpPlaceholder.Text = 'Session expired - reconnect.'
                return
            }
            if ($Script:UPR_GrpRef['Error']) {
                Write-Log "UPR: group load failed - $($Script:UPR_GrpRef['Error'])" 'ERROR'
                $Script:UPR_UI.GrpPlaceholder.Text = "Error: $($Script:UPR_GrpRef['Error'])"
                return
            }

            $Script:UPR_AllGroups = @($Script:UPR_GrpRef['Groups'] | Sort-Object { $_.displayName })
            $n = $Script:UPR_AllGroups.Count
            Write-Log "UPR: loaded $n group memberships" 'INFO'

            if ($n -eq 0) {
                $Script:UPR_UI.GrpPlaceholder.Text = 'No group memberships found.'
                return
            }

            $Script:UPR_UI.GrpHeader.Text            = "$n group membership$(if ($n -ne 1) { 's' })"
            $Script:UPR_UI.GrpPlaceholder.Visibility = 'Collapsed'
            $Script:UPR_UI.GrpSearch.Visibility      = 'Visible'
            Update-UprGroupFilter
            $Script:UPR_UI.GrpList.Visibility = 'Visible'
        } catch {
            Write-Log "UPR group timer error: $_" 'ERROR'
        }
    })
    $Script:UPR_GrpTimer.Start()
}

# ── XAML ───────────────────────────────────────────────────────────────────────
$Script:UprXaml = @'
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

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E2E2F0"/>
      <Setter Property="Cursor"     Value="Hand"/>
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
          <TextBox x:Name="UprUserSearch" IsEnabled="False" Height="34"/>
        </StackPanel>
      </Border>
      <ListBox x:Name="UprUserList" Grid.Row="1" IsEnabled="False"
               ScrollViewer.HorizontalScrollBarVisibility="Disabled"
               VirtualizingPanel.IsVirtualizing="True"
               VirtualizingPanel.VirtualizationMode="Recycling"
               Margin="0,2,0,2"/>
    </Grid>
  </Border>

  <!-- Right panel: action area + log tabs -->
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

    <!-- Reset tab -->
    <TabItem Header="Reset">
      <Grid Background="#12121C">

        <!-- Placeholder when no user selected -->
        <TextBlock x:Name="UprPlaceholder"
                   Text="Select a user on the left to reset their password"
                   Foreground="#50507A" FontStyle="Italic" FontSize="13"
                   HorizontalAlignment="Center" VerticalAlignment="Center"
                   Visibility="Visible"/>

        <!-- Action panel (shown when user selected) -->
        <ScrollViewer x:Name="UprActionPanel" VerticalScrollBarVisibility="Auto"
                      Visibility="Collapsed" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="32,28,32,28" MaxWidth="520">

            <!-- User header -->
            <Border Background="#1C1C2A" CornerRadius="8" Padding="18,14" Margin="0,0,0,20">
              <StackPanel>
                <TextBlock x:Name="UprLblName" Foreground="#E2E2F0"
                           FontSize="15" FontWeight="SemiBold"/>
                <TextBlock x:Name="UprLblUpn"  Foreground="#7878A0"
                           FontSize="12" Margin="0,3,0,0"/>
              </StackPanel>
            </Border>

            <!-- Current prompt status -->
            <TextBlock Text="CURRENT SIGN-IN PROMPT STATUS"
                       Foreground="#50507A" FontSize="10" FontWeight="Bold" Margin="0,0,0,6"/>
            <Border Background="#1C1C2A" CornerRadius="6" Padding="14,10" Margin="0,0,0,20">
              <TextBlock x:Name="UprPromptStatus" Foreground="#7878A0"
                         FontSize="12" TextWrapping="Wrap"/>
            </Border>

            <!-- New password -->
            <TextBlock Text="NEW PASSWORD"
                       Foreground="#50507A" FontSize="10" FontWeight="Bold" Margin="0,0,0,6"/>
            <Grid Margin="0,0,0,6">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="8"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBox x:Name="UprPasswordBox" Grid.Column="0" Height="36"
                       FontFamily="Consolas" FontSize="13"/>
              <Button x:Name="UprBtnRegen" Grid.Column="2" Content="Regenerate"
                      Style="{StaticResource PrimaryBtn}" Background="#3C3C5A"
                      Padding="12,0" Height="36"/>
            </Grid>
            <TextBlock Text="You can edit the password above before resetting."
                       Foreground="#50507A" FontSize="11" Margin="0,0,0,20"/>

            <!-- Force change option -->
            <TextBlock Text="SIGN-IN PROMPT AFTER RESET"
                       Foreground="#50507A" FontSize="10" FontWeight="Bold" Margin="0,0,0,8"/>
            <CheckBox x:Name="UprChkForce" Margin="0,0,0,4"
                      Content="Force password change on next sign-in"/>
            <TextBlock Text="When checked, the user must set a new password on their next login."
                       Foreground="#50507A" FontSize="11" Margin="0,0,0,24" TextWrapping="Wrap"/>

            <!-- Reset button -->
            <Button x:Name="UprBtnReset" Content="Reset Password" IsEnabled="False"
                    Style="{StaticResource PrimaryBtn}" Background="#6366F1"
                    Padding="0,12" FontSize="14"/>

            <!-- Inline status -->
            <TextBlock x:Name="UprInlineStatus" Foreground="#7878A0"
                       FontSize="12" TextWrapping="Wrap" Margin="0,12,0,0"
                       Visibility="Collapsed"/>

          </StackPanel>
        </ScrollViewer>
      </Grid>
    </TabItem>

    <!-- Log tab -->
    <TabItem Header="Log">
      <RichTextBox x:Name="UprLogBox" Background="#12121C" Foreground="#7878A0"
                   BorderThickness="0" IsReadOnly="True"
                   FontFamily="Consolas" FontSize="12" Padding="12"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
    </TabItem>

    <!-- Groups tab -->
    <TabItem Header="Groups">
      <Grid Background="#12121C">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Border Grid.Row="0" Padding="12,10" Background="#1C1C2A"
                BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
          <StackPanel>
            <TextBlock x:Name="UprGrpHeader" Foreground="#50507A" FontStyle="Italic"
                       FontSize="12" Text="Select a user to view their group memberships"/>
            <TextBox x:Name="UprGrpSearch" Height="34" Margin="0,8,0,0"
                     Visibility="Collapsed"/>
          </StackPanel>
        </Border>
        <TextBlock x:Name="UprGrpPlaceholder" Grid.Row="1"
                   Foreground="#50507A" FontStyle="Italic" FontSize="12"
                   HorizontalAlignment="Center" VerticalAlignment="Center"
                   Visibility="Collapsed"/>
        <ListBox x:Name="UprGrpList" Grid.Row="1"
                 ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                 VirtualizingPanel.IsVirtualizing="True"
                 VirtualizingPanel.VirtualizationMode="Recycling"
                 Margin="0,2,0,2" Visibility="Collapsed"/>
      </Grid>
    </TabItem>

  </TabControl>
</Grid>
'@

# ── Initialize ─────────────────────────────────────────────────────────────────
function Initialize-UserPasswordResetTool {
    $reader  = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new((Invoke-ThemeXaml $Script:UprXaml)))
    $content = [System.Windows.Markup.XamlReader]::Load($reader)

    $Script:UPR_UI = @{
        UserSearch    = $content.FindName('UprUserSearch')
        UserList      = $content.FindName('UprUserList')
        Placeholder   = $content.FindName('UprPlaceholder')
        ActionPanel   = $content.FindName('UprActionPanel')
        LblName       = $content.FindName('UprLblName')
        LblUpn        = $content.FindName('UprLblUpn')
        PromptStatus  = $content.FindName('UprPromptStatus')
        PasswordBox   = $content.FindName('UprPasswordBox')
        BtnRegen      = $content.FindName('UprBtnRegen')
        ChkForce      = $content.FindName('UprChkForce')
        BtnReset      = $content.FindName('UprBtnReset')
        InlineStatus  = $content.FindName('UprInlineStatus')
        LogBox        = $content.FindName('UprLogBox')
        GrpHeader     = $content.FindName('UprGrpHeader')
        GrpSearch     = $content.FindName('UprGrpSearch')
        GrpList       = $content.FindName('UprGrpList')
        GrpPlaceholder= $content.FindName('UprGrpPlaceholder')
    }

    $Script:UPR_UI.GrpSearch.Add_TextChanged({
        try { Update-UprGroupFilter }
        catch { Write-Log "UPR GrpSearch TextChanged error: $_" 'ERROR' }
    })

    # Search filter
    $Script:UPR_UI.UserSearch.Add_TextChanged({
        try { Update-UprUserFilter }
        catch { Write-Log "UPR UserSearch TextChanged error: $_" 'ERROR' }
    })

    # User selected
    $Script:UPR_UI.UserList.Add_SelectionChanged({
        try {
            $sel = $Script:UPR_UI.UserList.SelectedItem
            if (-not $sel) { return }
            $user = $sel.Tag
            Write-Log "UPR: selected user '$($user.displayName)' ($($user.id))" 'DEBUG'

            $Script:UPR_UI.LblName.Text  = $user.displayName
            $Script:UPR_UI.LblUpn.Text   = $user.userPrincipalName
            $Script:UPR_UI.PasswordBox.Text = New-Password
            $Script:UPR_UI.ChkForce.IsChecked = $false
            $Script:UPR_UI.InlineStatus.Visibility = 'Collapsed'
            $Script:UPR_UI.Placeholder.Visibility  = 'Collapsed'
            $Script:UPR_UI.ActionPanel.Visibility  = 'Visible'

            Start-UprProfileLoad -UserId $user.id
            Start-UprGroupLoad  -UserId $user.id
        } catch {
            Write-Log "UPR UserList SelectionChanged error: $_" 'ERROR'
        }
    })

    # Regenerate password
    $Script:UPR_UI.BtnRegen.Add_Click({
        try {
            $Script:UPR_UI.PasswordBox.Text = New-Password
            Write-Log 'UPR: password regenerated' 'DEBUG'
        } catch {
            Write-Log "UPR BtnRegen click error: $_" 'ERROR'
        }
    })

    # Reset password
    $Script:UPR_UI.BtnReset.Add_Click({
        try {
            $sel = $Script:UPR_UI.UserList.SelectedItem
            if (-not $sel) { return }
            $user  = $sel.Tag
            $pw    = $Script:UPR_UI.PasswordBox.Text.Trim()
            $force = [bool]$Script:UPR_UI.ChkForce.IsChecked

            if ([string]::IsNullOrWhiteSpace($pw)) {
                $Script:UPR_UI.InlineStatus.Text       = 'Password cannot be empty.'
                $Script:UPR_UI.InlineStatus.Foreground = (Get-ThemeHex 'Danger')
                $Script:UPR_UI.InlineStatus.Visibility = 'Visible'
                return
            }

            Write-Log "UPR: resetting password for $($user.userPrincipalName) (forceChange=$force)" 'INFO'
            $Script:UPR_UI.BtnReset.IsEnabled      = $false
            $Script:UPR_UI.BtnRegen.IsEnabled      = $false
            $Script:UPR_UI.InlineStatus.Visibility = 'Collapsed'
            Set-MainStatus "Resetting password for $($user.displayName)..." 'TextDim'

            try {
                if (-not $Script:DemoMode) {
                    Invoke-GraphPatch -Path "/v1.0/users/$($user.id)" -Body @{
                        passwordProfile = @{
                            password                      = $pw
                            forceChangePasswordNextSignIn = $force
                        }
                    }
                }

                $forceLabel = if ($force) { 'will prompt on next sign-in' } else { 'no prompt required' }
                Write-Log "UPR: password reset OK for $($user.userPrincipalName)" 'INFO'
                Write-UprLog "OK: $($user.displayName) ($($user.userPrincipalName)) - $forceLabel" 'Success'
                Set-MainStatus "Password reset for $($user.displayName)." 'Success'

                $Script:UPR_UI.InlineStatus.Text       = "Password reset successfully. ($forceLabel)"
                $Script:UPR_UI.InlineStatus.Foreground = (Get-ThemeHex 'Success')
                $Script:UPR_UI.InlineStatus.Visibility = 'Visible'

                # Update the prompt status display to reflect the new state
                if ($force) {
                    $Script:UPR_UI.PromptStatus.Text       = 'Currently: will prompt on next sign-in'
                    $Script:UPR_UI.PromptStatus.Foreground = (Get-ThemeHex 'Warning')
                } else {
                    $Script:UPR_UI.PromptStatus.Text       = 'Currently: no prompt required'
                    $Script:UPR_UI.PromptStatus.Foreground = (Get-ThemeHex 'Success')
                }

                # Pre-fill a fresh password ready for another reset
                $Script:UPR_UI.PasswordBox.Text = New-Password
            } catch {
                Write-Log "UPR: password reset FAILED for $($user.userPrincipalName) - $_" 'ERROR'
                Write-UprLog "FAILED: $($user.displayName) - $_" 'Danger'
                Set-MainStatus "Reset failed for $($user.displayName)." 'Danger'
                $Script:UPR_UI.InlineStatus.Text       = "Reset failed: $_"
                $Script:UPR_UI.InlineStatus.Foreground = (Get-ThemeHex 'Danger')
                $Script:UPR_UI.InlineStatus.Visibility = 'Visible'
            }

            $Script:UPR_UI.BtnReset.IsEnabled = $true
            $Script:UPR_UI.BtnRegen.IsEnabled = $true
        } catch {
            Write-Log "UPR BtnReset click error: $_" 'ERROR'
        }
    })

    # Register with global connect/reset hooks
    $Script:ConnectCallbacks.Add({ Start-UprUserLoad })
    $Script:ResetCallbacks.Add({
        $Script:UPR_AllUsers = @()
        $Script:UPR_UI.UserList.Items.Clear()
        $Script:UPR_UI.UserSearch.Text      = ''
        $Script:UPR_UI.UserSearch.IsEnabled = $false
        $Script:UPR_UI.UserList.IsEnabled   = $false
        $Script:UPR_UI.Placeholder.Visibility  = 'Visible'
        $Script:UPR_UI.ActionPanel.Visibility  = 'Collapsed'
        $Script:UPR_UI.InlineStatus.Visibility = 'Collapsed'
        $Script:UPR_AllGroups = @()
        $Script:UPR_UI.GrpList.Items.Clear()
        $Script:UPR_UI.GrpList.Visibility        = 'Collapsed'
        $Script:UPR_UI.GrpSearch.Visibility      = 'Collapsed'
        $Script:UPR_UI.GrpSearch.Text            = ''
        $Script:UPR_UI.GrpHeader.Text            = 'Select a user to view their group memberships'
        $Script:UPR_UI.GrpPlaceholder.Visibility = 'Collapsed'
    })

    Write-UprLog 'User Password Reset ready. Select a tenant to begin.' 'Muted'
    return $content
}
