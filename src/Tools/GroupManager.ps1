$Script:GM_UI=$null
$Script:GM_Roster=$null
$Script:GM_Groups=@()
$Script:GM_Plan=@()
$Script:GM_Busy=$false
$Script:GM_Timer=$null
$Script:GM_GroupTimer=$null
$Script:GM_Snapshot=$null

function Invalidate-GmPlan {
    if (-not $Script:GM_UI -or $Script:GM_Busy) { return }
    $Script:GM_Plan=@(); $Script:GM_Snapshot=$null
    $Script:GM_UI.Grid.ItemsSource=@(); $Script:GM_UI.Apply.IsEnabled=$false
    $Script:GM_UI.Status.Text='Choose a group and desired users, then Preview. Existing owners and non-user members are preserved.'
}

function Set-GmBusy {
    param([bool]$Busy)
    $Script:GM_Busy=$Busy
    $Script:GM_UI.Editor.IsEnabled=-not $Busy
    $Script:GM_Roster.Panel.IsEnabled=-not $Busy -and $Script:GM_Roster.Users.Count -gt 0
    $Script:GM_UI.Apply.IsEnabled=$false
}

function Update-GmGroups {
    $filter=$Script:GM_UI.Search.Text.Trim()
    $Script:GM_UI.Groups.ItemsSource=@($Script:GM_Groups | Where-Object { -not $filter -or $_.displayName.IndexOf($filter,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or $_.id -eq $filter } | Sort-Object displayName)
}

function Start-GmUsers {
    if ($Script:DemoMode) { Complete-GmUsers } else { Request-EtbUsers -OnReady 'Complete-GmUsers' }
    if ($Script:DemoMode) {
        $Script:GM_Groups=@([pscustomobject]@{ id='demo-group'; displayName='Year 7 resources'; groupTypes=@(); securityEnabled=$true; mailEnabled=$false; isAssignableToRole=$false; onPremisesSyncEnabled=$false })
        Update-GmGroups; return
    }
    $Script:GM_UI.Status.Text='Loading groups…'
    $Script:GM_GroupTimer=Start-AsyncWork -Script {
        $Ref['Groups']=@(Get-EtbGraphCollection -Uri 'https://graph.microsoft.com/v1.0/groups?$select=id,displayName,groupTypes,securityEnabled,mailEnabled,isAssignableToRole,onPremisesSyncEnabled&$top=999' -Headers @{ Authorization="Bearer $Token" })
    } -OnComplete {
        param($ref)
        if ($ref.Error) { $Script:GM_UI.Status.Text="Groups unavailable: $($ref.Error)"; return }
        $Script:GM_Groups=@($ref.Groups)
        Update-GmGroups
        $Script:GM_UI.Status.Text='Groups loaded. Synced, dynamic and privileged groups cannot be changed here.'
    }
}

function Complete-GmUsers {
    if (-not $Script:DemoMode -and $Script:UserCache.Error) { $Script:GM_UI.Status.Text="Users unavailable: $($Script:UserCache.Error)"; return }
    Set-EtbRosterUsers $Script:GM_Roster $(if ($Script:DemoMode) { @($Script:Demo_Users) } else { @($Script:UserCache.Users) })
}

function Start-GmPreview {
    if ($Script:GM_Busy -or -not $Script:AccessToken) { return }
    $group=$Script:GM_UI.Groups.SelectedItem
    if (-not $group -or $Script:GM_Roster.ImportError) { $Script:GM_UI.Status.Text='Select a group and resolve any unmatched import first.'; return }
    $mode=[string]$Script:GM_UI.Mode.SelectedItem
    if ($mode -eq 'Match user roster' -and -not $Script:GM_Roster.Rows.Count) { $Script:GM_UI.Status.Text='Add at least one desired user before matching a roster.'; return }
    try { Assert-GmEditableGroup $group } catch { $Script:GM_UI.Status.Text=$_.Exception.Message; return }
    Invalidate-GmPlan; Set-GmBusy $true
    $desired=@($Script:GM_Roster.Rows)
    $Script:GM_UI.Status.Text='Reading current members and owners…'
    if ($Script:DemoMode) {
        $snapshot=@{ Group=$group; Members=@($Script:Demo_Users | Select-Object -First 4); Owners=@($Script:Demo_Users | Select-Object -First 1) }
        Complete-GmPreview @{ Snapshot=$snapshot; Desired=$desired; Mode=$mode; Plan=@(Get-GmPlan $snapshot.Members $desired $snapshot.Owners $mode) }
        return
    }
    $Script:GM_Timer=Start-AsyncWork -Vars @{ GroupId=$group.id; Desired=$desired; Mode=$mode } -RefSeed @{ Desired=$desired; Mode=$mode } -Script {
        $snapshot=Get-GmSnapshot $GroupId @{ Authorization="Bearer $Token" }
        $Ref['Snapshot']=$snapshot
        $Ref['Plan']=@(Get-GmPlan $snapshot.Members $Desired $snapshot.Owners $Mode)
    } -OnComplete { param($ref); Complete-GmPreview $ref }
}

function Complete-GmPreview {
    param($Ref)
    Set-GmBusy $false
    if ($Ref.Error) { $Script:GM_UI.Status.Text=$Ref.Error; return }
    $Script:GM_Plan=@($Ref.Plan)
    $Script:GM_Snapshot=@{ Group=$Ref.Snapshot.Group; Desired=$Ref.Desired; Mode=$Ref.Mode; Signature=(Get-GmPlanSignature $Script:GM_Plan) }
    $Script:GM_UI.Grid.ItemsSource=$Script:GM_Plan
    $add=@($Script:GM_Plan | Where-Object Action -eq 'Add').Count
    $remove=@($Script:GM_Plan | Where-Object Action -eq 'Remove').Count
    $Script:GM_UI.Status.Text="$($Ref.Snapshot.Group.displayName) [$($Ref.Snapshot.Group.id)]: $add add, $remove remove, $(@($Script:GM_Plan | Where-Object Action -eq 'Keep').Count) keep. Owners and non-user members are preserved."
    $Script:GM_UI.Apply.IsEnabled=($add+$remove) -gt 0
}

$Script:GmApplyWork = {
    $headers=@{ Authorization="Bearer $Token" }
    $current=Get-GmSnapshot $GroupId $headers
    $fresh=@(Get-GmPlan $current.Members $Desired $current.Owners $Mode)
    if ((Get-GmPlanSignature $fresh) -ne $Signature) { throw 'Group membership or ownership changed since preview. Preview again; no changes were made.' }
    foreach ($row in $fresh | Where-Object Action -in 'Add','Remove') {
        if ($Ref['CancelRequested']) { break }
        $result='Succeeded'; $detail=''
        try {
            if ($row.Action -eq 'Add') {
                $body=@{ '@odata.id'="https://graph.microsoft.com/v1.0/directoryObjects/$($row.Id)" } | ConvertTo-Json
                $null=Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/members/`$ref" -Method POST -Headers $headers -Body $body -ContentType 'application/json'
            } else {
                # The reference suffix is essential: never delete the directory object.
                $null=Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/members/$($row.Id)/`$ref" -Method DELETE -Headers $headers
            }
        } catch {
            $result=Get-EtbWriteResult $(if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 })
            $detail=$_.Exception.Message
        }
        $Ref['Results'] += [pscustomobject]@{ Id=$row.Id; Target=$row.Target; Action=$row.Action; Result=$result; Detail=$detail }
    }
}

