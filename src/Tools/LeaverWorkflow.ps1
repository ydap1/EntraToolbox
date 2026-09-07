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
$Script:LW_RunTimer     = $null
$Script:LW_RestoreTimer = $null

function Write-LwLog {
    param([string]$Msg, [string]$Color = 'TextDim')
    Write-AppLog $Msg $Color
}

# ── Membership snapshots ──────────────────────────────────────────────────────
# Removing every group membership is the one step here that cannot be worked
# out again afterwards: once the memberships are gone, nothing records what the
# account used to belong to. Each live run writes the removed groups to
# config\leavers\ so a workflow run against the wrong account can be undone.
function Save-LwGroupSnapshot {
    param($User, $Groups)
    if ($Script:DemoMode -or -not $User -or -not $Groups -or $Groups.Count -eq 0) { return }
    try {
        $dir = Join-Path $Global:AppRoot 'config\leavers'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $safe = ($User.userPrincipalName -replace '[^a-zA-Z0-9._-]', '_')
        $path = Join-Path $dir "$safe-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        [pscustomobject]@{
            UserId      = $User.id
            Upn         = $User.userPrincipalName
            DisplayName = $User.displayName
            RemovedAt   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Groups      = @($Groups | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Name = $_.Name } })
        } | ConvertTo-Json -Depth 4 | Set-Content -Path $path -Encoding UTF8
        Write-LwLog "Saved membership snapshot: $path" 'Muted'
    } catch {
        Write-Log "LW snapshot save failed: $_" 'ERROR'
    }
}

function Start-LwRestore {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter           = 'Membership snapshot (*.json)|*.json'
    $dlg.Title            = 'Restore group memberships from snapshot'
    $dlg.InitialDirectory = Join-Path $Global:AppRoot 'config\leavers'
    if (-not $dlg.ShowDialog()) { return }

    try {
        $snap = Get-Content -Path $dlg.FileName -Raw | ConvertFrom-Json
    } catch {
        Write-LwLog "Could not read snapshot: $_" 'Danger'
        return
    }
    if (-not $snap.UserId -or -not $snap.Groups) {
        Write-LwLog 'Snapshot is missing a user or group list.' 'Danger'
        return
    }

    $groups = @($snap.Groups)
    if ($Script:DryMode) {
        Write-LwLog "[DRY] Would restore $($groups.Count) group membership(s) for $($snap.Upn)" 'Warning'
        return
    }
    if ($Script:DemoMode) {
        Write-LwLog "Demo: would restore $($groups.Count) membership(s) for $($snap.Upn)." 'Warning'
        return
    }

    $Script:LW_UI.BtnRestore.IsEnabled = $false
    Write-LwLog "Restoring $($groups.Count) membership(s) for $($snap.Upn)..." 'TextDim'

    if ($Script:LW_RestoreTimer) { $Script:LW_RestoreTimer.Stop() }
    $Script:LW_RestoreTimer = Start-AsyncWork `
        -Vars    @{ UserId = $snap.UserId; Groups = $groups } `
        -RefSeed @{ Upn = $snap.Upn; Restored = 0; Results = @() } `
        -Script {
            $out = [System.Collections.Generic.List[object]]::new()
            $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$UserId" } | ConvertTo-Json
            foreach ($g in $Groups) {
                try {
                    Invoke-RestMethod `
                        -Uri "https://graph.microsoft.com/v1.0/groups/$($g.Id)/members/`$ref" `
                        -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } `
                        -Method POST -Body $body -ErrorAction Stop
                    $out.Add(@{ Name = $g.Name; Ok = $true; Err = '' })
                } catch {
                    $out.Add(@{ Name = $g.Name; Ok = $false; Err = $_.Exception.Message })
                }
            }
            $Ref['Results'] = $out.ToArray()
        } -OnComplete {
            param($ref)
            try {
                $Script:LW_UI.BtnRestore.IsEnabled = $true
                if ($ref['Error']) {
                    Write-LwLog "Restore failed: $($ref['Error'])" 'Danger'
                    return
                }
                $ok = 0; $fail = 0
                foreach ($r in $ref['Results']) {
                    if ($r['Ok']) { $ok++; Write-LwLog "Restored: $($r['Name'])" 'Success' }
                    else { $fail++; Write-LwLog "Restore failed: $($r['Name']) — $($r['Err'])" 'Danger' }
                }
                $summary = "Restore complete — $ok restored, $fail failed."
                $color = if ($fail -gt 0) { 'Warning' } else { 'Success' }
                Write-LwLog $summary $color
                Set-MainStatus $summary $color
                Write-EtbAudit -Tool 'Leaver Workflow' -Action 'Restore group memberships' `
                               -Target $ref['Upn'] -Result $(if ($fail -gt 0) { 'Partial' } else { 'OK' }) `
                               -Detail "$ok restored, $fail failed"
            } catch {
                Write-Log "LW restore-timer error: $_" 'ERROR'
            }
        }
}

