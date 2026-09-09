# One helpdesk view of a user; each section reports its own permission/load error.
$Script:UO_UI = $null
$Script:UO_Users = @()
$Script:UO_User = $null
$Script:UO_Timer = $null
$Script:UO_PendingId = $null

$Script:UoLoadWork = {
    $headers = @{ Authorization = "Bearer $Token" }
    $base = "https://graph.microsoft.com/v1.0/users/$UserId"
    $requests = [ordered]@{
        Profile = "$base" + '?$select=id,displayName,userPrincipalName,accountEnabled,department,officeLocation,jobTitle,userType,onPremisesSyncEnabled,usageLocation'
        Groups = "$base/memberOf" + '?$select=id,displayName&$top=999'
        Licences = "$base/licenseDetails" + '?$select=skuId,skuPartNumber&$top=999'
        Devices = "$base/managedDevices" + '?$select=id,deviceName,operatingSystem,complianceState,lastSyncDateTime&$top=100'
        SignIns = 'https://graph.microsoft.com/v1.0/auditLogs/signIns?$filter=' + [uri]::EscapeDataString("userId eq '$UserId'") + '&$top=10&$orderby=createdDateTime desc&$select=id,createdDateTime,appDisplayName,status'
    }
    foreach ($key in $requests.Keys) {
        try {
            if ($key -eq 'Profile') { $Ref[$key] = Invoke-RestMethod -Uri $requests[$key] -Headers $headers }
            elseif ($key -eq 'SignIns') { $Ref[$key] = @((Invoke-RestMethod -Uri $requests[$key] -Headers $headers).value) }
            else {
                $items = @(Get-EtbGraphCollection -Uri $requests[$key] -Headers $headers)
                if ($key -eq 'Groups') { $Ref[$key] = @($items | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' }) } else { $Ref[$key] = $items }
            }
        } catch { $Ref["${key}Error"] = $_.Exception.Message }
    }
}

function Start-UoUsers {
    if ($Script:DemoMode) { Complete-UoUsers; return }
    Request-EtbUsers -OnReady 'Complete-UoUsers'
}

function Complete-UoUsers {
    if (-not $Script:DemoMode -and $Script:UserCache.Error) { $Script:UO_UI.Summary.Text = "Users unavailable: $($Script:UserCache.Error)"; return }
    $Script:UO_Users = if ($Script:DemoMode) { @($Script:Demo_Users) } else { @($Script:UserCache.Users) }
    Update-UoFilter
}

function Update-UoFilter {
    if (-not $Script:UO_PendingId -and $Script:UO_UI.Users.SelectedItem) { $Script:UO_PendingId = $Script:UO_UI.Users.SelectedItem.id }
    $filter = $Script:UO_UI.Search.Text.Trim()
    $Script:UO_UI.Users.ItemsSource = @($Script:UO_Users | Where-Object { -not $filter -or $_.displayName.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $_.userPrincipalName.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Sort-Object displayName)
    if ($Script:UO_PendingId) {
        $Script:UO_UI.Users.SelectedItem = $Script:UO_Users | Where-Object id -eq $Script:UO_PendingId | Select-Object -First 1
        if ($Script:UO_UI.Users.SelectedItem) { $Script:UO_PendingId = $null }
    }
}

function Clear-UoDetails {
    Stop-EtbAsyncWork $Script:UO_Timer
    $Script:UO_User = $null
    $Script:UO_UI.Summary.Text = 'Select a user to view account details.'
    foreach ($key in 'Groups','Licences','Devices','SignIns') {
        $Script:UO_UI[$key].ItemsSource = @()
        $Script:UO_UI["${key}Status"].Text = ''
    }
    $Script:UO_UI.Actions.IsEnabled = $false
}

function Start-UoLoad {
    $user = $Script:UO_UI.Users.SelectedItem
    Clear-UoDetails
    if (-not $user) { return }
    $Script:UO_User = $user
    $Script:UO_UI.Summary.Text = "Loading $($user.userPrincipalName)…"
    $Script:UO_UI.Actions.IsEnabled = $true
    if ($Script:DemoMode) {
        $ref = @{ UserId = $user.id; Profile = $user; Groups = @(Get-DemoGroupsForUser $user.id); Licences = @([pscustomobject]@{ skuPartNumber='STANDARDWOFFPACK_STUDENT' }); Devices = @($Script:Demo_Devices | Where-Object { $_.usersLoggedOn.userId -contains $user.id }); SignIns = @([pscustomobject]@{ createdDateTime = [datetime]::UtcNow.ToString('o'); appDisplayName='Microsoft Teams'; status=@{ errorCode=0; failureReason='' } }) }
        Complete-UoLoad $ref
        return
    }
    $Script:UO_Timer = Start-AsyncWork -Vars @{ UserId = $user.id } -RefSeed @{ UserId = $user.id } -Script $Script:UoLoadWork -OnComplete { param($ref); Complete-UoLoad $ref }
}

function Complete-UoLoad {
    param($Ref)
    if (-not $Script:UO_User -or $Ref.UserId -ne $Script:UO_User.id) { return }
    $p = $Ref.Profile
    $Script:UO_UI.Summary.Text = if ($Ref.ProfileError -or $Ref.Error) { "Account details unavailable: $($Ref.ProfileError) $($Ref.Error)" } else {
        "$($p.displayName)  ·  $($p.userPrincipalName)`n$(if ($p.accountEnabled) { 'Enabled' } else { 'Disabled' })  ·  $(if ($p.onPremisesSyncEnabled) { 'Synced from on-premises' } else { 'Cloud managed' })  ·  $($p.userType)`nDepartment: $($p.department)  ·  Office: $($p.officeLocation)  ·  Usage location: $($p.usageLocation)`nUpdated $(Get-Date -Format 'HH:mm:ss')"
    }
    foreach ($key in 'Groups','Licences','Devices','SignIns') {
        $Script:UO_UI["${key}Status"].Text = if ($Ref["${key}Error"]) { "Unavailable: $($Ref["${key}Error"])" } else { "$(@($Ref[$key]).Count) $(if ($key -eq 'SignIns') { 'recent sign-ins (up to 10)' } else { $key.ToLower() })" }
    }
    $Script:UO_UI.Groups.ItemsSource = @($Ref.Groups | Select-Object displayName, id)
    $Script:UO_UI.Licences.ItemsSource = @($Ref.Licences | ForEach-Object { [pscustomobject]@{ Name = Get-LaSkuLabel $_.skuPartNumber; Sku = $_.skuPartNumber } })
    $Script:UO_UI.Devices.ItemsSource = @($Ref.Devices | Select-Object deviceName, operatingSystem, complianceState, lastSyncDateTime)
    $Script:UO_UI.SignIns.ItemsSource = @($Ref.SignIns | ForEach-Object { [pscustomobject]@{ Time = $_.createdDateTime; Application = $_.appDisplayName; Result = if ($_.status.errorCode -eq 0) { 'Success' } else { "$($_.status.errorCode): $($_.status.failureReason)" } } })
}

function Open-UoTool {
    param([string]$Tool)
    if (-not $Script:UO_User) { return }
    $upn = $Script:UO_User.userPrincipalName
    Set-NavSelection $Tool
    $box = switch ($Tool) {
        UserReset { $Script:UPR_UI.UserSearch }; LastDevice { $Script:LD_UI.UserSearch }
        SignIn { $Script:SL_UI.UserSearch }; Licence { $Script:LA_UI.UserSearch }; Leaver { $Script:LW_UI.UserSearch }
    }
    $box.Text = $upn
    $null = $box.Focus()
}

$Script:UoXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Background="#12121C">
  <Grid.Resources></Grid.Resources>
  <Grid.ColumnDefinitions><ColumnDefinition Width="260" MinWidth="200"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
  <Border Background="#1C1C2A"><Grid Margin="12"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><TextBox x:Name="UoSearch" AutomationProperties.Name="Find a user" Margin="0,0,0,8"/><ListBox x:Name="UoUsers" Grid.Row="1" DisplayMemberPath="userPrincipalName"/></Grid></Border>
  <GridSplitter Grid.Column="1" Width="5" HorizontalAlignment="Stretch" Background="#3C3C5A"/>
  <Grid Grid.Column="2" Margin="16"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
    <TextBlock x:Name="UoSummary" Foreground="#E2E2F0" FontSize="14" TextWrapping="Wrap" Margin="0,0,0,16"/>
    <WrapPanel x:Name="UoActions" Grid.Row="1" IsEnabled="False"><Button x:Name="UoRefresh" Content="Refresh" Style="{StaticResource EtbAction}"/><Button x:Name="UoReset" Content="Password reset" Style="{StaticResource EtbAction}"/><Button x:Name="UoDevice" Content="Devices" Style="{StaticResource EtbAction}"/><Button x:Name="UoSignIn" Content="Sign-ins" Style="{StaticResource EtbAction}"/><Button x:Name="UoLicence" Content="Licences" Style="{StaticResource EtbAction}"/><Button x:Name="UoLeaver" Content="Leaver" Style="{StaticResource EtbAction}"/></WrapPanel>
    <TabControl Grid.Row="2">
      <TabItem Header="Groups"><DockPanel><TextBlock x:Name="UoGroupsStatus" DockPanel.Dock="Top" Foreground="#7878A0" TextWrapping="Wrap" Margin="8"/><DataGrid x:Name="UoGroups" AutoGenerateColumns="False" IsReadOnly="True" RowStyle="{StaticResource DgRow}" CellStyle="{StaticResource DgCell}"><DataGrid.Columns><DataGridTextColumn Header="Group" Binding="{Binding displayName}" Width="*"/><DataGridTextColumn Header="ID" Binding="{Binding id}" Width="*"/></DataGrid.Columns></DataGrid></DockPanel></TabItem>
      <TabItem Header="Licences"><DockPanel><TextBlock x:Name="UoLicencesStatus" DockPanel.Dock="Top" Foreground="#7878A0" TextWrapping="Wrap" Margin="8"/><DataGrid x:Name="UoLicences" AutoGenerateColumns="False" IsReadOnly="True" RowStyle="{StaticResource DgRow}" CellStyle="{StaticResource DgCell}"><DataGrid.Columns><DataGridTextColumn Header="Licence" Binding="{Binding Name}" Width="*"/><DataGridTextColumn Header="SKU" Binding="{Binding Sku}" Width="*"/></DataGrid.Columns></DataGrid></DockPanel></TabItem>
      <TabItem Header="Devices"><DockPanel><TextBlock x:Name="UoDevicesStatus" DockPanel.Dock="Top" Foreground="#7878A0" TextWrapping="Wrap" Margin="8"/><DataGrid x:Name="UoDevices" AutoGenerateColumns="False" IsReadOnly="True" RowStyle="{StaticResource DgRow}" CellStyle="{StaticResource DgCell}"><DataGrid.Columns><DataGridTextColumn Header="Device" Binding="{Binding deviceName}" Width="*"/><DataGridTextColumn Header="OS" Binding="{Binding operatingSystem}" Width="*"/><DataGridTextColumn Header="Compliance" Binding="{Binding complianceState}" Width="*"/><DataGridTextColumn Header="Last sync" Binding="{Binding lastSyncDateTime}" Width="*"/></DataGrid.Columns></DataGrid></DockPanel></TabItem>
      <TabItem Header="Recent sign-ins"><DockPanel><TextBlock x:Name="UoSignInsStatus" DockPanel.Dock="Top" Foreground="#7878A0" TextWrapping="Wrap" Margin="8"/><DataGrid x:Name="UoSignIns" AutoGenerateColumns="False" IsReadOnly="True" RowStyle="{StaticResource DgRow}" CellStyle="{StaticResource DgCell}"><DataGrid.Columns><DataGridTextColumn Header="Time (UTC)" Binding="{Binding Time}" Width="*"/><DataGridTextColumn Header="Application" Binding="{Binding Application}" Width="*"/><DataGridTextColumn Header="Result" Binding="{Binding Result}" Width="2*"/></DataGrid.Columns></DataGrid></DockPanel></TabItem>
    </TabControl>
  </Grid>
</Grid>
'@

function Initialize-UserOverviewTool {
    $reader = [Xml.XmlReader]::Create([IO.StringReader]::new((Invoke-ThemeXaml $Script:UoXaml)))
    try { $panel = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    $Script:UO_UI = @{}
    foreach ($key in 'Search','Users','Summary','Actions','Refresh','Reset','Device','SignIn','Licence','Leaver','Groups','GroupsStatus','Licences','LicencesStatus','Devices','DevicesStatus','SignIns','SignInsStatus') { $Script:UO_UI[$key] = $panel.FindName("Uo$key") }
    $Script:UO_UI.Search.Add_TextChanged({ Invoke-EtbDebounced -Key 'UO_Search' -Command 'Update-UoFilter' })
    $Script:UO_UI.Users.Add_SelectionChanged({ Start-UoLoad })
    $Script:UO_UI.Refresh.Add_Click({ Start-UoLoad })
    $Script:UO_UI.Reset.Add_Click({ Open-UoTool 'UserReset' })
    $Script:UO_UI.Device.Add_Click({ Open-UoTool 'LastDevice' })
    $Script:UO_UI.SignIn.Add_Click({ Open-UoTool 'SignIn' })
    $Script:UO_UI.Licence.Add_Click({ Open-UoTool 'Licence' })
    $Script:UO_UI.Leaver.Add_Click({ Open-UoTool 'Leaver' })
    Register-ConnectCallback 'Start-UoUsers'
    $Script:ResetCallbacks.Add({
        Clear-UoDetails
        $Script:UO_Users = @(); $Script:UO_PendingId = $null
        $Script:UO_UI.Users.ItemsSource = @(); $Script:UO_UI.Search.Text = ''
    })
    Clear-UoDetails
    return $panel
}