function Start-GmApply {
    if ($Script:GM_Busy -or -not $Script:GM_Snapshot -or -not $Script:AccessToken) { return }
    $rows=@($Script:GM_Plan | Where-Object { $_.Action -in 'Add','Remove' -and $_.Result -eq 'Preview' })
    if (-not $rows.Count) { return }
    if ($Script:DryMode -or $Script:DemoMode) {
        foreach ($r in $rows) { $r.Result=if ($Script:DemoMode) { 'Demo' } else { 'Dry run' } }
        Publish-EtbBulkPreview 'Group Manager' $rows $(if ($Script:DemoMode) { 'Demo' } else { 'Dry run' })
        $Script:GM_UI.Grid.Items.Refresh(); $Script:GM_UI.Apply.IsEnabled=$false
        $Script:GM_UI.Status.Text="Preview only: $($rows.Count) membership changes. No tenant changes made."
        return
    }
    $snapshot=$Script:GM_Snapshot
    $remove=@($rows | Where-Object Action -eq 'Remove').Count
    if ([Windows.MessageBox]::Show("Apply to '$($snapshot.Group.displayName)' [$($snapshot.Group.id)]?`n$($rows.Count-$remove) additions and $remove removals. Removed users may lose access to group resources.", 'Apply group membership plan', 'YesNo', 'Question') -ne 'Yes') { return }
    Set-GmBusy $true
    $Script:GM_UI.Status.Text='Applying membership plan. Open Bulk Results for progress and Stop.'
    $Script:GM_Timer=Start-AsyncWork -BulkName 'Group Manager' -BulkTotal $rows.Count -Vars @{ GroupId=$snapshot.Group.id; Desired=$snapshot.Desired; Mode=$snapshot.Mode; Signature=$snapshot.Signature } -RefSeed @{ Results=@(); GroupId=$snapshot.Group.id } -Script $Script:GmApplyWork -OnComplete {
        param($ref)
        Set-GmBusy $false
        foreach ($result in $ref.Results) {
            $row=$Script:GM_Plan | Where-Object Id -eq $result.Id | Select-Object -First 1
            $row.Result=$result.Result; $row.Detail=$result.Detail
            Write-EtbAudit -Tool 'Group Manager' -Action "$($result.Action) member" -Target $result.Target -Result $result.Result -Detail "Group $($ref.GroupId). $($result.Detail)"
        }
        foreach ($row in $Script:GM_Plan | Where-Object { $_.Action -ne 'Keep' -and $_.Result -eq 'Preview' }) { $row.Result='Not run' }
        $Script:GM_UI.Grid.Items.Refresh()
        $Script:GM_UI.Status.Text="$(@($ref.Results | Where-Object Result -eq 'Succeeded').Count) succeeded; $(@($ref.Results | Where-Object Result -in 'Failed','Uncertain').Count) failed or uncertain. $($ref.Error) Preview again before another run."
    }
}

