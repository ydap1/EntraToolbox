<#
    Team Editor tab for Art's Entra Toolbox.
    Dot-sourced by Start.ps1.
    Exposes Initialize-TeamEditorTool.

    Adds missing students or staff to an existing Team, chosen by year group,
    department, office or name as in Teams Provisioning. Never removes anyone.
#>

$Script:TE_UI         = $null
$Script:TE_Teams      = @()
$Script:TE_Users      = @()
$Script:TE_MemberIds  = $null   # user IDs already in the selected team; $null until read
$Script:TE_Rows       = [System.Collections.ObjectModel.ObservableCollection[PSObject]]::new()
$Script:TE_Busy       = $false
$Script:TE_Timer      = $null
$Script:TE_SearchTimer = $null
$Script:TE_MemberError = $null

# Grid rows for the users not already in the team or already listed.
function Get-TeMissingRows {
    param([object[]]$Users, [System.Collections.Generic.HashSet[string]]$MemberIds, [object[]]$Listed = @())
    $seen = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Listed | ForEach-Object Id))
    foreach ($u in $Users) {
        if (-not $u.id -or $MemberIds.Contains($u.id) -or -not $seen.Add($u.id)) { continue }
        [pscustomobject]@{ Id = $u.id; DisplayName = $u.displayName; UPN = $u.userPrincipalName; Department = $u.department; Office = $u.officeLocation; IsOwner = $false }
    }
}

function Update-TeState {
    $ready = $Script:TE_UI.Teams.SelectedItem -and $null -ne $Script:TE_MemberIds -and -not $Script:TE_Busy
    $Script:TE_UI.TeamPicker.IsEnabled = -not $Script:TE_Busy
    $Script:TE_UI.Picker.IsEnabled     = $ready
    $Script:TE_UI.Remove.IsEnabled     = $ready -and $Script:TE_Rows.Count -gt 0
    $Script:TE_UI.Clear.IsEnabled      = $ready -and $Script:TE_Rows.Count -gt 0
    $Script:TE_UI.Apply.IsEnabled      = $ready -and $Script:TE_Rows.Count -gt 0
    $Script:TE_UI.Count.Text = "$($Script:TE_Rows.Count) to add"
    Update-TeBanner
}

# The pinned card above the list, so the target team is never in doubt.
function Update-TeBanner {
    $team = $Script:TE_UI.Teams.SelectedItem
    $Script:TE_UI.BannerBar.Background = Get-ThemeHex $(if ($team) { 'Accent' } else { 'Border' })
    $Script:TE_UI.BannerBadge.Visibility = if ($team -and $null -ne $Script:TE_MemberIds) { 'Visible' } else { 'Collapsed' }
    $Script:TE_UI.BannerCount.Text = "$($Script:TE_Rows.Count) to add"
    if (-not $team) {
        $Script:TE_UI.BannerName.Text = 'No team selected'
        $Script:TE_UI.BannerName.Foreground = Get-ThemeHex 'TextDim'
        $Script:TE_UI.BannerInfo.Text = 'Search for a team on the left, then choose it from the results.'
        $Script:TE_UI.Banner.ToolTip = $null
        return
    }
    $Script:TE_UI.BannerName.Text = $team.displayName
    $Script:TE_UI.BannerName.Foreground = Get-ThemeHex 'Text'
    $Script:TE_UI.Banner.ToolTip = "$($team.displayName)`nID: $($team.id)"
    $Script:TE_UI.BannerInfo.Text = if ($Script:TE_Busy) { 'Adding people to this team…' }
        elseif ($Script:TE_MemberError) { "Could not read members: $Script:TE_MemberError" }
        elseif ($null -eq $Script:TE_MemberIds) { 'Reading current members…' }
        else { "$($Script:TE_MemberIds.Count) people already in this team. Anyone you add below joins this team." }
}

