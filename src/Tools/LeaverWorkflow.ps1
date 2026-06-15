<#
    Leaver Workflow tool for Art's Entra Toolbox.
    Dot-sourced by Start.ps1.
    Exposes Initialize-LeaverWorkflowTool.

    Actions: disable account, revoke sign-in sessions, remove from all direct group memberships.
    Each step is individually togglable. Dry-run aware.
#>

$Script:LW_UI           = $null
$Script:LW_AllUsers     = @()
$Script:LW_SelectedUser = $null
$Script:LW_UserTimer    = $null
$Script:LW_RunTimer     = $null

function Write-LwLog {
    param([string]$Msg, [string]$Color = 'TextDim')
    Write-AppLog $Msg $Color
}

function Start-LwUserLoad {
    if ($Script:DemoMode) { Start-LwUserLoadDemo; return }

    $Script:LW_UI.UserSearch.IsEnabled = $false
    $Script:LW_UI.UserList.IsEnabled   = $false
    Write-LwLog 'Loading users from Entra ID...' 'TextDim'
    Set-MainStatus 'Loading users...' 'TextDim'

    if ($Script:LW_UserTimer) { $Script:LW_UserTimer.Stop() }
    $Script:LW_UserTimer = Start-AsyncWork -RefSeed @{ Users = $null } -Script {
        $users = [System.Collections.Generic.List[object]]::new()
        $url   = 'https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName,accountEnabled&$top=999'
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
                Write-LwLog 'Session expired — reconnect.' 'Danger'
                Set-MainStatus 'Session expired.' 'Danger'
                return
            }
            if ($ref['Error']) {
                Write-LwLog "Error loading users: $($ref['Error'])" 'Danger'
                Set-MainStatus 'Failed to load users.' 'Danger'
                return
            }
            $Script:LW_AllUsers = @($ref['Users'] | Sort-Object { $_.displayName })
            Update-LwUserFilter
            $Script:LW_UI.UserSearch.IsEnabled = $true
            $Script:LW_UI.UserList.IsEnabled   = $true
            $n = $Script:LW_AllUsers.Count
            Write-LwLog "Loaded $n users." 'Success'
            Set-MainStatus "Loaded $n users." 'Success'
        } catch {
            Write-Log "LW user-load timer error: $_" 'ERROR'
        }
    }
}

function Update-LwUserFilter {
    $filter = $Script:LW_UI.UserSearch.Text.Trim()
    $Script:LW_UI.UserList.Items.Clear()
    $list = if ([string]::IsNullOrWhiteSpace($filter)) { $Script:LW_AllUsers } else {
        $Script:LW_AllUsers | Where-Object {
            $_.displayName -like "*$filter*" -or $_.userPrincipalName -like "*$filter*"
        }
    }
    foreach ($u in $list) {
        $lbi         = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Content = $u.displayName
        $lbi.Tag     = $u
        $lbi.ToolTip = $u.userPrincipalName
        [void]$Script:LW_UI.UserList.Items.Add($lbi)
    }
}

function Set-LwUserSelected {
    param($User)
    $Script:LW_SelectedUser = $User
    if (-not $User) {
        $Script:LW_UI.SelName.Text     = 'No user selected'
        $Script:LW_UI.SelUpn.Text      = ''
        $Script:LW_UI.SelState.Text    = ''
        $Script:LW_UI.BtnRun.IsEnabled = $false
        return
    }
    $Script:LW_UI.SelName.Text  = $User.displayName
    $Script:LW_UI.SelUpn.Text   = $User.userPrincipalName
    $stateLabel = if ($User.accountEnabled -eq $true) { 'CURRENTLY ENABLED' } else { 'ALREADY DISABLED' }
    $Script:LW_UI.SelState.Text    = $stateLabel
    $Script:LW_UI.BtnRun.IsEnabled = $true
}