$Script:GmXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Background="#12121C">
  <Grid.Resources></Grid.Resources><Grid.ColumnDefinitions><ColumnDefinition Width="290"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
  <ContentControl x:Name="GmRoster"/>
  <Grid Grid.Column="1" Margin="16"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <StackPanel x:Name="GmEditor"><TextBlock Text="Find an existing group" Foreground="#7878A0" Margin="0,0,0,6"/><TextBox x:Name="GmSearch" AutomationProperties.Name="Search groups by name or ID"/><ComboBox x:Name="GmGroups" DisplayMemberPath="displayName" Style="{StaticResource EtbPopulationCombo}" Margin="0,8,0,12" AutomationProperties.Name="Existing group"/><WrapPanel><ComboBox x:Name="GmMode" Width="180" Style="{StaticResource EtbPopulationCombo}" Margin="0,0,12,8" AutomationProperties.Name="Membership comparison mode"/><Button x:Name="GmPreview" Content="Preview" Style="{StaticResource EtbAction}"/></WrapPanel></StackPanel>
    <TextBlock x:Name="GmStatus" Grid.Row="1" Foreground="#7878A0" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <DataGrid x:Name="GmGrid" Grid.Row="2" AutoGenerateColumns="False" IsReadOnly="True" RowStyle="{StaticResource DgRow}" CellStyle="{StaticResource DgCell}"><DataGrid.Columns><DataGridTextColumn Header="User" Binding="{Binding Target}" Width="2*"/><DataGridTextColumn Header="Action" Binding="{Binding Action}" Width="80"/><DataGridTextColumn Header="Result" Binding="{Binding Result}" Width="100"/><DataGridTextColumn Header="Detail" Binding="{Binding Detail}" Width="2*"/></DataGrid.Columns></DataGrid>
    <WrapPanel Grid.Row="3" Margin="0,12,0,0"><Button x:Name="GmApply" Content="Apply plan" Style="{StaticResource EtbAction}" IsEnabled="False"/><Button x:Name="GmExport" Content="Export plan / results" Style="{StaticResource EtbAction}"/></WrapPanel>
  </Grid>
</Grid>
'@

function Initialize-GroupManagerTool {
    $reader=[Xml.XmlReader]::Create([IO.StringReader]::new((Invoke-ThemeXaml $Script:GmXaml)))
    try { $panel=[Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    $Script:GM_UI=@{}
    foreach ($key in 'Roster','Editor','Search','Groups','Mode','Preview','Status','Grid','Apply','Export') { $Script:GM_UI[$key]=$panel.FindName("Gm$key") }
    $Script:GM_Roster=Initialize-EtbRoster 'Invalidate-GmPlan'
    $Script:GM_UI.Roster.Content=$Script:GM_Roster.Panel
    $Script:GM_UI.Mode.ItemsSource=@('Add missing','Match user roster'); $Script:GM_UI.Mode.SelectedIndex=0
    $Script:GM_UI.Search.Add_TextChanged({ Invoke-EtbDebounced -Key 'GM_Search' -Command 'Update-GmGroups' })
    $Script:GM_UI.Groups.Add_SelectionChanged({ Invalidate-GmPlan })
    $Script:GM_UI.Mode.Add_SelectionChanged({ Invalidate-GmPlan })
    $Script:GM_UI.Preview.Add_Click({ Start-GmPreview })
    $Script:GM_UI.Apply.Add_Click({ Start-GmApply })
    $Script:GM_UI.Export.Add_Click({ Export-EtbRows $Script:GM_Plan 'group-membership' })
    Register-ConnectCallback 'Start-GmUsers'
    $Script:ResetCallbacks.Add({
        Stop-EtbAsyncWork $Script:GM_Timer; Stop-EtbAsyncWork $Script:GM_GroupTimer
        Set-GmBusy $false; $Script:GM_Roster.Rows.Clear(); $Script:GM_Roster.Users=@(); $Script:GM_Roster.ImportError=$false
        $Script:GM_Roster.UI.Count.Text='0 selected users'; $Script:GM_Roster.UI.Status.Text='Connect to load users.'; $Script:GM_Roster.UI.Search.Text=''
        $Script:GM_Roster.UI.Matches.ItemsSource=@(); $Script:GM_Roster.UI.Years.ItemsSource=@(); $Script:GM_Roster.UI.Departments.ItemsSource=@(); $Script:GM_Roster.Panel.IsEnabled=$false
        $Script:GM_Groups=@(); $Script:GM_UI.Groups.ItemsSource=@(); Invalidate-GmPlan
    })
    Invalidate-GmPlan
    return $panel
}
