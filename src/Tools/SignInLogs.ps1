<#
    Sign-In Log Viewer tab for Art's Entra Toolbox.
    Dot-sourced by Start.ps1.
    Exposes Initialize-SignInLogsTool.

    Browses paged sign-ins for a selected user. Requires AuditLog.Read.All.
#>

# ── Script-level state ─────────────────────────────────────────────────────────
$Script:SL_UI        = $null
$Script:SL_AllUsers  = @()
$Script:SL_LogsTimer = $null

# ── Log helper ─────────────────────────────────────────────────────────────────
function Write-SlLog {
    param([string]$Msg, [string]$Color = 'TextDim')
    Write-AppLog $Msg $Color
}

# ── Async user load ────────────────────────────────────────────────────────────
function Start-SlUserLoad {
    if ($Script:DemoMode) { Start-SlUserLoadDemo; return }
    $Script:SL_UI.UserSearch.IsEnabled = $false
    $Script:SL_UI.UserList.IsEnabled   = $false
    Clear-EtbList $Script:SL_UI.UserList
    Set-MainStatus 'Loading users...' 'TextDim'
    Write-SlLog 'Fetching users from Entra ID...' 'TextDim'

    Request-EtbUsers -OnReady 'Complete-SlUserLoad'
}

function Complete-SlUserLoad {
    try {
        if ($Script:UserCache.Error -eq '401') {
            Write-Log 'SignInLogs: user load 401 - session expired' 'ERROR'
            Write-SlLog 'Session expired - reconnect via the tenant selector.' 'Danger'
            Set-MainStatus 'Session expired.' 'Danger'
            return
        }
        if ($Script:UserCache.Error) {
            Write-Log "SignInLogs: user load failed - $($Script:UserCache.Error)" 'ERROR'
            Write-SlLog "Error loading users: $($Script:UserCache.Error)" 'Danger'
            Set-MainStatus 'Failed to load users.' 'Danger'
            return
        }

        $Script:SL_AllUsers = @($Script:UserCache.Users |
            Sort-Object { $_.displayName })
        Update-SlUserFilter
        $Script:SL_UI.UserSearch.IsEnabled = $true
        $Script:SL_UI.UserList.IsEnabled   = $true
        $n = $Script:SL_AllUsers.Count
        Write-Log "SignInLogs: loaded $n users" 'INFO'
        Write-SlLog "Loaded $n users." 'Success'
        Set-MainStatus "Loaded $n users." 'Success'
    } catch {
        Write-Log "SignInLogs user-load error: $_" 'ERROR'
    }
}

function Update-SlUserFilter {
    $filter = $Script:SL_UI.UserSearch.Text.Trim()
    Clear-EtbList $Script:SL_UI.UserList
    $list = if ([string]::IsNullOrWhiteSpace($filter)) {
        $Script:SL_AllUsers
    } else {
        $Script:SL_AllUsers | Where-Object {
            $_.displayName       -like "*$filter*" -or
            $_.userPrincipalName -like "*$filter*"
        }
    }
    Set-EtbListItems -List $Script:SL_UI.UserList -Items @(foreach ($u in $list) {
        [pscustomobject]@{ Content = $u.displayName; Tag = $u; ToolTip = $u.userPrincipalName }
    })
}


$Script:SL_Entries = @()
$Script:SL_Next = $null
$Script:SL_Request = 0
$Script:SL_Busy = $false

function Get-SlQuery {
    param([string]$UserId, [datetime]$From, [datetime]$To)
    if ($From.Date -gt $To.Date) { throw 'Start date must be on or before end date.' }
    $start = $From.Date.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $end = $To.Date.AddDays(1).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $filter = "userId eq '$($UserId.Replace("'", "''"))' and createdDateTime ge $start and createdDateTime lt $end"
    'https://graph.microsoft.com/v1.0/auditLogs/signIns?$filter=' + [uri]::EscapeDataString($filter) + '&$top=50&$orderby=createdDateTime desc&$select=id,createdDateTime,appDisplayName,status,ipAddress,location,deviceDetail,correlationId,conditionalAccessStatus'
}

