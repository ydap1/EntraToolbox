# Assigned-membership security groups; all directory writes run in a worker.
$Script:SG_UI = $null
$Script:SG_Users = @()
$Script:SG_Devices = @()
$Script:SG_DeviceTimer = $null
$Script:SG_Rows = [System.Collections.ObjectModel.ObservableCollection[PSObject]]::new()
$Script:SG_Busy = $false
$Script:SG_GroupId = $null
$Script:SG_Timer = $null

$Script:SgXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Background="#12121C">
  <Grid.Resources>
    <Style x:Key="SgButton" TargetType="Button">
      <Setter Property="Foreground" Value="#E2E2F0"/>
      <Setter Property="Background" Value="#242436"/>
      <Setter Property="BorderBrush" Value="#3C3C5A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="Margin" Value="0,4,0,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value><ControlTemplate TargetType="Button">
          <Border x:Name="Surface" Background="{TemplateBinding Background}"
                  BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                  CornerRadius="5" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Surface" Property="Opacity" Value="0.8"/></Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Surface" Property="BorderBrush" Value="#6366F1"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Surface" Property="Opacity" Value="0.4"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SgLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#7878A0"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,14,0,6"/>
    </Style>
  </Grid.Resources>
  <Grid.ColumnDefinitions><ColumnDefinition Width="290"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
  <Border Grid.Column="0" Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="0,0,1,0">
    <ScrollViewer VerticalScrollBarVisibility="Auto">
      <StackPanel x:Name="SgEditor" Margin="16">
        <TextBlock Text="Group details" Foreground="#E2E2F0" FontSize="18" FontWeight="SemiBold"/>
        <TextBlock Text="Group name" Style="{StaticResource SgLabel}"/>
        <TextBox x:Name="SgName" MaxLength="256" AutomationProperties.Name="Group name"/>
        <TextBlock Text="Description (optional)" Style="{StaticResource SgLabel}"/>
        <TextBox x:Name="SgDescription" MaxLength="1024" Height="60" AcceptsReturn="True" TextWrapping="Wrap" AutomationProperties.Name="Group description"/>
        <TextBlock Text="Add a year group" Style="{StaticResource SgLabel}"/>
        <ComboBox x:Name="SgYears" Style="{StaticResource EtbPopulationCombo}" DisplayMemberPath="Label" AutomationProperties.Name="Year groups"/>
        <Button x:Name="SgAddYear" Content="Add year group" Style="{StaticResource SgButton}" IsEnabled="False"/>
        <TextBlock Text="Add a department" Style="{StaticResource SgLabel}"/>
        <ComboBox x:Name="SgDepartments" Style="{StaticResource EtbPopulationCombo}" DisplayMemberPath="Label" AutomationProperties.Name="Departments"/>
        <Button x:Name="SgAddDepartment" Content="Add department" Style="{StaticResource SgButton}" IsEnabled="False"/>
        <TextBlock Text="Find individual users" Style="{StaticResource SgLabel}"/>
        <TextBox x:Name="SgSearch" AutomationProperties.Name="Search by name or username"/>
        <ListBox x:Name="SgMatches" Height="110" Margin="0,6,0,0" SelectionMode="Extended" DisplayMemberPath="userPrincipalName" AutomationProperties.Name="Matching users"/>
        <Button x:Name="SgAddUsers" Content="Add selected users" Style="{StaticResource SgButton}"/>
        <Button x:Name="SgImport" Content="Paste users / import CSV…" Style="{StaticResource SgButton}" Margin="0,14,0,0"/>
        <TextBlock Text="Find Entra devices" Style="{StaticResource SgLabel}"/>
        <TextBox x:Name="SgDeviceSearch" ToolTip="Search by name, device ID or Entra object ID" AutomationProperties.Name="Search devices by name, device ID or object ID"/>
        <ListBox x:Name="SgDeviceMatches" Height="130" Margin="0,6,0,0" SelectionMode="Extended" AutomationProperties.Name="Matching devices">
          <ListBox.ItemTemplate><DataTemplate><StackPanel>
            <TextBlock Text="{Binding displayName}" FontWeight="SemiBold"/>
            <TextBlock Text="{Binding operatingSystem}" FontSize="11"/>
            <TextBlock Text="{Binding id}" FontSize="10" ToolTip="Entra object ID"/>
          </StackPanel></DataTemplate></ListBox.ItemTemplate>
        </ListBox>
        <TextBlock x:Name="SgDeviceStatus" Text="Connect to load devices." TextWrapping="Wrap" Foreground="#7878A0" FontSize="11" Margin="0,6,0,0"/>
        <Button x:Name="SgAddDevices" Content="Add selected devices" Style="{StaticResource SgButton}"/>
        <Button x:Name="SgReloadDevices" Content="Reload devices" Style="{StaticResource SgButton}" IsEnabled="False"/>
        <TextBlock Text="Ctrl/Shift selects multiple devices. Combine users and devices, or add devices only. Duplicates are skipped. Up to 50 device matches are shown; narrow your search if needed." TextWrapping="Wrap" Foreground="#7878A0" FontSize="11" Margin="0,8,0,0"/>
        <Button x:Name="SgCreate" Content="Create security group" Style="{StaticResource SgButton}" Background="#6366F1" FontWeight="SemiBold" Margin="0,20,0,0" IsEnabled="False"/>
      </StackPanel>
    </ScrollViewer>
  </Border>
  <Grid Grid.Column="1" Margin="18,16">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock x:Name="SgCount" Text="0 members" Foreground="#E2E2F0" FontSize="18" FontWeight="SemiBold"/>
    <TextBlock Grid.Row="1" Text="Review members before creating an assigned-membership security group." Foreground="#7878A0" TextWrapping="Wrap" Margin="0,6,0,14"/>
    <DataGrid x:Name="SgGrid" Grid.Row="2" HeadersVisibility="Column" SelectionMode="Extended"
              RowStyle="{StaticResource DgRow}" CellStyle="{StaticResource DgCell}">
      <DataGrid.Columns>
        <DataGridTextColumn Header="Name" Binding="{Binding DisplayName}" Width="*"/>
        <DataGridTextColumn Header="Type" Binding="{Binding MemberType}" Width="70"/>
        <DataGridTextColumn Header="Username / device ID" Binding="{Binding Identifier}" Width="1.3*"/>
        <DataGridTextColumn Header="Department / OS" Binding="{Binding Department}" Width="*"/>
        <DataGridTextColumn Header="Result" Binding="{Binding Result}" Width="100"/>
      </DataGrid.Columns>
    </DataGrid>
    <StackPanel Grid.Row="3" Margin="0,10,0,0">
      <WrapPanel>
        <Button x:Name="SgRemove" Content="Remove selected" Style="{StaticResource SgButton}" Margin="0,0,8,0"/>
        <Button x:Name="SgClear" Content="Clear all" Style="{StaticResource SgButton}" Margin="0,0,8,0" IsEnabled="False"
                ToolTip="Empty the member list; keep the group name and description"/>
        <Button x:Name="SgNew" Content="New group" Style="{StaticResource SgButton}" Margin="0"/>
      </WrapPanel>
      <TextBlock x:Name="SgStatus" Text="Connect to a tenant to load users." Foreground="#7878A0" TextWrapping="Wrap" Margin="0,12,0,0"/>
    </StackPanel>
  </Grid>
