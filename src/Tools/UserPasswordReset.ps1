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
$Script:UPR_ProfTimer  = $null
$Script:UPR_GrpTimer   = $null

# ── Log helper ─────────────────────────────────────────────────────────────────
function Write-UprLog {
    param([string]$Msg, [string]$Color = 'TextDim')
    Write-AppLog $Msg $Color
}

# ── Async user load ────────────────────────────────────────────────────────────
function Start-UprUserLoad {
    if ($Script:DemoMode) { Start-UprUserLoadDemo; return }
    $Script:UPR_UI.UserSearch.IsEnabled = $false
    $Script:UPR_UI.UserList.IsEnabled   = $false
    Clear-EtbList $Script:UPR_UI.UserList
    Set-MainStatus 'Loading users...' 'TextDim'
    Write-UprLog 'Fetching users from Entra ID...' 'TextDim'

    Request-EtbUsers -OnReady 'Complete-UprUserLoad'
}

function Complete-UprUserLoad {
    try {
        if ($Script:UserCache.Error -eq '401') {
            Write-Log 'UPR: user load 401 - session expired' 'ERROR'
            Write-UprLog 'Session expired - reconnect via the tenant selector.' 'Danger'
            Set-MainStatus 'Session expired.' 'Danger'
            return
        }
        if ($Script:UserCache.Error) {
            Write-Log "UPR: user load failed - $($Script:UserCache.Error)" 'ERROR'
            Write-UprLog "Error loading users: $($Script:UserCache.Error)" 'Danger'
            Set-MainStatus 'Failed to load users.' 'Danger'
            return
        }

        $Script:UPR_AllUsers = @($Script:UserCache.Users |
            Where-Object { $_.accountEnabled } | Sort-Object { $_.displayName })
        Update-UprUserFilter
        $Script:UPR_UI.UserSearch.IsEnabled = $true
        $Script:UPR_UI.UserList.IsEnabled   = $true
        $n = $Script:UPR_AllUsers.Count
        Write-Log "UPR: loaded $n users" 'INFO'
        Write-UprLog "Loaded $n users." 'Success'
        Set-MainStatus "Loaded $n users." 'Success'
    } catch {
        Write-Log "UPR user-load error: $_" 'ERROR'
    }
}

function Update-UprUserFilter {
    $filter = $Script:UPR_UI.UserSearch.Text.Trim()
    Clear-EtbList $Script:UPR_UI.UserList
    $list = if ([string]::IsNullOrWhiteSpace($filter)) {
        $Script:UPR_AllUsers
    } else {
        $Script:UPR_AllUsers | Where-Object {
            $_.displayName       -like "*$filter*" -or
            $_.userPrincipalName -like "*$filter*"
        }
    }
    Set-EtbListItems -List $Script:UPR_UI.UserList -Items @(foreach ($u in $list) {
        [pscustomobject]@{ Content = $u.displayName; Tag = $u; ToolTip = $u.userPrincipalName }
    })
}

