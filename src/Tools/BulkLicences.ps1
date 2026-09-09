$Script:BL_UI = $null
$Script:BL_Roster = $null
$Script:BL_Busy = $false
$Script:BL_Plan = @()
$Script:BL_Timer = $null
$Script:BL_SkuTimer = $null

function Invalidate-BlPlan {
    if (-not $Script:BL_UI -or $Script:BL_Busy) { return }
    $Script:BL_Plan = @(); $Script:BL_UI.Grid.ItemsSource = @()
    $Script:BL_UI.Apply.IsEnabled = $false
    $Script:BL_UI.Status.Text = 'Select users, a licence and an action, then Preview.'
}

function Set-BlBusy {
    param([bool]$Busy)
    $Script:BL_Busy = $Busy
    $Script:BL_Roster.Panel.IsEnabled = -not $Busy -and $Script:BL_Roster.Users.Count -gt 0
    $Script:BL_UI.Editor.IsEnabled = -not $Busy
    $Script:BL_UI.Apply.IsEnabled = $false
}

function Start-BlUsers {
    if ($Script:DemoMode) { Complete-BlUsers } else { Request-EtbUsers -OnReady 'Complete-BlUsers' }
    $Script:BL_UI.Status.Text = 'Loading licences…'
    if ($Script:DemoMode) {
        $Script:BL_UI.Sku.ItemsSource = @([pscustomobject]@{ skuId='demo-student'; skuPartNumber='STANDARDWOFFPACK_STUDENT'; Label='Microsoft 365 A1 for Students'; consumedUnits=20; prepaidUnits=@{ enabled=500 }; capabilityStatus='Enabled' })
        $Script:BL_UI.Sku.SelectedIndex = 0
        return
    }
    $Script:BL_SkuTimer = Start-AsyncWork -Script {
        $Ref['Skus'] = @(Get-EtbGraphCollection -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus' -Headers @{ Authorization="Bearer $Token" })
    } -OnComplete {
        param($ref)
        if ($ref.Error) { $Script:BL_UI.Status.Text = "Licences unavailable: $($ref.Error)"; return }
        $Script:BL_UI.Sku.ItemsSource = @($ref.Skus | Where-Object capabilityStatus -eq 'Enabled' | ForEach-Object {
            $_ | Add-Member NoteProperty Label (Get-LaSkuLabel $_.skuPartNumber (Get-BlAvailableSeats $_)) -PassThru
        })
        if ($Script:BL_UI.Sku.Items.Count) { $Script:BL_UI.Sku.SelectedIndex = 0 }
    }
}

function Complete-BlUsers {
    if (-not $Script:DemoMode -and $Script:UserCache.Error) { $Script:BL_UI.Status.Text = "Users unavailable: $($Script:UserCache.Error)"; return }
    Set-EtbRosterUsers $Script:BL_Roster $(if ($Script:DemoMode) { @($Script:Demo_Users) } else { @($Script:UserCache.Users) })
}

$Script:BlPreviewWork = {
    $headers = @{ Authorization="Bearer $Token" }
    $skus = @(Get-EtbGraphCollection -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus' -Headers $headers)
    $sku = $skus | Where-Object skuId -eq $SkuId | Select-Object -First 1
    if (-not $sku -or $sku.capabilityStatus -ne 'Enabled') { throw 'The selected licence is not available. Reconnect to reload licences.' }
    $Ref['Available'] = Get-BlAvailableSeats $sku
    foreach ($user in $Users) {
        try {
            $current = Invoke-RestMethod -Uri ("https://graph.microsoft.com/v1.0/users/$($user.id)" + '?$select=id,userPrincipalName,usageLocation,assignedLicenses,licenseAssignmentStates') -Headers $headers
            $Ref['Plan'] += Get-BlPlanRow $current $SkuId $Action
        } catch { $Ref['Plan'] += [pscustomobject]@{ Id=$user.id; Target=$user.userPrincipalName; Action=$Action; Source='Unknown'; Result='Blocked'; Detail=$_.Exception.Message; SkuId=$SkuId } }
    }
}

$Script:BlApplyWork = {
    $headers = @{ Authorization="Bearer $Token" }
    if ($Action -eq 'Assign') {
        $sku = @(Get-EtbGraphCollection -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus' -Headers $headers) | Where-Object skuId -eq $SkuId | Select-Object -First 1
        if (-not $sku -or $sku.capabilityStatus -ne 'Enabled' -or (Get-BlAvailableSeats $sku) -lt $Rows.Count) { throw 'Available seats changed. Preview again before applying.' }
    }
    foreach ($row in $Rows) {
        if ($Ref['CancelRequested']) { break }
        $result = 'Skipped'; $detail = ''; $submitted = $false
        try {
            $current = Invoke-RestMethod -Uri ("https://graph.microsoft.com/v1.0/users/$($row.Id)" + '?$select=id,userPrincipalName,usageLocation,assignedLicenses,licenseAssignmentStates') -Headers $headers
            $fresh = Get-BlPlanRow $current $SkuId $Action
            if ($fresh.Result -ne 'Ready' -or $fresh.Source -ne $row.Source) { $detail = 'Assignment changed since preview. ' + $fresh.Detail }
            else {
                $body = if ($Action -eq 'Assign') { @{ addLicenses=@(@{ skuId=$SkuId; disabledPlans=@() }); removeLicenses=@() } }
                    else { @{ addLicenses=@(); removeLicenses=@($SkuId) } }
                $submitted = $true
                $null = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$($row.Id)/assignLicense" -Method POST -Headers $headers -Body ($body | ConvertTo-Json -Depth 5) -ContentType 'application/json'
                $result = 'Succeeded'; $detail = $fresh.Detail
            }
        } catch {
            $result = if ($submitted) { Get-EtbWriteResult $(if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }) } else { 'Failed' }
            $detail = $_.Exception.Message
        }
        $Ref['Results'] += [pscustomobject]@{ Id=$row.Id; Target=$row.Target; Result=$result; Detail=$detail }
    }
}

function Start-BlPreview {
    if ($Script:BL_Busy -or -not $Script:AccessToken) { return }
    $sku = $Script:BL_UI.Sku.SelectedItem
    if (-not $sku -or -not $Script:BL_Roster.Rows.Count -or $Script:BL_Roster.ImportError) { $Script:BL_UI.Status.Text = 'Choose a licence and users; resolve any unmatched import first.'; return }
    Invalidate-BlPlan
    Set-BlBusy $true
    $action = [string]$Script:BL_UI.Action.SelectedItem
    $Script:BL_UI.Status.Text = 'Reading current assignments and available seats…'
    if ($Script:DemoMode) {
        $plan = @(foreach ($u in $Script:BL_Roster.Rows) {
            $current = @{ id=$u.id; userPrincipalName=$u.userPrincipalName; usageLocation='GB'; assignedLicenses=@(); licenseAssignmentStates=@() }
            if ($action -eq 'Remove') { $current.licenseAssignmentStates = @(@{ skuId=$sku.skuId; assignedByGroup=$null }) }
            Get-BlPlanRow $current $sku.skuId $action
        })
        Complete-BlPreview @{ Plan=$plan; Available=480; SkuId=$sku.skuId; Action=$action }
        return
    }
    $Script:BL_Timer = Start-AsyncWork -Vars @{ Users=@($Script:BL_Roster.Rows); SkuId=$sku.skuId; Action=$action } -RefSeed @{ Plan=@(); SkuId=$sku.skuId; Action=$action } -Script $Script:BlPreviewWork -OnComplete { param($ref); Complete-BlPreview $ref }
}

function Complete-BlPreview {
    param($Ref)
    Set-BlBusy $false
    if ($Ref.Error) { $Script:BL_UI.Status.Text = $Ref.Error; return }
    $Script:BL_Plan = @($Ref.Plan)
    $ready = @($Script:BL_Plan | Where-Object Result -eq 'Ready').Count
    if ($Ref.Action -eq 'Assign' -and $ready -gt $Ref.Available) {
        foreach ($row in $Script:BL_Plan | Where-Object Result -eq 'Ready') { $row.Result='Blocked'; $row.Detail="Insufficient seats: $ready required, $($Ref.Available) available." }
        $ready = 0
    }
    $Script:BL_UI.Grid.ItemsSource = $Script:BL_Plan
    $Script:BL_UI.Status.Text = "$ready ready; $(@($Script:BL_Plan | Where-Object Result -eq 'Skip').Count) skipped; $(@($Script:BL_Plan | Where-Object Result -eq 'Blocked').Count) blocked. $($Ref.Available) seats available. Review each row before applying."
    $Script:BL_UI.Apply.IsEnabled = $ready -gt 0
}

function Start-BlApply {
    if ($Script:BL_Busy -or -not $Script:AccessToken) { return }
    $rows = @($Script:BL_Plan | Where-Object Result -eq 'Ready')
    if (-not $rows.Count) { return }
    if ($Script:DryMode -or $Script:DemoMode) {
        foreach ($row in $rows) { $row.Result = if ($Script:DemoMode) { 'Demo' } else { 'Dry run' } }
        Publish-EtbBulkPreview 'Bulk Licences' $rows $(if ($Script:DemoMode) { 'Demo' } else { 'Dry run' })
        $Script:BL_UI.Grid.Items.Refresh(); $Script:BL_UI.Apply.IsEnabled=$false
        $Script:BL_UI.Status.Text = "Preview only: $($rows.Count) assignments would change. No tenant changes made."
        return
    }
    $action = $rows[0].Action; $skuId = $rows[0].SkuId
    if ([Windows.MessageBox]::Show("$action '$($Script:BL_UI.Sku.SelectedItem.Label)' for $($rows.Count) users? Removing a direct licence can remove service access. Group-inherited assignments remain.", 'Apply licence plan', 'YesNo', 'Question') -ne 'Yes') { return }
    Set-BlBusy $true
    $Script:BL_UI.Status.Text = 'Applying licences. Open Bulk Results for progress and Stop.'
    $Script:BL_Timer = Start-AsyncWork -BulkName 'Bulk Licences' -BulkTotal $rows.Count -Vars @{ Rows=$rows; SkuId=$skuId; Action=$action } -RefSeed @{ Results=@(); Action=$action; SkuId=$skuId } -Script $Script:BlApplyWork -OnComplete {
        param($ref)
        Set-BlBusy $false
        foreach ($result in $ref.Results) {
            $row = $Script:BL_Plan | Where-Object Id -eq $result.Id | Select-Object -First 1
            $row.Result=$result.Result; $row.Detail=$result.Detail
            Write-EtbAudit -Tool 'Bulk Licences' -Action $ref.Action -Target $result.Target -Result $result.Result -Detail "SKU $($ref.SkuId). $($result.Detail)"
        }
        foreach ($row in $Script:BL_Plan | Where-Object Result -eq 'Ready') { $row.Result='Not run' }
        $Script:BL_UI.Grid.Items.Refresh()
        $Script:BL_UI.Status.Text = "$(@($ref.Results | Where-Object Result -eq 'Succeeded').Count) succeeded; $(@($ref.Results | Where-Object Result -in 'Failed','Uncertain').Count) failed or uncertain. $(if ($ref.Error) { $ref.Error }) Preview again to refresh assignments before another run."
    }
}

$Script:BlXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Background="#12121C">
  <Grid.Resources></Grid.Resources><Grid.ColumnDefinitions><ColumnDefinition Width="290"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
  <ContentControl x:Name="BlRoster"/>
  <Grid Grid.Column="1" Margin="16"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <StackPanel x:Name="BlEditor"><TextBlock Text="Licence" Foreground="#7878A0" Margin="0,0,0,6"/><ComboBox x:Name="BlSku" DisplayMemberPath="Label" Style="{StaticResource EtbPopulationCombo}" AutomationProperties.Name="Licence"/><WrapPanel Margin="0,12,0,0"><ComboBox x:Name="BlAction" Width="130" Style="{StaticResource EtbPopulationCombo}" Margin="0,0,12,8" AutomationProperties.Name="Assign or remove"/><Button x:Name="BlPreview" Content="Preview" Style="{StaticResource EtbAction}"/></WrapPanel></StackPanel>
    <TextBlock x:Name="BlStatus" Grid.Row="1" Foreground="#7878A0" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <DataGrid x:Name="BlGrid" Grid.Row="2" AutoGenerateColumns="False" IsReadOnly="True" RowStyle="{StaticResource DgRow}" CellStyle="{StaticResource DgCell}"><DataGrid.Columns><DataGridTextColumn Header="User" Binding="{Binding Target}" Width="2*"/><DataGridTextColumn Header="Action" Binding="{Binding Action}" Width="80"/><DataGridTextColumn Header="Assignment" Binding="{Binding Source}" Width="110"/><DataGridTextColumn Header="Result" Binding="{Binding Result}" Width="90"/><DataGridTextColumn Header="Detail" Binding="{Binding Detail}" Width="2*"/></DataGrid.Columns></DataGrid>
    <WrapPanel Grid.Row="3" Margin="0,12,0,0"><Button x:Name="BlApply" Content="Apply plan" Style="{StaticResource EtbAction}" IsEnabled="False"/><Button x:Name="BlExport" Content="Export plan / results" Style="{StaticResource EtbAction}"/></WrapPanel>
  </Grid>
</Grid>
'@

function Initialize-BulkLicencesTool {
    $reader = [Xml.XmlReader]::Create([IO.StringReader]::new((Invoke-ThemeXaml $Script:BlXaml)))
    try { $panel = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    $Script:BL_UI=@{}
    foreach ($key in 'Roster','Editor','Sku','Action','Preview','Status','Grid','Apply','Export') { $Script:BL_UI[$key]=$panel.FindName("Bl$key") }
    $Script:BL_Roster = Initialize-EtbRoster 'Invalidate-BlPlan'
    $Script:BL_UI.Roster.Content = $Script:BL_Roster.Panel
    $Script:BL_UI.Action.ItemsSource = @('Assign','Remove'); $Script:BL_UI.Action.SelectedIndex=0
    $Script:BL_UI.Sku.Add_SelectionChanged({ Invalidate-BlPlan })
    $Script:BL_UI.Action.Add_SelectionChanged({ Invalidate-BlPlan })
    $Script:BL_UI.Preview.Add_Click({ Start-BlPreview })
    $Script:BL_UI.Apply.Add_Click({ Start-BlApply })
    $Script:BL_UI.Export.Add_Click({ Export-EtbRows $Script:BL_Plan 'bulk-licences' })
    Register-ConnectCallback 'Start-BlUsers'
    $Script:ResetCallbacks.Add({
        Stop-EtbAsyncWork $Script:BL_Timer; Stop-EtbAsyncWork $Script:BL_SkuTimer
        Set-BlBusy $false; $Script:BL_Roster.Rows.Clear(); $Script:BL_Roster.Users=@(); $Script:BL_Roster.ImportError=$false
        $Script:BL_Roster.UI.Count.Text='0 selected users'; $Script:BL_Roster.UI.Status.Text='Connect to load users.'; $Script:BL_Roster.UI.Search.Text=''
        $Script:BL_Roster.UI.Matches.ItemsSource=@(); $Script:BL_Roster.UI.Years.ItemsSource=@(); $Script:BL_Roster.UI.Departments.ItemsSource=@()
        $Script:BL_Roster.Panel.IsEnabled=$false; $Script:BL_UI.Sku.ItemsSource=@(); Invalidate-BlPlan
    })
    Invalidate-BlPlan
    return $panel
}