function Start-LwUserLoad {
    if ($Script:DemoMode) { Start-LwUserLoadDemo; return }

    $Script:LW_UI.UserSearch.IsEnabled = $false
    $Script:LW_UI.UserList.IsEnabled   = $false
    Write-LwLog 'Loading users from Entra ID...' 'TextDim'
    Set-MainStatus 'Loading users...' 'TextDim'

    Request-EtbUsers -OnReady 'Complete-LwUserLoad'
}

function Complete-LwUserLoad {
    try {
        if ($Script:UserCache.Error -eq '401') {
            Write-LwLog 'Session expired — reconnect.' 'Danger'
            Set-MainStatus 'Session expired.' 'Danger'
            return
        }
        if ($Script:UserCache.Error) {
            Write-LwLog "Error loading users: $($Script:UserCache.Error)" 'Danger'
            Set-MainStatus 'Failed to load users.' 'Danger'
            return
        }
        $Script:LW_AllUsers = @($Script:UserCache.Users | Sort-Object { $_.displayName })
        Update-LwUserFilter
        $Script:LW_UI.UserSearch.IsEnabled = $true
        $Script:LW_UI.UserList.IsEnabled   = $true
        $n = $Script:LW_AllUsers.Count
        Write-LwLog "Loaded $n users." 'Success'
        Set-MainStatus "Loaded $n users." 'Success'
    } catch {
        Write-Log "LW user-load error: $_" 'ERROR'
    }
}