function ConvertTo-SlRows {
    param([object[]]$Entries, [bool]$FailuresOnly = $false, [string]$Filter = '')
    foreach ($entry in $Entries) {
        $code = $entry.status.errorCode
        if ($FailuresOnly -and ($null -eq $code -or $code -eq 0)) { continue }
        $row = [pscustomobject]@{
            DateTime = ([datetime]$entry.createdDateTime).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
            Application = $entry.appDisplayName
            Result = if ($null -eq $code) { 'Unknown' } elseif ($code -eq 0) { 'Success' } else { "Failure ($code)" }
            FailureReason = $entry.status.failureReason
            AdditionalDetails = $entry.status.additionalDetails
            IpAddress = $entry.ipAddress
            Location = @($entry.location.city, $entry.location.countryOrRegion | Where-Object { $_ }) -join ', '
            Device = $entry.deviceDetail.displayName
            ConditionalAccess = $entry.conditionalAccessStatus
            CorrelationId = $entry.correlationId
            SignInId = $entry.id
        }
        if ($Filter -and ($row.PSObject.Properties.Value -join ' ').IndexOf($Filter, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $row
    }
}

function Update-SlResults {
    $rows = @(ConvertTo-SlRows $Script:SL_Entries ([bool]$Script:SL_UI.Failures.IsChecked) $Script:SL_UI.Filter.Text.Trim())
    $Script:SL_UI.LogsGrid.ItemsSource = $rows
    $Script:SL_UI.LogsGrid.Visibility = 'Visible'
    $Script:SL_UI.LogsPlaceholder.Visibility = 'Collapsed'
    $Script:SL_UI.Count.Text = "$($rows.Count) shown / $($Script:SL_Entries.Count) loaded. $(if ($Script:SL_Next) { 'More records available.' } else { 'End of available records.' })"
    $Script:SL_UI.More.IsEnabled = [bool]$Script:SL_Next -and -not $Script:SL_Busy
    $Script:SL_UI.Export.IsEnabled = $rows.Count -gt 0
}

function Reset-SlResults {
    Stop-EtbAsyncWork $Script:SL_LogsTimer
    $Script:SL_Request++
    $Script:SL_Busy = $false
    $Script:SL_Entries = @(); $Script:SL_Next = $null
    Update-SlResults
    $Script:SL_UI.Count.Text = 'Select a user, choose dates and click Search.'
}

function Start-SlLogsLoad {
    param([string]$UserId, [switch]$More)
    if (-not $UserId) { return }
    if (-not $Script:SL_UI.From.SelectedDate -or -not $Script:SL_UI.To.SelectedDate) { $Script:SL_UI.Count.Text = 'Choose both dates.'; return }
    try { $url = Get-SlQuery $UserId $Script:SL_UI.From.SelectedDate $Script:SL_UI.To.SelectedDate }
    catch { $Script:SL_UI.Count.Text = $_.Exception.Message; return }
    if ($More) {
        if ($Script:SL_Busy -or -not $Script:SL_Next) { return }
        $url = $Script:SL_Next
    } else { Reset-SlResults }
    $Script:SL_Busy = $true
    $Script:SL_UI.More.IsEnabled = $false
    $Script:SL_UI.Count.Text = 'Loading sign-ins…'
    $Script:SL_Request++
    if ($Script:DemoMode) {
        $offset = if ($More) { 50 } else { 0 }
        $entries = @(for ($i = $offset; $i -lt [math]::Min(70, $offset + 50); $i++) {
            [pscustomobject]@{ id = "demo-$i"; createdDateTime = $Script:SL_UI.To.SelectedDate.Date.AddHours(18).AddMinutes(-$i * 2).ToUniversalTime().ToString('o'); appDisplayName = 'Microsoft Teams'; status = @{ errorCode = if ($i % 4) { 0 } else { 50126 }; failureReason = if ($i % 4) { '' } else { 'Invalid username or password.' }; additionalDetails = '' }; ipAddress = '192.0.2.10'; location = @{ city = 'London'; countryOrRegion = 'GB' }; deviceDetail = @{ displayName = 'Classroom PC' }; correlationId = "demo-correlation-$i"; conditionalAccessStatus = 'notApplied' }
        })
        Complete-SlPage @{ UserId=$UserId; Request=$Script:SL_Request; Entries=$entries; Next= $(if (-not $More) { 'demo-next' }) }
        return
    }
    $Script:SL_LogsTimer = Start-AsyncWork -Vars @{ Url = $url } -RefSeed @{ UserId = $UserId; Request = $Script:SL_Request } -Script {
        $page = Invoke-RestMethod -Uri $Url -Headers @{ Authorization = "Bearer $Token" }
        $Ref['Entries'] = @($page.value); $Ref['Next'] = $page.'@odata.nextLink'
    } -OnComplete { param($ref); Complete-SlPage $ref }
}

function Complete-SlPage {
    param($Ref)
    if ($Ref.Request -ne $Script:SL_Request -or $Ref.UserId -ne $Script:SL_UI.UserList.SelectedItem.Tag.id) { return }
    $Script:SL_Busy = $false
    if ($Ref.Error) {
        Update-SlResults
        $Script:SL_UI.Count.Text = "Could not load sign-ins: $($Ref.Error). Check AuditLog.Read.All consent, your role and Entra sign-in licensing. Previously loaded rows are retained."
        return
    }
    $ids = [Collections.Generic.HashSet[string]]::new()
    foreach ($e in $Script:SL_Entries) { [void]$ids.Add($e.id) }
    $Script:SL_Entries += @($Ref.Entries | Where-Object { $ids.Add($_.id) })
    $Script:SL_Next = $Ref.Next
    Update-SlResults
}

$Script:SlXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Background="#12121C">
  <Grid.Resources></Grid.Resources>
  <Grid.ColumnDefinitions><ColumnDefinition Width="260" MinWidth="200"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
  <Border Background="#1C1C2A"><Grid Margin="12"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><TextBox x:Name="SlUserSearch" IsEnabled="False" AutomationProperties.Name="Find a user" Margin="0,0,0,8"/><ListBox x:Name="SlUserList" Grid.Row="1" IsEnabled="False"/></Grid></Border>
  <GridSplitter Grid.Column="1" Width="5" HorizontalAlignment="Stretch" Background="#3C3C5A"/>
  <Grid Grid.Column="2" Margin="16"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <StackPanel><WrapPanel><TextBlock Text="From" Foreground="#E2E2F0" VerticalAlignment="Center" Margin="0,0,8,8"/><DatePicker x:Name="SlFrom" Width="135" Margin="0,0,12,8" AutomationProperties.Name="Start date"/><TextBlock Text="To" Foreground="#E2E2F0" VerticalAlignment="Center" Margin="0,0,8,8"/><DatePicker x:Name="SlTo" Width="135" Margin="0,0,12,8" AutomationProperties.Name="End date"/><Button x:Name="SlSearch" Content="Search" Style="{StaticResource EtbAction}"/></WrapPanel>
      <TextBlock Text="Dates and times use this PC's timezone. Available history depends on tenant retention and licensing." Foreground="#7878A0" TextWrapping="Wrap" Margin="0,0,0,8"/>
      <WrapPanel><CheckBox x:Name="SlFailures" Content="Failures only (loaded records)" Foreground="#E2E2F0" VerticalAlignment="Center" Margin="0,0,12,8"/><TextBox x:Name="SlFilter" Width="220" AutomationProperties.Name="Filter loaded records by app, IP or reason" ToolTip="Filter loaded records by app, IP, device or failure reason" Margin="0,0,0,8"/></WrapPanel>
    </StackPanel>
    <TextBlock x:Name="SlCount" Grid.Row="1" Foreground="#7878A0" TextWrapping="Wrap" Margin="0,0,0,8"/>
    <TextBlock x:Name="SlLogsPlaceholder" Grid.Row="2" Visibility="Collapsed"/>
    <DataGrid x:Name="SlLogsGrid" Grid.Row="2" AutoGenerateColumns="False" IsReadOnly="True" RowStyle="{StaticResource DgRow}" CellStyle="{StaticResource DgCell}">
      <DataGrid.Columns>
        <DataGridTextColumn Header="Date / time" Binding="{Binding DateTime}" Width="150"/><DataGridTextColumn Header="Application" Binding="{Binding Application}" Width="150"/><DataGridTextColumn Header="Result" Binding="{Binding Result}" Width="130"/><DataGridTextColumn Header="Failure reason" Binding="{Binding FailureReason}" Width="280"/><DataGridTextColumn Header="Additional details" Binding="{Binding AdditionalDetails}" Width="240"/><DataGridTextColumn Header="IP" Binding="{Binding IpAddress}" Width="130"/><DataGridTextColumn Header="Location" Binding="{Binding Location}" Width="150"/><DataGridTextColumn Header="Device" Binding="{Binding Device}" Width="150"/><DataGridTextColumn Header="Conditional Access" Binding="{Binding ConditionalAccess}" Width="140"/><DataGridTextColumn Header="Correlation ID" Binding="{Binding CorrelationId}" Width="260"/>
      </DataGrid.Columns>
    </DataGrid>
    <WrapPanel Grid.Row="3" Margin="0,12,0,0"><Button x:Name="SlMore" Content="Load more" Style="{StaticResource EtbAction}" IsEnabled="False"/><Button x:Name="SlExport" Content="Export shown records" Style="{StaticResource EtbAction}" IsEnabled="False"/></WrapPanel>
  </Grid>
</Grid>
'@

function Initialize-SignInLogsTool {
    $reader = [Xml.XmlReader]::Create([IO.StringReader]::new((Invoke-ThemeXaml $Script:SlXaml)))
    try { $panel = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    $Script:SL_UI = @{}
    foreach ($key in 'UserSearch','UserList','LogsPlaceholder','LogsGrid','From','To','Search','Failures','Filter','Count','More','Export') { $Script:SL_UI[$key] = $panel.FindName("Sl$key") }
    $Script:SL_UI.From.SelectedDate = [datetime]::Today.AddDays(-7)
    $Script:SL_UI.To.SelectedDate = [datetime]::Today
    $Script:SL_UI.UserSearch.Add_TextChanged({ Invoke-EtbDebounced -Key 'SL_User' -Command 'Update-SlUserFilter' })
    $Script:SL_UI.UserList.Add_SelectionChanged({ Reset-SlResults; if ($Script:SL_UI.UserList.SelectedItem) { Start-SlLogsLoad $Script:SL_UI.UserList.SelectedItem.Tag.id } })
    $Script:SL_UI.Search.Add_Click({ Start-SlLogsLoad $Script:SL_UI.UserList.SelectedItem.Tag.id })
    $Script:SL_UI.From.Add_SelectedDateChanged({ Reset-SlResults })
    $Script:SL_UI.To.Add_SelectedDateChanged({ Reset-SlResults })
    $Script:SL_UI.More.Add_Click({ Start-SlLogsLoad $Script:SL_UI.UserList.SelectedItem.Tag.id -More })
    $Script:SL_UI.Failures.Add_Click({ Update-SlResults })
    $Script:SL_UI.Filter.Add_TextChanged({ Update-SlResults })
    $Script:SL_UI.Export.Add_Click({ Export-EtbRows @($Script:SL_UI.LogsGrid.ItemsSource) 'sign-ins' })
    Register-ConnectCallback 'Start-SlUserLoad'
    $Script:ResetCallbacks.Add({
        Reset-SlResults; $Script:SL_AllUsers = @(); Clear-EtbList $Script:SL_UI.UserList
        $Script:SL_UI.UserSearch.Text = ''; $Script:SL_UI.UserSearch.IsEnabled = $false; $Script:SL_UI.UserList.IsEnabled = $false
    })
    Reset-SlResults
    return $panel
}