# ── Async passwordProfile fetch ────────────────────────────────────────────────
function Start-UprProfileLoad {
    param([string]$UserId)
    if ($Script:DemoMode) { Start-UprProfileLoadDemo; return }

    $Script:UPR_UI.PromptStatus.Text       = 'Checking...'
    $Script:UPR_UI.PromptStatus.Foreground = (Get-ThemeHex 'TextDim')
    $Script:UPR_UI.BtnReset.IsEnabled      = $false

    if ($Script:UPR_ProfTimer) { $Script:UPR_ProfTimer.Stop() }
    $Script:UPR_ProfTimer = Start-AsyncWork `
        -Vars    @{ UserId = $UserId } `
        -RefSeed @{ RequestedId = $UserId; Force  = $null } `
        -Script {
            $resp = Invoke-RestMethod `
                -Uri "https://graph.microsoft.com/v1.0/users/$UserId`?`$select=passwordProfile" `
                -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
            $Ref['Force'] = $resp.passwordProfile.forceChangePasswordNextSignIn
        } -OnComplete {
            param($ref)
            if ($Script:UPR_UI.UserList.SelectedItem.Tag.id -ne $ref.RequestedId) { return }
            try {
                $Script:UPR_UI.BtnReset.IsEnabled = $true

                if ($ref['Error']) {
                    Write-Log "UPR: passwordProfile fetch failed - $($ref['Error'])" 'WARN'
                    $Script:UPR_UI.PromptStatus.Text       = 'Could not read current status'
                    $Script:UPR_UI.PromptStatus.Foreground = (Get-ThemeHex 'TextDim')
                    return
                }

                $force = $ref['Force']
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
        }
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

    if ($Script:UPR_GrpTimer) { $Script:UPR_GrpTimer.Stop() }
    $Script:UPR_GrpTimer = Start-AsyncWork `
        -Vars    @{ UserId = $UserId } `
        -RefSeed @{ RequestedId = $UserId; Groups = $null } `
        -Script {
            $groups = [System.Collections.Generic.List[object]]::new()
            $url = "https://graph.microsoft.com/v1.0/users/$UserId/transitiveMemberOf?`$select=displayName,groupTypes&`$top=999"
            do {
                $resp = Invoke-RestMethod -Uri $url `
                    -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
                foreach ($g in $resp.value) { $groups.Add($g) }
                $url = $resp.'@odata.nextLink'
            } while ($url)
            $Ref['Groups'] = $groups.ToArray()
        } -OnComplete {
            param($ref)
            if ($Script:UPR_UI.UserList.SelectedItem.Tag.id -ne $ref.RequestedId) { return }
            try {
                if ($ref['Error'] -eq '401') {
                    $Script:UPR_UI.GrpPlaceholder.Text = 'Session expired - reconnect.'
                    return
                }
                if ($ref['Error']) {
                    Write-Log "UPR: group load failed - $($ref['Error'])" 'ERROR'
                    $Script:UPR_UI.GrpPlaceholder.Text = "Error: $($ref['Error'])"
                    return
                }

                $Script:UPR_AllGroups = @($ref['Groups'] | Sort-Object { $_.displayName })
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
        }
}

# ── XAML ───────────────────────────────────────────────────────────────────────
$Script:UprXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
      Background="#12121C">
  <Grid.Resources>

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

    <Style TargetType="PasswordBox">
      <Setter Property="Background"               Value="#242436"/>
      <Setter Property="Foreground"               Value="#E2E2F0"/>
      <Setter Property="BorderBrush"              Value="#3C3C5A"/>
      <Setter Property="BorderThickness"          Value="1"/>
      <Setter Property="Padding"                  Value="8,4"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="CaretBrush"               Value="#E2E2F0"/>
      <Setter Property="SelectionBrush"           Value="#6366F1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="PasswordBox">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="4">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                            Background="{TemplateBinding Background}"
                            VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
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
                <ColumnDefinition Width="6"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="6"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <Grid Grid.Column="0" Height="36">
                <PasswordBox x:Name="UprPasswordMasked"
                             FontFamily="Consolas" FontSize="13"/>
                <TextBox x:Name="UprPasswordBox" Height="36"
                         FontFamily="Consolas" FontSize="13"
                         Visibility="Collapsed"/>
              </Grid>
              <Button x:Name="UprBtnEye" Grid.Column="2" Content="Show"
                      Style="{StaticResource PrimaryBtn}" Background="#3C3C5A"
                      Padding="10,0" Height="36" MinWidth="48"/>
              <Button x:Name="UprBtnRegen" Grid.Column="4" Content="Regenerate"
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
function Start-UprPasswordReset {
    param($User, [securestring]$Password, [bool]$Force)
    $forceLabel = if ($Force) { 'will prompt on next sign-in' } else { 'no prompt required' }
    if ($Script:DryMode -or $Script:DemoMode) {
        $mode = if ($Script:DemoMode) { 'DEMO' } else { 'DRY' }
        $message = "[$mode] Would reset password for $($User.displayName) ($forceLabel). No changes made."
        Write-UprLog $message 'Warning'
        Set-MainStatus $message 'Warning'
        $Script:UPR_UI.InlineStatus.Text = $message
        $Script:UPR_UI.InlineStatus.Foreground = Get-ThemeHex 'Warning'
        $Script:UPR_UI.InlineStatus.Visibility = 'Visible'
        return
    }
    $Script:UPR_UI.BtnReset.IsEnabled = $false
    $Script:UPR_UI.BtnRegen.IsEnabled = $false
    $Script:UPR_UI.PasswordMasked.IsEnabled = $false
    $Script:UPR_UI.PasswordBox.IsEnabled = $false
    $Script:UPR_UI.ChkForce.IsEnabled = $false
    $Script:UPR_UI.UserList.IsEnabled = $false
    $Script:UPR_UI.UserSearch.IsEnabled = $false
    $Script:UPR_UI.InlineStatus.Visibility = 'Collapsed'
    Set-MainStatus "Resetting password for $($User.displayName)..." 'TextDim'
    $Script:UPR_ResetTimer = Start-AsyncWork `
        -Vars @{ UserId = $User.id; Password = $Password; Force = $Force } `
        -RefSeed @{ UserId = $User.id; Name = $User.displayName; Upn = $User.userPrincipalName; Force = $Force; ForceLabel = $forceLabel } `
        -Script {
            $body = @{ passwordProfile = @{ password = [Net.NetworkCredential]::new('', $Password).Password; forceChangePasswordNextSignIn = $Force } } | ConvertTo-Json
            Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$UserId" `
                -Headers @{ Authorization = "Bearer $Token" } -ContentType 'application/json' -Method PATCH -Body $body | Out-Null
        } -OnComplete {
            param($ref)
            $Script:UPR_UI.BtnReset.IsEnabled = $true
            $Script:UPR_UI.BtnRegen.IsEnabled = $true
            $Script:UPR_UI.PasswordMasked.IsEnabled = $true
            $Script:UPR_UI.PasswordBox.IsEnabled = $true
            $Script:UPR_UI.ChkForce.IsEnabled = $true
            $Script:UPR_UI.UserList.IsEnabled = $true
            $Script:UPR_UI.UserSearch.IsEnabled = $true
            $message = if ($ref.Error) { "Reset failed for $($ref.Name): $($ref.Error)" }
                       else { "Password reset for $($ref.Name). ($($ref.ForceLabel))" }
            $color = if ($ref.Error) { 'Danger' } else { 'Success' }
            Write-UprLog $message $color
            Set-MainStatus $message $color
            Write-EtbAudit -Tool 'User Password Reset' -Action 'Reset password' -Target $ref.Upn `
                           -Result $(if ($ref.Error) { 'Failed' } else { 'OK' }) `
                           -Detail $(if ($ref.Error) { $ref.Error } else { $ref.ForceLabel })
            if ($Script:UPR_UI.UserList.SelectedItem.Tag.id -ne $ref.UserId) { return }
            $Script:UPR_UI.InlineStatus.Text = $message
            $Script:UPR_UI.InlineStatus.Foreground = Get-ThemeHex $color
            $Script:UPR_UI.InlineStatus.Visibility = 'Visible'
            if (-not $ref.Error) {
                # A preceding profile read must not overwrite the successful reset.
                Stop-EtbAsyncWork $Script:UPR_ProfTimer
                $Script:UPR_UI.PromptStatus.Text = "Currently: $($ref.ForceLabel)"
                $Script:UPR_UI.PromptStatus.Foreground = Get-ThemeHex $(if ($ref.Force) { 'Warning' } else { 'Success' })
            }
        }
}

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
        PasswordBox    = $content.FindName('UprPasswordBox')
        PasswordMasked = $content.FindName('UprPasswordMasked')
        BtnEye         = $content.FindName('UprBtnEye')
        BtnRegen       = $content.FindName('UprBtnRegen')
        ChkForce      = $content.FindName('UprChkForce')
        BtnReset      = $content.FindName('UprBtnReset')
        InlineStatus  = $content.FindName('UprInlineStatus')
        # LogBox removed — use Write-AppLog to the global Log pane
        GrpHeader     = $content.FindName('UprGrpHeader')
        GrpSearch     = $content.FindName('UprGrpSearch')
        GrpList       = $content.FindName('UprGrpList')
        GrpPlaceholder= $content.FindName('UprGrpPlaceholder')
    }

    $Script:UPR_UI.GrpSearch.Add_TextChanged({
        try { Invoke-EtbDebounced -Key 'UPR_Grp' -Command 'Update-UprGroupFilter' }
        catch { Write-Log "UPR GrpSearch TextChanged error: $_" 'ERROR' }
    })

    # Search filter
    $Script:UPR_UI.UserSearch.Add_TextChanged({
        try { Invoke-EtbDebounced -Key 'UPR_User' -Command 'Update-UprUserFilter' }
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
            $pw = New-Password
            $Script:UPR_UI.PasswordMasked.Password   = $pw
            $Script:UPR_UI.PasswordBox.Text           = $pw
            $Script:UPR_UI.PasswordMasked.Visibility  = 'Visible'
            $Script:UPR_UI.PasswordBox.Visibility     = 'Collapsed'
            $Script:UPR_UI.BtnEye.Content             = 'Show'
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
            $pw = New-Password
            $Script:UPR_UI.PasswordMasked.Password   = $pw
            $Script:UPR_UI.PasswordBox.Text           = $pw
            $Script:UPR_UI.PasswordMasked.Visibility  = 'Visible'
            $Script:UPR_UI.PasswordBox.Visibility     = 'Collapsed'
            $Script:UPR_UI.BtnEye.Content             = 'Show'
            Write-Log 'UPR: password regenerated' 'DEBUG'
        } catch {
            Write-Log "UPR BtnRegen click error: $_" 'ERROR'
        }
    })

    # Eye toggle
    $Script:UPR_UI.BtnEye.Add_Click({
        try {
            if ($Script:UPR_UI.PasswordMasked.Visibility -eq 'Visible') {
                $Script:UPR_UI.PasswordBox.Text          = $Script:UPR_UI.PasswordMasked.Password
                $Script:UPR_UI.PasswordMasked.Visibility = 'Collapsed'
                $Script:UPR_UI.PasswordBox.Visibility    = 'Visible'
                $Script:UPR_UI.BtnEye.Content            = 'Hide'
            } else {
                $Script:UPR_UI.PasswordMasked.Password   = $Script:UPR_UI.PasswordBox.Text
                $Script:UPR_UI.PasswordBox.Visibility    = 'Collapsed'
                $Script:UPR_UI.PasswordMasked.Visibility = 'Visible'
                $Script:UPR_UI.BtnEye.Content            = 'Show'
            }
        } catch {
            Write-Log "UPR BtnEye click error: $_" 'ERROR'
        }
    })

    # Reset password
    $Script:UPR_UI.BtnReset.Add_Click({
        try {
            $sel = $Script:UPR_UI.UserList.SelectedItem
            if (-not $sel) { return }
            $user  = $sel.Tag
            $pw    = if ($Script:UPR_UI.PasswordMasked.Visibility -eq 'Visible') {
                $Script:UPR_UI.PasswordMasked.Password
            } else {
                $Script:UPR_UI.PasswordBox.Text
            }
            $force = [bool]$Script:UPR_UI.ChkForce.IsChecked

            if ([string]::IsNullOrWhiteSpace($pw)) {
                $Script:UPR_UI.InlineStatus.Text       = 'Password cannot be empty.'
                $Script:UPR_UI.InlineStatus.Foreground = (Get-ThemeHex 'Danger')
                $Script:UPR_UI.InlineStatus.Visibility = 'Visible'
                return
            }

            if ($Script:UPR_UI.PasswordBox.Visibility -eq 'Visible') {
                $Script:UPR_UI.PasswordMasked.Password = $pw
            }
            Start-UprPasswordReset -User $user -Password $Script:UPR_UI.PasswordMasked.SecurePassword -Force $force

        } catch {
            Write-Log "UPR BtnReset click error: $_" 'ERROR'
        }
    })

    # Register with global connect/reset hooks
    Register-ConnectCallback 'Start-UprUserLoad'
    $Script:ResetCallbacks.Add({
        $Script:UPR_AllUsers = @()
        $Script:UPR_UI.PasswordMasked.Password = ''
        $Script:UPR_UI.PasswordBox.Text = ''
        $Script:UPR_UI.BtnReset.IsEnabled = $true
        $Script:UPR_UI.BtnRegen.IsEnabled = $true
        $Script:UPR_UI.PasswordMasked.IsEnabled = $true
        $Script:UPR_UI.PasswordBox.IsEnabled = $true
        $Script:UPR_UI.ChkForce.IsEnabled = $true
        Clear-EtbList $Script:UPR_UI.UserList
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