</Grid>
'@

function Update-SgControls {
    $editable = -not $Script:SG_Busy -and -not $Script:SG_GroupId
    $Script:SG_UI.Editor.IsEnabled = $editable
    $Script:SG_UI.Remove.IsEnabled = $editable
    $Script:SG_UI.Clear.IsEnabled = $editable -and $Script:SG_Rows.Count -gt 0
    $Script:SG_UI.New.IsEnabled = -not $Script:SG_Busy
    $Script:SG_UI.Create.IsEnabled = $editable -and [bool]$Script:AccessToken -and
        -not [string]::IsNullOrWhiteSpace($Script:SG_UI.Name.Text)
    $Script:SG_UI.Count.Text = "$($Script:SG_Rows.Count) members"
}

function Add-SgMembers {
    param([object[]]$Members, [ValidateSet('User', 'Device')][string]$MemberType)
    if ($Script:SG_Busy -or $Script:SG_GroupId) { return }
    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $Script:SG_Rows) { [void]$ids.Add($row.Id) }
    foreach ($member in $Members) {
        if ($member.id -and $ids.Add($member.id)) {
            $Script:SG_Rows.Add([pscustomobject]@{
                Id = $member.id; DisplayName = $member.displayName; MemberType = $MemberType
                Identifier = if ($MemberType -eq 'Device') { $member.deviceId } else { $member.userPrincipalName }
                Department = if ($MemberType -eq 'Device') { $member.operatingSystem } else { $member.department }
                Result = 'Pending'
            })
        }
    }
    Update-SgControls
}