function Start-LwRun {
    $user = $Script:LW_SelectedUser
    if (-not $user) { return }

    $doDisable = [bool]($Script:LW_UI.ChkDisable.IsChecked)
    $doRevoke  = [bool]($Script:LW_UI.ChkRevoke.IsChecked)
    $doGroups  = [bool]($Script:LW_UI.ChkGroups.IsChecked)

    if (-not $doDisable -and -not $doRevoke -and -not $doGroups) {
        Write-LwLog 'No actions selected — tick at least one.' 'Warning'
        return
    }

    if ($Script:DryMode) {
        Write-LwLog "[DRY] Leaver workflow for: $($user.displayName) ($($user.userPrincipalName))" 'Warning'
        if ($doDisable) { Write-LwLog '[DRY] Would disable account (accountEnabled = false)' 'Warning' }
        if ($doRevoke)  { Write-LwLog '[DRY] Would revoke all sign-in sessions' 'Warning' }
        if ($doGroups)  { Write-LwLog '[DRY] Would remove from all direct group memberships' 'Warning' }
        return
    }

    $Script:LW_UI.BtnRun.IsEnabled    = $false
    $Script:LW_UI.UserSearch.IsEnabled = $false
    $Script:LW_UI.UserList.IsEnabled   = $false
    Write-LwLog "Starting leaver workflow for $($user.displayName)..." 'TextDim'
    Set-MainStatus "Running leaver workflow for $($user.displayName)..." 'TextDim'

    if ($Script:LW_RunTimer) { $Script:LW_RunTimer.Stop() }
    $Script:LW_RunTimer = Start-AsyncWork `
        -Vars    @{ UserId = $user.id } `
        -RefSeed @{
            DoDisable     = $doDisable
            DoRevoke      = $doRevoke
            DoGroups      = $doGroups
            DisableDone   = $false
            DisableErr    = $null
            RevokeDone    = $false
            RevokeErr     = $null
            GroupsRemoved = [System.Collections.Generic.List[string]]::new()
            GroupsFailed  = [System.Collections.Generic.List[string]]::new()
        } `
        -Script {
            if ($Ref['DoDisable']) {
                try {
                    $body = '{"accountEnabled":false}'
                    Invoke-RestMethod `
                        -Uri "https://graph.microsoft.com/v1.0/users/$UserId" `
                        -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } `
                        -Method PATCH -Body $body -ErrorAction Stop
                    $Ref['DisableDone'] = $true
                } catch {
                    $Ref['DisableErr'] = $_.Exception.Message
                }
            }

            if ($Ref['DoRevoke']) {
                try {
                    Invoke-RestMethod `
                        -Uri "https://graph.microsoft.com/v1.0/users/$UserId/revokeSignInSessions" `
                        -Headers @{ Authorization = "Bearer $Token" } `
                        -Method POST -ErrorAction Stop
                    $Ref['RevokeDone'] = $true
                } catch {
                    $Ref['RevokeErr'] = $_.Exception.Message
                }
            }

            if ($Ref['DoGroups']) {
                $groups = [System.Collections.Generic.List[object]]::new()
                $url = "https://graph.microsoft.com/v1.0/users/$UserId/memberOf?`$select=id,displayName&`$top=999"
                do {
                    $resp = Invoke-RestMethod -Uri $url `
                        -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
                    foreach ($g in $resp.value) {
                        if ($g.'@odata.type' -eq '#microsoft.graph.group') { $groups.Add($g) }
                    }
                    $url = $resp.'@odata.nextLink'
                } while ($url)

                foreach ($grp in $groups) {
                    try {
                        Invoke-RestMethod `
                            -Uri "https://graph.microsoft.com/v1.0/groups/$($grp.id)/members/$UserId/`$ref" `
                            -Headers @{ Authorization = "Bearer $Token" } `
                            -Method DELETE -ErrorAction Stop
                        $Ref['GroupsRemoved'].Add($grp.displayName)
                    } catch {
                        $Ref['GroupsFailed'].Add("$($grp.displayName): $($_.Exception.Message)")
                    }
                }
            }
        } -OnComplete {
            param($ref)
            try {
                if ($ref['Error']) {
                    Write-LwLog "Workflow error: $($ref['Error'])" 'Danger'
                    Set-MainStatus 'Leaver workflow failed.' 'Danger'
                } else {
                    if ($ref['DoDisable']) {
                        if ($ref['DisableErr']) {
                            Write-LwLog "Disable account: FAILED — $($ref['DisableErr'])" 'Danger'
                        } else {
                            Write-LwLog 'Disable account: done' 'Success'
                        }
                    }
                    if ($ref['DoRevoke']) {
                        if ($ref['RevokeErr']) {
                            Write-LwLog "Revoke sessions: FAILED — $($ref['RevokeErr'])" 'Danger'
                        } else {
                            Write-LwLog 'Revoke sign-in sessions: done' 'Success'
                        }
                    }
                    if ($ref['DoGroups']) {
                        foreach ($g in $ref['GroupsRemoved']) { Write-LwLog "Removed from group: $g" 'Success' }
                        foreach ($g in $ref['GroupsFailed'])  { Write-LwLog "Group removal failed: $g" 'Danger' }
                        $nr = $ref['GroupsRemoved'].Count
                        $nf = $ref['GroupsFailed'].Count
                        Write-LwLog "Groups: $nr removed, $nf failed" 'Text'
                    }
                    $displayName = if ($Script:LW_SelectedUser) { $Script:LW_SelectedUser.displayName } else { 'user' }
                    $summary = "Leaver workflow complete for $displayName"
                    Write-LwLog $summary 'Success'
                    Set-MainStatus $summary 'Success'
                    Write-Log "LW: $summary" 'INFO'
                }
                $Script:LW_UI.BtnRun.IsEnabled    = $true
                $Script:LW_UI.UserSearch.IsEnabled = $true
                $Script:LW_UI.UserList.IsEnabled   = $true
            } catch {
                Write-Log "LW run-timer error: $_" 'ERROR'
            }
        }
}

function Start-LwUserLoadDemo {
    $Script:LW_AllUsers = @(
        $Script:Demo_Users | Where-Object { $_.id -ne $null } | Select-Object -First 10
    )
    Update-LwUserFilter
    $Script:LW_UI.UserSearch.IsEnabled = $true
    $Script:LW_UI.UserList.IsEnabled   = $true
    Write-LwLog "Demo: loaded $($Script:LW_AllUsers.Count) users." 'Success'
}

$Script:LwXaml = @'
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

  </Grid.Resources>

  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="260" MinWidth="200"/>
    <ColumnDefinition Width="5"/>
    <ColumnDefinition Width="*"/>
  </Grid.ColumnDefinitions>

  <GridSplitter Grid.Column="1" Width="5" HorizontalAlignment="Stretch"
                Background="#3C3C5A" Cursor="SizeWE" ResizeBehavior="PreviousAndNext"/>

  <!-- Left sidebar: user list -->
  <Border Grid.Column="0" Background="#1C1C2A">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <Border Grid.Row="0" Padding="12,10" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
        <StackPanel>
          <TextBlock Text="SELECT LEAVER" Foreground="#50507A" FontSize="10"
                     FontWeight="Bold" Margin="0,0,0,8"/>
          <TextBox x:Name="LwUserSearch" IsEnabled="False" Height="34"/>
        </StackPanel>
      </Border>
      <ListBox x:Name="LwUserList" Grid.Row="1" IsEnabled="False"
               ScrollViewer.HorizontalScrollBarVisibility="Disabled"
               VirtualizingPanel.IsVirtualizing="True"
               VirtualizingPanel.VirtualizationMode="Recycling"
               Margin="0,2,0,2"/>
    </Grid>
  </Border>

  <!-- Right: action panel -->
  <Grid Grid.Column="2">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- Selected user bar -->
    <Border Grid.Row="0" Background="#1C1C2A" BorderBrush="#3C3C5A"
            BorderThickness="0,0,0,1" Padding="20,14">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" VerticalAlignment="Center">
          <TextBlock x:Name="LwSelName" Text="No user selected"
                     Foreground="#7878A0" FontStyle="Italic" FontSize="15" FontWeight="SemiBold"/>
          <TextBlock x:Name="LwSelUpn" Foreground="#50507A" FontSize="11" Margin="0,3,0,0"/>
          <TextBlock x:Name="LwSelState" Foreground="#50507A" FontSize="10"
                     FontWeight="Bold" Margin="0,5,0,0"/>
        </StackPanel>
        <Button x:Name="LwBtnRun" Grid.Column="1"
                Content="Run Leaver Workflow" IsEnabled="False"
                Style="{StaticResource PrimaryBtn}" Background="#EF4444"
                Padding="18,10" FontSize="13" VerticalAlignment="Center"/>
      </Grid>
    </Border>

    <!-- Actions -->
    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
      <StackPanel Margin="24,20,24,20">

        <TextBlock Text="ACTIONS TO RUN" Foreground="#50507A" FontSize="10"
                   FontWeight="Bold" Margin="0,0,0,14"/>

        <Border Background="#242436" CornerRadius="6" Padding="16,14" Margin="0,0,0,10">
          <CheckBox x:Name="LwChkDisable" IsChecked="True" Foreground="#E2E2F0" Cursor="Hand">
            <StackPanel Margin="6,0,0,0">
              <TextBlock Text="Disable account" Foreground="#E2E2F0" FontSize="13" FontWeight="SemiBold"/>
              <TextBlock Foreground="#7878A0" FontSize="11" Margin="0,3,0,0" TextWrapping="Wrap"
                         Text="Sets accountEnabled = false. The user cannot sign in to any service."/>
            </StackPanel>
          </CheckBox>
        </Border>

        <Border Background="#242436" CornerRadius="6" Padding="16,14" Margin="0,0,0,10">
          <CheckBox x:Name="LwChkRevoke" IsChecked="True" Foreground="#E2E2F0" Cursor="Hand">
            <StackPanel Margin="6,0,0,0">
              <TextBlock Text="Revoke sign-in sessions" Foreground="#E2E2F0" FontSize="13" FontWeight="SemiBold"/>
              <TextBlock Foreground="#7878A0" FontSize="11" Margin="0,3,0,0" TextWrapping="Wrap"
                         Text="Invalidates all active refresh tokens immediately. Forces re-auth on any existing sessions."/>
            </StackPanel>
          </CheckBox>
        </Border>

        <Border Background="#242436" CornerRadius="6" Padding="16,14" Margin="0,0,0,10">
          <CheckBox x:Name="LwChkGroups" IsChecked="True" Foreground="#E2E2F0" Cursor="Hand">
            <StackPanel Margin="6,0,0,0">
              <TextBlock Text="Remove from all groups" Foreground="#E2E2F0" FontSize="13" FontWeight="SemiBold"/>
              <TextBlock Foreground="#7878A0" FontSize="11" Margin="0,3,0,0" TextWrapping="Wrap"
                         Text="Removes all direct security group and Microsoft 365 group memberships."/>
            </StackPanel>
          </CheckBox>
        </Border>

        <TextBlock Foreground="#3C3C5A" FontSize="11" TextWrapping="Wrap" Margin="0,10,0,0"
                   Text="Results are shown in the global Log pane (Log button in the toolbar)."/>
      </StackPanel>
    </ScrollViewer>
  </Grid>

</Grid>
'@

function Initialize-LeaverWorkflowTool {
    $reader  = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new((Invoke-ThemeXaml $Script:LwXaml)))
    $content = [System.Windows.Markup.XamlReader]::Load($reader)

    $Script:LW_UI = @{
        UserSearch = $content.FindName('LwUserSearch')
        UserList   = $content.FindName('LwUserList')
        SelName    = $content.FindName('LwSelName')
        SelUpn     = $content.FindName('LwSelUpn')
        SelState   = $content.FindName('LwSelState')
        BtnRun     = $content.FindName('LwBtnRun')
        ChkDisable = $content.FindName('LwChkDisable')
        ChkRevoke  = $content.FindName('LwChkRevoke')
        ChkGroups  = $content.FindName('LwChkGroups')
    }

    $Script:LW_UI.UserSearch.Add_TextChanged({
        try { Update-LwUserFilter }
        catch { Write-Log "LW UserSearch error: $_" 'ERROR' }
    })

    $Script:LW_UI.UserList.Add_SelectionChanged({
        try {
            $sel  = $Script:LW_UI.UserList.SelectedItem
            $user = if ($sel) { $sel.Tag } else { $null }
            Set-LwUserSelected $user
        } catch {
            Write-Log "LW UserList SelectionChanged error: $_" 'ERROR'
        }
    })

    $Script:LW_UI.BtnRun.Add_Click({
        try { Start-LwRun }
        catch { Write-Log "LW BtnRun click error: $_" 'ERROR' }
    })

    Register-ConnectCallback 'Start-LwUserLoad'
    $Script:ResetCallbacks.Add({
        $Script:LW_AllUsers     = @()
        $Script:LW_SelectedUser = $null
        if ($Script:LW_UserTimer) { $Script:LW_UserTimer.Stop() }
        if ($Script:LW_RunTimer)  { $Script:LW_RunTimer.Stop() }
        $Script:LW_UI.UserList.Items.Clear()
        $Script:LW_UI.UserSearch.Text      = ''
        $Script:LW_UI.UserSearch.IsEnabled = $false
        $Script:LW_UI.UserList.IsEnabled   = $false
        $Script:LW_UI.SelName.Text         = 'No user selected'
        $Script:LW_UI.SelUpn.Text          = ''
        $Script:LW_UI.SelState.Text        = ''
        $Script:LW_UI.BtnRun.IsEnabled     = $false
    })

    Write-LwLog 'Leaver Workflow ready. Select a tenant to begin.' 'Muted'
    return $content
}