function Update-LwUserFilter {
    $filter = $Script:LW_UI.UserSearch.Text.Trim()
    Clear-EtbList $Script:LW_UI.UserList
    $list = if ([string]::IsNullOrWhiteSpace($filter)) { $Script:LW_AllUsers } else {
        $Script:LW_AllUsers | Where-Object {
            $_.displayName -like "*$filter*" -or $_.userPrincipalName -like "*$filter*"
        }
    }
    Set-EtbListItems -List $Script:LW_UI.UserList -Items @(foreach ($u in $list) {
        [pscustomobject]@{ Content = $u.displayName; Tag = $u; ToolTip = $u.userPrincipalName }
    })
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

    if ($Script:DryMode -or $Script:DemoMode) {
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
            # id + name of every group actually removed, so the membership can
            # be put back if the workflow was run against the wrong account.
            RemovedDetail = [System.Collections.Generic.List[object]]::new()
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
                        $Ref['RemovedDetail'].Add(@{ Id = $grp.id; Name = $grp.displayName })
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
                    $upn = if ($Script:LW_SelectedUser) { $Script:LW_SelectedUser.userPrincipalName } else { '' }
                    if ($ref['DoDisable']) {
                        if ($ref['DisableErr']) {
                            Write-LwLog "Disable account: FAILED — $($ref['DisableErr'])" 'Danger'
                            Write-EtbAudit -Tool 'Leaver Workflow' -Action 'Disable account' -Target $upn `
                                           -Result 'Failed' -Detail $ref['DisableErr']
                        } else {
                            Write-LwLog 'Disable account: done' 'Success'
                            Write-EtbAudit -Tool 'Leaver Workflow' -Action 'Disable account' -Target $upn
                        }
                    }
                    if ($ref['DoRevoke']) {
                        if ($ref['RevokeErr']) {
                            Write-LwLog "Revoke sessions: FAILED — $($ref['RevokeErr'])" 'Danger'
                            Write-EtbAudit -Tool 'Leaver Workflow' -Action 'Revoke sessions' -Target $upn `
                                           -Result 'Failed' -Detail $ref['RevokeErr']
                        } else {
                            Write-LwLog 'Revoke sign-in sessions: done' 'Success'
                            Write-EtbAudit -Tool 'Leaver Workflow' -Action 'Revoke sessions' -Target $upn
                        }
                    }
                    if ($ref['DoGroups']) {
                        foreach ($g in $ref['GroupsRemoved']) { Write-LwLog "Removed from group: $g" 'Success' }
                        foreach ($g in $ref['GroupsFailed'])  { Write-LwLog "Group removal failed: $g" 'Danger' }
                        $nr = $ref['GroupsRemoved'].Count
                        $nf = $ref['GroupsFailed'].Count
                        Write-LwLog "Groups: $nr removed, $nf failed" 'Text'
                        Write-EtbAudit -Tool 'Leaver Workflow' -Action 'Remove all group memberships' `
                                       -Target $upn -Result $(if ($nf -gt 0) { 'Partial' } else { 'OK' }) `
                                       -Detail "$nr removed, $nf failed"
                        Save-LwGroupSnapshot -User $Script:LW_SelectedUser -Groups $ref['RemovedDetail']
                    }
                    $displayName = if ($Script:LW_SelectedUser) { $Script:LW_SelectedUser.displayName } else { 'user' }
                    $summary = "Leaver workflow complete for $displayName"
                    $failed = $ref.DisableErr -or $ref.RevokeErr -or $ref.GroupsFailed.Count -gt 0
                    if ($failed) { $summary += ' — some actions failed; check the activity log.' }
                    $color = if ($failed) { 'Warning' } else { 'Success' }
                    Write-LwLog $summary $color
                    Set-MainStatus $summary $color
                    if ($ref.DisableDone -and $Script:LW_SelectedUser) {
                        $Script:LW_SelectedUser.accountEnabled = $false
                        Set-LwUserSelected $Script:LW_SelectedUser
                    }
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
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="LwBtnRestore" Content="Restore Groups…"
                  Style="{StaticResource PrimaryBtn}" Background="#3C3C5A"
                  Padding="14,10" FontSize="12" Margin="0,0,10,0"
                  ToolTip="Put back the group memberships a previous leaver run removed"/>
          <Button x:Name="LwBtnRun"
                  Content="Run Leaver Workflow" IsEnabled="False"
                  Style="{StaticResource PrimaryBtn}" Background="#EF4444"
                  Padding="18,10" FontSize="13"/>
        </StackPanel>
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
        BtnRestore = $content.FindName('LwBtnRestore')
        ChkDisable = $content.FindName('LwChkDisable')
        ChkRevoke  = $content.FindName('LwChkRevoke')
        ChkGroups  = $content.FindName('LwChkGroups')
    }

    $Script:LW_UI.UserSearch.Add_TextChanged({
        try { Invoke-EtbDebounced -Key 'LW_User' -Command 'Update-LwUserFilter' }
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

    $Script:LW_UI.BtnRestore.Add_Click({
        try { Start-LwRestore }
        catch { Write-Log "LW BtnRestore click error: $_" 'ERROR' }
    })

    Register-ConnectCallback 'Start-LwUserLoad'
    $Script:ResetCallbacks.Add({
        $Script:LW_AllUsers     = @()
        $Script:LW_SelectedUser = $null
        if ($Script:LW_RunTimer)     { $Script:LW_RunTimer.Stop() }
        if ($Script:LW_RestoreTimer) { $Script:LW_RestoreTimer.Stop() }
        Clear-EtbList $Script:LW_UI.UserList
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