function Add-SgUsers {
    param([object[]]$Users)
    Add-SgMembers -Members $Users -MemberType User
}

function Add-SgDevices {
    param([object[]]$Devices)
    Add-SgMembers -Members $Devices -MemberType Device
}

function Update-SgDeviceSearch {
    if (-not $Script:SG_UI) { return }
    $query = $Script:SG_UI.DeviceSearch.Text.Trim()
    $Script:SG_UI.DeviceMatches.ItemsSource = @($Script:SG_Devices | Where-Object {
        -not $query -or
        ([string]$_.displayName).IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        ([string]$_.deviceId).IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        ([string]$_.id).IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0
    } | Select-Object -First 50)
}

$Script:SgDeviceLoadWork = {
    $Ref['Devices'] = @(Get-EtbGraphCollection -Uri 'https://graph.microsoft.com/v1.0/devices?$select=id,deviceId,displayName,operatingSystem' -Headers @{ Authorization = "Bearer $Token" })
}

function Start-SgDeviceLoad {
    if ($Script:SG_DeviceTimer -or -not $Script:AccessToken) { return }
    $Script:SG_Devices = @()
    Update-SgDeviceSearch
    if ($Script:DemoMode) {
        $Script:SG_Devices = @($Script:Demo_DirectoryDevices)
        $Script:SG_UI.DeviceStatus.Text = "$($Script:SG_Devices.Count) demo devices loaded."
        $Script:SG_UI.ReloadDevices.IsEnabled = $true
        Update-SgDeviceSearch
        return
    }
    $Script:SG_UI.ReloadDevices.IsEnabled = $false
    $Script:SG_UI.DeviceStatus.Text = 'Loading Entra devices…'
    $Script:SG_DeviceTimer = Start-AsyncWork -RefSeed @{ Devices = @() } -Script $Script:SgDeviceLoadWork -OnComplete {
        param($ref)
        $Script:SG_DeviceTimer = $null
        $Script:SG_UI.ReloadDevices.IsEnabled = $true
        if ($ref['Error']) {
            $Script:SG_UI.DeviceStatus.Text = "Could not load devices: $($ref['Error']). Check Device.Read.All consent and reload. User selection is still available."
        } else {
            $Script:SG_Devices = @($ref['Devices'])
            $Script:SG_UI.DeviceStatus.Text = "$($Script:SG_Devices.Count) Entra devices loaded."
        }
        Update-SgDeviceSearch
    }
}

function Update-SgSearch {
    if (-not $Script:SG_UI) { return }
    $query = $Script:SG_UI.Search.Text.Trim()
    $matches = if ($query) {
        @($Script:SG_Users | Where-Object {
            ([string]$_.displayName).IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            ([string]$_.userPrincipalName).IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0
        } | Select-Object -First 50)
    } else { @() }
    $Script:SG_UI.Matches.ItemsSource = @($matches)
}

function Complete-SgUserLoad {
    if (-not $Script:DemoMode -and $Script:UserCache.Error) {
        $Script:SG_UI.Status.Text = "Could not load users: $($Script:UserCache.Error)"
        return
    }
    $Script:SG_Users = if ($Script:DemoMode) { @($Script:Demo_Users) } else { @($Script:UserCache.Users) }
    $Script:SG_UI.Years.ItemsSource = @(Get-EtbPopulationChoices -Users $Script:SG_Users -Mode YearGroup)
    $Script:SG_UI.Departments.ItemsSource = @(Get-EtbPopulationChoices -Users $Script:SG_Users -Mode Department)
    foreach ($key in 'Years', 'Departments') {
        if ($Script:SG_UI[$key].Items.Count -gt 0) { $Script:SG_UI[$key].SelectedIndex = 0 }
    }
    $Script:SG_UI.Status.Text = "$($Script:SG_Users.Count) users loaded. Add members or create an empty group."
    Update-SgSearch
    Update-SgControls
}

function Start-SgUserLoad {
    Start-SgDeviceLoad
    if ($Script:DemoMode) { Complete-SgUserLoad; return }
    $Script:SG_UI.Status.Text = 'Loading directory users…'
    Request-EtbUsers -OnReady 'Complete-SgUserLoad'
}