# Teams are searched on request rather than listed up front: a school tenant
# can hold thousands, and loading them all stalled the window.
function Start-TeSearch {
    $text = $Script:TE_UI.Search.Text.Trim() -replace '["\\]', ''
    if (-not $text -or $Script:TE_Busy) { return }
    Stop-EtbAsyncWork $Script:TE_SearchTimer
    $Script:TE_UI.Teams.ItemsSource = @()
    if ($Script:DemoMode) {
        $demo = @(
            [pscustomobject]@{ id = 'demo-team-7'; displayName = 'Year 7 Science 2026' }
            [pscustomobject]@{ id = 'demo-team-10'; displayName = 'Year 10 Tutor Group 2026' }
        )
        Complete-TeSearch @{ Query = $text; Teams = @($demo | Where-Object { $_.displayName.IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
        return
    }
    $Script:TE_UI.Status.Text = "Searching for teams matching '$text'…"
    $Script:TE_SearchTimer = Start-AsyncWork -Vars @{ Query = $text } -RefSeed @{ Query = $text } -Script {
        # $search matches words that start with the query, e.g. 2026 finds '7X Maths 2026'.
        $search = [uri]::EscapeDataString("`"displayName:$Query`"")
        $Ref['Teams'] = @(Get-EtbGraphCollection -Uri "https://graph.microsoft.com/v1.0/groups?`$search=$search&`$select=id,displayName,resourceProvisioningOptions&`$top=100" -Headers @{ Authorization = "Bearer $Token"; ConsistencyLevel = 'eventual' } |
            Where-Object { $_.resourceProvisioningOptions -contains 'Team' })
    } -OnComplete { param($ref); Complete-TeSearch $ref }
}

function Complete-TeSearch {
    param($Ref)
    if ($Ref.Error) { $Script:TE_UI.Status.Text = "Team search failed: $($Ref.Error)"; return }
    $Script:TE_Teams = @($Ref.Teams | Sort-Object displayName)
    $Script:TE_UI.Teams.ItemsSource = $Script:TE_Teams
    $Script:TE_UI.Status.Text = if ($Script:TE_Teams.Count) { "$($Script:TE_Teams.Count) teams match '$($Ref.Query)'. Choose one to see who is missing." }
        else { "No teams match '$($Ref.Query)'. Search matches the start of words in the name, e.g. 2026 or Maths." }
}

function Update-TeUserSearch {
    $text = $Script:TE_UI.UserSearch.Text.Trim()
    $Script:TE_UI.Matches.ItemsSource = @(if ($text) {
        $Script:TE_Users | Where-Object { $_.displayName.IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $_.userPrincipalName.IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 50
    })
}

function Start-TeLoad {
    if ($Script:DemoMode) { Complete-TeUsers } else { Request-EtbUsers -OnReady 'Complete-TeUsers' }
    $Script:TE_UI.Status.Text = 'Type part of a team name, then press Enter or Search.'
}

function Complete-TeUsers {
    if (-not $Script:DemoMode -and $Script:UserCache.Error) { $Script:TE_UI.Status.Text = "Users unavailable: $($Script:UserCache.Error)"; return }
    $source = if ($Script:DemoMode) { $Script:Demo_Users } else { $Script:UserCache.Users }
    $Script:TE_Users = @($source | Where-Object { $_.accountEnabled })
    Set-EtbPopulationCombo -ComboBox $Script:TE_UI.Years -Users $Script:TE_Users -Mode YearGroup
    Set-EtbPopulationCombo -ComboBox $Script:TE_UI.Departments -Users $Script:TE_Users -Mode Department
    Set-EtbPopulationCombo -ComboBox $Script:TE_UI.Offices -Users $Script:TE_Users -Mode OfficeLocation
}

function Start-TeMembersLoad {
    Stop-EtbAsyncWork $Script:TE_Timer
    $Script:TE_MemberIds = $null
    $Script:TE_MemberError = $null
    $Script:TE_Rows.Clear()
    Update-TeState
    $team = $Script:TE_UI.Teams.SelectedItem
    if (-not $team) { return }
    $Script:TE_UI.Status.Text = "Reading members of $($team.displayName)…"
    if ($Script:DemoMode) {
        Complete-TeMembersLoad @{ TeamId = $team.id; MemberIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Script:Demo_Users | Select-Object -First 5 | ForEach-Object id)) }
        return
    }
    $Script:TE_Timer = Start-AsyncWork -Vars @{ TeamId = $team.id } -RefSeed @{ TeamId = $team.id } -Script {
        $Ref['MemberIds'] = Get-EtbTeamMemberIds $TeamId @{ Authorization = "Bearer $Token" }
    } -OnComplete { param($ref); Complete-TeMembersLoad $ref }
}

function Complete-TeMembersLoad {
    param($Ref)
    $team = $Script:TE_UI.Teams.SelectedItem
    if (-not $team -or $team.id -ne $Ref.TeamId) { return }
    if ($Ref.Error) {
        $Script:TE_MemberError = $Ref.Error
        $Script:TE_UI.Status.Text = "Could not read the members of $($team.displayName): $($Ref.Error)"
        Update-TeBanner
        return
    }
    $Script:TE_MemberIds = $Ref.MemberIds
    $Script:TE_UI.Status.Text = "$($team.displayName) has $($Script:TE_MemberIds.Count) members. Add a year group, department, office or individual users; only people not already in the team are listed."
    Update-TeState
}

function Add-TeUsers {
    param([object[]]$Users)
    if ($null -eq $Script:TE_MemberIds -or -not $Users.Count) { return }
    $new = @(Get-TeMissingRows $Users $Script:TE_MemberIds @($Script:TE_Rows))
    foreach ($row in $new) { $Script:TE_Rows.Add($row) }
    $already = @($Users | Where-Object { $Script:TE_MemberIds.Contains([string]$_.id) }).Count
    $Script:TE_UI.Status.Text = "$($new.Count) added to the list; $already already in the team."
    Update-TeState
}

function Start-TeApply {
    $team = $Script:TE_UI.Teams.SelectedItem
    $Script:TE_UI.Grid.CommitEdit('Row', $true) | Out-Null
    $rows = @($Script:TE_Rows)
    if ($Script:TE_Busy -or -not $team -or -not $rows.Count) { return }
    $owners = @($rows | Where-Object IsOwner).Count
    if ($Script:DryMode -or $Script:DemoMode) {
        $mode = if ($Script:DemoMode) { 'Demo' } else { 'Dry run' }
        Publish-EtbBulkPreview 'Team Editor' @($rows | ForEach-Object { [pscustomobject]@{ Target = $_.UPN; Action = $(if ($_.IsOwner) { 'Add owner' } else { 'Add member' }); Result = $mode; Detail = $team.displayName } }) $mode
        $Script:TE_UI.Status.Text = "Preview only: would add $($rows.Count) people to $($team.displayName) ($owners as owners). No tenant changes made."
        return
    }
    if (-not (Confirm-EtbAction "Add $($rows.Count) people to '$($team.displayName)'? $owners of them will be owners." 'Confirm team changes')) { return }
    $Script:TE_Busy = $true
    Update-TeState
    $Script:TE_UI.Status.Text = "Adding $($rows.Count) people to $($team.displayName). Open Bulk Results for progress and Stop."
    $Script:TE_Timer = Start-AsyncWork -BulkName 'Team Editor' -BulkTotal $rows.Count `
        -Vars @{ TeamId = $team.id; Members = @($rows | ForEach-Object { @{ Id = $_.Id; UPN = $_.UPN; IsOwner = [bool]$_.IsOwner } }) } `
        -RefSeed @{ TeamName = $team.displayName; Results = @() } `
        -Script {
            $headers = @{ Authorization = "Bearer $Token" }
            # Re-read now: anyone who joined after the list was built is skipped, not failed.
            $present = Get-EtbTeamMemberIds $TeamId $headers
            foreach ($m in $Members) {
                if ($Ref['CancelRequested']) { break }
                $role = if ($m.IsOwner) { 'owner' } else { 'member' }
                if ($present.Contains($m.Id)) {
                    $Ref['Results'] += [pscustomobject]@{ Id = $m.Id; Target = $m.UPN; Role = $role; Result = 'Skipped'; Detail = 'Already in the team.' }
                    if ($Ref['BulkQueue']) { $Ref['BulkQueue'].Enqueue([pscustomobject]@{ Time = (Get-Date -Format HH:mm:ss); Target = $m.UPN; Action = "Add $role"; Result = 'Skipped'; Detail = 'Already in the team.'; Retry = $null }) }
                    continue
                }
                try {
                    $body = @{
                        '@odata.type'     = '#microsoft.graph.aadUserConversationMember'
                        roles             = @(if ($m.IsOwner) { 'owner' })
                        'user@odata.bind' = "https://graph.microsoft.com/v1.0/users('$($m.Id)')"
                    } | ConvertTo-Json
                    $null = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/teams/$TeamId/members" -Method POST -Headers $headers -Body $body -ContentType 'application/json'
                    $Ref['Results'] += [pscustomobject]@{ Id = $m.Id; Target = $m.UPN; Role = $role; Result = 'Succeeded'; Detail = '' }
                    [void]$present.Add($m.Id)
                } catch {
                    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                    # Graph reports an existing member as a conflict; that is the outcome wanted.
                    $result = if ($status -eq 409 -or "$($_.ErrorDetails.Message) $($_.Exception.Message)" -match 'already (exist|a member)') { 'Skipped' } else { Get-EtbWriteResult $status }
                    $Ref['Results'] += [pscustomobject]@{ Id = $m.Id; Target = $m.UPN; Role = $role; Result = $result; Detail = $(if ($result -eq 'Skipped') { 'Already in the team.' } else { $_.Exception.Message }) }
                }
            }
        } `
        -OnComplete {
            param($ref)
            $Script:TE_Busy = $false
            foreach ($result in $ref.Results) {
                Write-EtbAudit -Tool 'Team Editor' -Action "Add $($result.Role)" -Target $result.Target -Result $result.Result -Detail "Team $($ref.TeamName). $($result.Detail)"
                if ($result.Result -in 'Succeeded', 'Skipped') {
                    [void]$Script:TE_MemberIds.Add($result.Id)
                    $row = $Script:TE_Rows | Where-Object Id -eq $result.Id | Select-Object -First 1
                    if ($row) { [void]$Script:TE_Rows.Remove($row) }
                } else {
                    Write-AppLog "Team Editor: $($result.Target) not added — $($result.Detail)" 'Danger'
                }
            }
            $ok = @($ref.Results | Where-Object Result -eq 'Succeeded').Count
            $skipped = @($ref.Results | Where-Object Result -eq 'Skipped').Count
            $failed = $ref.Results.Count - $ok - $skipped
            $color = if ($failed -or $ref.CancelRequested -or $ref.Error) { 'Warning' } else { 'Success' }
            $Script:TE_UI.Status.Text = "$ok added to $($ref.TeamName); $skipped already in the team; $failed failed.$(if ($ref.CancelRequested) { ' Stopped before the end.' }) $($ref.Error) People not added stay in the list."
            Set-MainStatus "Team Editor: $ok added, $failed failed." $color
            Update-TeState
        }
}

$Script:TeXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
      Background="#12121C">
  <Grid.Resources>
    <Style x:Key="OwnerCheckBox" TargetType="CheckBox">
      <Setter Property="HorizontalAlignment" Value="Center"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border Background="Transparent" Padding="5,3">
              <Border x:Name="Box" Width="18" Height="18" CornerRadius="3"
                      Background="#242436" BorderBrush="#7878A0" BorderThickness="1">
                <Path x:Name="Check" Data="M 2,7 L 6,11 L 13,3" Stroke="#E2E2F0"
                      StrokeThickness="2.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                      Margin="1" Visibility="Collapsed"/>
              </Border>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Check" Property="Visibility" Value="Visible"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="#6366F1"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Box" Property="BorderThickness" Value="2"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="#6366F1"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="#6366F1"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Grid.Resources>
  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="290" MinWidth="200"/>
    <ColumnDefinition Width="5"/>
    <ColumnDefinition Width="*"/>
  </Grid.ColumnDefinitions>
  <GridSplitter Grid.Column="1" Width="5" HorizontalAlignment="Stretch"
                Background="#3C3C5A" Cursor="SizeWE" ResizeBehavior="PreviousAndNext"/>

  <Border Grid.Column="0" Background="#1C1C2A">
    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <StackPanel Margin="12">
        <StackPanel x:Name="TeTeamPicker">
          <TextBlock Text="Team" Foreground="#7878A0" Margin="0,0,0,6"/>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBox x:Name="TeSearch" AutomationProperties.Name="Team name to search for"/>
            <Button x:Name="TeFind" Grid.Column="1" Content="Search" Style="{StaticResource EtbAction}" Margin="8,0,0,0"/>
          </Grid>
          <ListBox x:Name="TeTeams" Height="160" DisplayMemberPath="displayName" Margin="0,8,0,16" AutomationProperties.Name="Matching teams"/>
        </StackPanel>
        <StackPanel x:Name="TePicker" IsEnabled="False">
          <TextBlock Text="Year group" Foreground="#7878A0" Margin="0,0,0,6"/>
          <ComboBox x:Name="TeYears" Style="{StaticResource EtbPopulationCombo}" AutomationProperties.Name="Year group"/>
          <Button x:Name="TeAddYear" Content="Add missing from year group" Style="{StaticResource EtbAction}" Margin="0,8,0,12"/>
          <TextBlock Text="Department" Foreground="#7878A0" Margin="0,0,0,6"/>
          <ComboBox x:Name="TeDepartments" Style="{StaticResource EtbPopulationCombo}" AutomationProperties.Name="Department"/>
          <Button x:Name="TeAddDepartment" Content="Add missing from department" Style="{StaticResource EtbAction}" Margin="0,8,0,12"/>
          <TextBlock Text="Office" Foreground="#7878A0" Margin="0,0,0,6"/>
          <ComboBox x:Name="TeOffices" Style="{StaticResource EtbPopulationCombo}" AutomationProperties.Name="Office location"/>
          <Button x:Name="TeAddOffice" Content="Add missing from office" Style="{StaticResource EtbAction}" Margin="0,8,0,12"/>
          <TextBlock Text="Find users" Foreground="#7878A0" Margin="0,0,0,6"/>
          <TextBox x:Name="TeUserSearch" AutomationProperties.Name="Find users"/>
          <ListBox x:Name="TeMatches" Height="100" DisplayMemberPath="userPrincipalName" SelectionMode="Extended" Margin="0,6,0,8"/>
          <Button x:Name="TeAddUsers" Content="Add selected users" Style="{StaticResource EtbAction}"/>
        </StackPanel>
      </StackPanel>
    </ScrollViewer>
  </Border>

  <Grid Grid.Column="2" Margin="16">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <Border x:Name="TeBanner" Background="#242436" BorderBrush="#3C3C5A" BorderThickness="1" CornerRadius="8" Margin="0,0,0,12">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <Border x:Name="TeBannerBar" Background="#3C3C5A" CornerRadius="7,0,0,7"/>
        <StackPanel Grid.Column="1" Margin="16,12,12,12">
          <TextBlock Text="SELECTED TEAM" Foreground="#50507A" FontSize="10" FontWeight="Bold"/>
          <TextBlock x:Name="TeBannerName" Text="No team selected" Foreground="#7878A0" FontSize="20" FontWeight="SemiBold"
                     TextTrimming="CharacterEllipsis" Margin="0,2,0,4"/>
          <TextBlock x:Name="TeBannerInfo" Foreground="#7878A0" FontSize="12" TextWrapping="Wrap"/>
        </StackPanel>
        <Border x:Name="TeBannerBadge" Grid.Column="2" Background="#2A2A50" CornerRadius="12" Padding="12,4"
                Margin="0,0,16,0" VerticalAlignment="Center" Visibility="Collapsed">
          <TextBlock x:Name="TeBannerCount" Foreground="#E2E2F0" FontSize="12" FontWeight="SemiBold"/>
        </Border>
      </Grid>
    </Border>
    <TextBlock x:Name="TeStatus" Grid.Row="1" Foreground="#7878A0" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <DataGrid x:Name="TeGrid" Grid.Row="2" AutoGenerateColumns="False" CanUserAddRows="False" SelectionMode="Extended"
              RowStyle="{StaticResource DgRow}" CellStyle="{StaticResource DgCell}"
              VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
      <DataGrid.Columns>
        <DataGridTextColumn Header="Display Name"   Binding="{Binding DisplayName}" Width="*"    IsReadOnly="True"/>
        <DataGridTextColumn Header="Username (UPN)" Binding="{Binding UPN}"         Width="1.4*" IsReadOnly="True"/>
        <DataGridTextColumn Header="Department"     Binding="{Binding Department}"  Width="90"   IsReadOnly="True"/>
        <DataGridTextColumn Header="Office"         Binding="{Binding Office}"      Width="110"  IsReadOnly="True"/>
        <DataGridTemplateColumn Header="Owner" Width="70" SortMemberPath="IsOwner">
          <DataGridTemplateColumn.CellTemplate>
            <DataTemplate>
              <CheckBox Style="{StaticResource OwnerCheckBox}" AutomationProperties.Name="Team owner"
                        IsChecked="{Binding IsOwner, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"/>
            </DataTemplate>
          </DataGridTemplateColumn.CellTemplate>
        </DataGridTemplateColumn>
      </DataGrid.Columns>
    </DataGrid>
    <WrapPanel Grid.Row="3" Margin="0,12,0,0">
      <TextBlock x:Name="TeCount" Foreground="#E2E2F0" VerticalAlignment="Center" Margin="0,0,12,0"/>
      <Button x:Name="TeApply" Content="Add to team" Style="{StaticResource EtbAction}" IsEnabled="False"/>
      <Button x:Name="TeRemove" Content="Remove selected" Style="{StaticResource EtbAction}" IsEnabled="False"/>
      <Button x:Name="TeClear" Content="Clear list" Style="{StaticResource EtbAction}" IsEnabled="False"/>
    </WrapPanel>
  </Grid>
</Grid>
'@

function Initialize-TeamEditorTool {
    $reader = [Xml.XmlReader]::Create([IO.StringReader]::new((Invoke-ThemeXaml $Script:TeXaml)))
    try { $panel = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    $Script:TE_UI = @{}
    foreach ($key in 'TeamPicker','Search','Find','Teams','Picker','Years','AddYear','Departments','AddDepartment','Offices','AddOffice','UserSearch','Matches','AddUsers','Status','Grid','Count','Apply','Remove','Clear','Banner','BannerBar','BannerName','BannerInfo','BannerBadge','BannerCount') {
        $Script:TE_UI[$key] = $panel.FindName("Te$key")
    }
    $Script:TE_UI.Grid.ItemsSource = $Script:TE_Rows

    $Script:TE_UI.Find.Add_Click({
        try { Start-TeSearch } catch { Write-Log "TE search error: $_" 'ERROR' }
    })
    $Script:TE_UI.Search.Add_KeyDown({
        param($searchSender, $searchEvent)
        if ($searchEvent.Key -ne 'Return') { return }
        $searchEvent.Handled = $true
        try { Start-TeSearch } catch { Write-Log "TE search error: $_" 'ERROR' }
    })
    $Script:TE_UI.Teams.Add_SelectionChanged({
        try { Start-TeMembersLoad } catch { Write-Log "TE team selection error: $_" 'ERROR' }
    })
    $Script:TE_UI.AddYear.Add_Click({ Add-TeUsers @($Script:TE_UI.Years.SelectedItem.DataContext.Users) })
    $Script:TE_UI.AddDepartment.Add_Click({ Add-TeUsers @($Script:TE_UI.Departments.SelectedItem.DataContext.Users) })
    $Script:TE_UI.AddOffice.Add_Click({ Add-TeUsers @($Script:TE_UI.Offices.SelectedItem.DataContext.Users) })
    $Script:TE_UI.UserSearch.Add_TextChanged({ Invoke-EtbDebounced -Key 'TE_UserSearch' -Command 'Update-TeUserSearch' })
    $Script:TE_UI.AddUsers.Add_Click({ Add-TeUsers @($Script:TE_UI.Matches.SelectedItems) })
    $Script:TE_UI.Matches.Add_MouseDoubleClick({ Add-TeUsers @($Script:TE_UI.Matches.SelectedItems) })
    $Script:TE_UI.Remove.Add_Click({
        foreach ($row in @($Script:TE_UI.Grid.SelectedItems)) { [void]$Script:TE_Rows.Remove($row) }
        Update-TeState
    })
    $Script:TE_UI.Clear.Add_Click({ $Script:TE_Rows.Clear(); Update-TeState })
    $Script:TE_UI.Apply.Add_Click({
        try { Start-TeApply } catch { Write-Log "TE apply error: $_" 'ERROR' }
    })

    Register-ConnectCallback 'Start-TeLoad'
    $Script:ResetCallbacks.Add({
        Stop-EtbAsyncWork $Script:TE_Timer; Stop-EtbAsyncWork $Script:TE_SearchTimer
        $Script:TE_Busy = $false; $Script:TE_MemberIds = $null; $Script:TE_MemberError = $null
        $Script:TE_Teams = @(); $Script:TE_Users = @(); $Script:TE_Rows.Clear()
        $Script:TE_UI.Search.Text = ''; $Script:TE_UI.UserSearch.Text = ''
        $Script:TE_UI.Teams.ItemsSource = @(); $Script:TE_UI.Matches.ItemsSource = @()
        foreach ($combo in 'Years','Departments','Offices') { $Script:TE_UI[$combo].Items.Clear(); $Script:TE_UI[$combo].IsEnabled = $false }
        $Script:TE_UI.Status.Text = 'Connect to a tenant, then search for a team.'
        Update-TeState
    })
    $Script:TE_UI.Status.Text = 'Connect to a tenant, then search for a team.'
    Update-TeState
    return $panel
}