# Keep this block directly executable with mocked Graph calls in offline tests.
$Script:SgCreateWork = {
    $headers = @{ Authorization = "Bearer $Token" }
    $body = @{
        displayName = $GroupName; description = $Description
        mailEnabled = $false; securityEnabled = $true; groupTypes = @()
        mailNickname = 'sg-' + [guid]::NewGuid().ToString('N')
    } | ConvertTo-Json
    $group = Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/groups' -Method POST -Headers $headers -Body $body -ContentType 'application/json'
    if (-not $group.id) { throw 'Group creation returned no ID. Check Entra before trying again.' }
    $Ref['GroupId'] = $group.id
    foreach ($member in $Members) {
        try {
            $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($member.Id)" } | ConvertTo-Json
            $null = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)/members/`$ref" -Method POST -Headers $headers -Body $body -ContentType 'application/json'
            $Ref['Results'] += [pscustomobject]@{ Id = $member.Id; Target = $member.Target; Result = 'Added'; Error = '' }
        } catch {
            $Ref['Results'] += [pscustomobject]@{ Id = $member.Id; Target = $member.Target; Result = 'Failed'; Error = $_.Exception.Message }
        }
    }
}

function Start-SgCreate {
    if ($Script:SG_Busy -or $Script:SG_GroupId -or -not $Script:AccessToken) { return }
    $name = $Script:SG_UI.Name.Text.Trim()
    if (-not $name) { return }
    if ($Script:DemoMode -or $Script:DryMode) {
        $prefix = if ($Script:DemoMode) { '[DEMO]' } else { '[DRY]' }
        $Script:SG_UI.Status.Text = "$prefix Would create '$name' with $($Script:SG_Rows.Count) members. No changes made."
        Write-AppLog $Script:SG_UI.Status.Text 'Warning'
        return
    }
    $answer = [System.Windows.MessageBox]::Show("Create security group '$name' with $($Script:SG_Rows.Count) members?", 'Create security group', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    $Script:SG_Busy = $true
    Update-SgControls
    $Script:SG_UI.Status.Text = "Creating '$name' and adding members…"
    $Script:SG_Timer = Start-AsyncWork -Vars @{
        GroupName = $name; Description = $Script:SG_UI.Description.Text.Trim()
        Members = @($Script:SG_Rows | ForEach-Object { [pscustomobject]@{
            Id = $_.Id; Target = "$($_.MemberType): $($_.DisplayName) [$($_.Identifier)] (object $($_.Id))"
        } })
    } -RefSeed @{ GroupName = $name; GroupId = $null; Results = @() } -Script $Script:SgCreateWork -OnComplete {
        param($ref)
        $Script:SG_Busy = $false
        $Script:SG_GroupId = $ref['GroupId']
        foreach ($result in $ref['Results']) {
            $row = $Script:SG_Rows | Where-Object Id -eq $result.Id | Select-Object -First 1
            if ($row) { $row.Result = $result.Result }
            if ($result.Error) { Write-AppLog "$($result.Target): $($result.Error)" 'Danger' }
            Write-EtbAudit -Tool 'Security Group Creator' -Action 'Add member' -Target $result.Target -Result $result.Result -Detail "Group $($ref['GroupId']). $($result.Error)"
        }
        $Script:SG_UI.Grid.Items.Refresh()
        $added = @($ref['Results'] | Where-Object Result -eq 'Added').Count
        $failed = @($ref['Results'] | Where-Object Result -eq 'Failed').Count
        if ($ref['GroupId']) {
            $message = "Created '$($ref['GroupName'])' ($($ref['GroupId'])). $added added, $failed failed."
            if ($ref['Error']) { $message += " Interrupted: $($ref['Error'])" }
            $result = if ($failed -or $ref['Error']) { 'Partial' } else { 'OK' }
        } else {
            $message = "Creation failed: $($ref['Error']). Check Entra before retrying; the request may have reached the server."
            $result = 'Failed'
        }
        $Script:SG_UI.Status.Text = $message
        Write-AppLog $message $(if ($result -eq 'OK') { 'Success' } else { 'Warning' })
        Write-EtbAudit -Tool 'Security Group Creator' -Action 'Create group' -Target $ref['GroupName'] -Result $result -Detail $message
        Update-SgControls
    }
}

function Clear-SgMembers {
    if ($Script:SG_Busy -or $Script:SG_GroupId) { return }
    $Script:SG_Rows.Clear()
    $Script:SG_UI.Status.Text = 'Member list cleared. Add users or devices to start again.'
    Update-SgControls
}

function Reset-SgForm {
    $Script:SG_GroupId = $null
    $Script:SG_Rows.Clear()
    $Script:SG_UI.Name.Clear()
    $Script:SG_UI.Description.Clear()
    $Script:SG_UI.Search.Clear()
    $Script:SG_UI.DeviceSearch.Clear()
    $Script:SG_UI.DeviceMatches.UnselectAll()
    $Script:SG_UI.Status.Text = 'Add members and enter a group name.'
    Update-SgControls
}

function Initialize-SecurityGroupCreatorTool {
    $reader = [Xml.XmlReader]::Create([IO.StringReader]::new((Invoke-ThemeXaml $Script:SgXaml)))
    try { $content = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    $Script:SG_UI = @{}
    foreach ($key in 'Editor','Name','Description','Years','AddYear','Departments','AddDepartment','Search','Matches','AddUsers','Import','DeviceSearch','DeviceMatches','DeviceStatus','AddDevices','ReloadDevices','Create','Count','Grid','Remove','Clear','New','Status') {
        $Script:SG_UI[$key] = $content.FindName("Sg$key")
    }
    $Script:SG_UI.Grid.ItemsSource = $Script:SG_Rows
    $Script:SG_UI.Name.Add_TextChanged({ Update-SgControls })
    $Script:SG_UI.Search.Add_TextChanged({ Invoke-EtbDebounced -Key 'SG_Search' -Command 'Update-SgSearch' })
    $Script:SG_UI.DeviceSearch.Add_TextChanged({ Invoke-EtbDebounced -Key 'SG_DeviceSearch' -Command 'Update-SgDeviceSearch' })
    $Script:SG_UI.AddDevices.Add_Click({ Add-SgDevices @($Script:SG_UI.DeviceMatches.SelectedItems) })
    $Script:SG_UI.ReloadDevices.Add_Click({ Start-SgDeviceLoad })
    $Script:SG_UI.Years.Add_SelectionChanged({ $Script:SG_UI.AddYear.IsEnabled = $null -ne $Script:SG_UI.Years.SelectedItem })
    $Script:SG_UI.Departments.Add_SelectionChanged({ $Script:SG_UI.AddDepartment.IsEnabled = $null -ne $Script:SG_UI.Departments.SelectedItem })
    $Script:SG_UI.AddYear.Add_Click({
        $choice = $Script:SG_UI.Years.SelectedItem
        if ($choice) { Add-SgUsers $choice.Users }
    })
    $Script:SG_UI.AddDepartment.Add_Click({
        $choice = $Script:SG_UI.Departments.SelectedItem
        if ($choice) { Add-SgUsers $choice.Users }
    })
    $Script:SG_UI.AddUsers.Add_Click({ Add-SgUsers @($Script:SG_UI.Matches.SelectedItems) })
    $Script:SG_UI.Import.Add_Click({
        $upns = @(Show-EtbUpnImport)
        if (-not $upns.Count) { return }
        $selection = Select-EtbUsersByUpn -Users $Script:SG_Users -Upns $upns
        Add-SgUsers $selection.Matched
        $Script:SG_UI.Status.Text = "$($selection.Matched.Count) matched; $($selection.Missing.Count) not found."
        foreach ($upn in $selection.Missing) { Write-AppLog "User not found: $upn" 'Warning' }
    })
    $Script:SG_UI.Remove.Add_Click({
        foreach ($row in @($Script:SG_UI.Grid.SelectedItems)) { [void]$Script:SG_Rows.Remove($row) }
        Update-SgControls
    })
    $Script:SG_UI.New.Add_Click({ Reset-SgForm })
    $Script:SG_UI.Clear.Add_Click({ Clear-SgMembers })
    $Script:SG_UI.Create.Add_Click({ Start-SgCreate })
    Register-ConnectCallback 'Start-SgUserLoad'
    $Script:ResetCallbacks.Add({
        if ($Script:SG_Timer) { $Script:SG_Timer.Stop(); $Script:SG_Timer = $null }
        if ($Script:SG_DeviceTimer) { $Script:SG_DeviceTimer.Stop(); $Script:SG_DeviceTimer = $null }
        $Script:SG_Busy = $false
        $Script:SG_Users = @()
        $Script:SG_Devices = @()
        $Script:SG_UI.DeviceMatches.ItemsSource = @()
        $Script:SG_UI.DeviceStatus.Text = 'Connect to load devices.'
        $Script:SG_UI.ReloadDevices.IsEnabled = $false
        $Script:SG_UI.Years.ItemsSource = @()
        $Script:SG_UI.Departments.ItemsSource = @()
        $Script:SG_UI.Matches.ItemsSource = @()
        Reset-SgForm
        $Script:SG_UI.Create.IsEnabled = $false
        $Script:SG_UI.Status.Text = 'Connect to a tenant to load users.'
    })
    return $content
}
