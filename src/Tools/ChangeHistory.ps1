$Script:CH_UI=$null
$Script:CH_Rows=@()
$Script:CH_Errors=@()
$Script:CH_Timer=$null

function Update-ChFilter {
    if (-not $Script:CH_UI.From.SelectedDate -or -not $Script:CH_UI.To.SelectedDate) { return }
    try {
        $operator=if ($Script:CH_UI.Operator.SelectedIndex -gt 0) { [string]$Script:CH_UI.Operator.SelectedItem } else { '' }
        $tool=if ($Script:CH_UI.Tool.SelectedIndex -gt 0) { [string]$Script:CH_UI.Tool.SelectedItem } else { '' }
        $shown=@(Select-EtbHistory $Script:CH_Rows $Script:CH_UI.From.SelectedDate $Script:CH_UI.To.SelectedDate $operator $tool $Script:CH_UI.Search.Text.Trim())
        $Script:CH_UI.Grid.ItemsSource=$shown
        $Script:CH_UI.Export.IsEnabled=$shown.Count -gt 0
        $Script:CH_UI.Status.Text="$($shown.Count) shown / $($Script:CH_Rows.Count) loaded for $(if ($Script:DemoMode) { 'offline demo' } else { $Script:CurrentTenantId }). $(if ($Script:CH_Errors.Count) { 'Some files could not be fully read; see the activity log.' })"
    } catch { $Script:CH_UI.Status.Text=$_.Exception.Message; $Script:CH_UI.Grid.ItemsSource=@(); $Script:CH_UI.Export.IsEnabled=$false }
}

function Complete-ChLoad {
    param($Ref)
    $Script:CH_UI.Reload.IsEnabled=$true
    $Script:CH_Rows=@($Ref.Rows); $Script:CH_Errors=@($Ref.Errors)
    if ($Ref.Error) { $Script:CH_Errors += $Ref.Error }
    foreach ($errorText in $Script:CH_Errors) { Write-AppLog "Change History: $errorText" 'Warning' }
    $operator=$Script:CH_UI.Operator.SelectedItem; $tool=$Script:CH_UI.Tool.SelectedItem
    $Script:CH_UI.Operator.ItemsSource=@('All operators') + @($Script:CH_Rows.Operator | Where-Object { $_ } | Sort-Object -Unique)
    $Script:CH_UI.Tool.ItemsSource=@('All tools') + @($Script:CH_Rows.Tool | Where-Object { $_ } | Sort-Object -Unique)
    $Script:CH_UI.Operator.SelectedItem=$operator; $Script:CH_UI.Tool.SelectedItem=$tool
    if ($Script:CH_UI.Operator.SelectedIndex -lt 0) { $Script:CH_UI.Operator.SelectedIndex=0 }
    if ($Script:CH_UI.Tool.SelectedIndex -lt 0) { $Script:CH_UI.Tool.SelectedIndex=0 }
    Update-ChFilter
}

function Start-ChLoad {
    Stop-EtbAsyncWork $Script:CH_Timer
    if ($Script:DemoMode) {
        Complete-ChLoad @{ Rows=@(
            [pscustomobject]@{ Timestamp=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); Operator='admin@contoso.edu'; Tenant='DEMO'; Tool='Group Manager'; Action='Add member'; Target='pupil@contoso.edu'; Result='Succeeded'; Detail='Group: Year 7 resources (example record)' }
            [pscustomobject]@{ Timestamp=(Get-Date).AddDays(-1).ToString('yyyy-MM-dd HH:mm:ss'); Operator='admin@contoso.edu'; Tenant='DEMO'; Tool='Bulk Licences'; Action='Assign'; Target='teacher@contoso.edu'; Result='Failed'; Detail='No seats available (example record)' }
        ); Errors=@() }
        return
    }
    if (-not $Script:CurrentTenantId) { $Script:CH_UI.Status.Text='Connect to a tenant to browse its local change history.'; return }
    $Script:CH_UI.Reload.IsEnabled=$false
    $Script:CH_UI.Status.Text='Reading local change records…'
    $Script:CH_Timer=Start-AsyncWork -NoToken -Vars @{ Directory=(Join-Path $Global:AppRoot 'config/audit'); Tenant=$Script:CurrentTenantId; ReaderText=${function:Read-EtbHistory}.ToString() } -Script {
        $history=& ([scriptblock]::Create($ReaderText)) -Directory $Directory -Tenant $Tenant
        $Ref['Rows']=$history.Rows; $Ref['Errors']=$history.Errors
    } -OnComplete { param($ref); Complete-ChLoad $ref }
}

$Script:ChXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Background="#12121C" Margin="16">
  <Grid.Resources></Grid.Resources><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <StackPanel><TextBlock Text="Changes recorded by this installation" Foreground="#E2E2F0" FontSize="18" Margin="0,0,0,8"/><TextBlock Text="Local toolbox activity for the selected tenant. This is not the tenant-wide Entra audit log. Dates use the time recorded by the PC that made the change." Foreground="#7878A0" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <WrapPanel><TextBlock Text="From" Foreground="#E2E2F0" VerticalAlignment="Center" Margin="0,0,8,8"/><DatePicker x:Name="ChFrom" Width="135" Margin="0,0,12,8" AutomationProperties.Name="Start date"/><TextBlock Text="To" Foreground="#E2E2F0" VerticalAlignment="Center" Margin="0,0,8,8"/><DatePicker x:Name="ChTo" Width="135" Margin="0,0,12,8" AutomationProperties.Name="End date"/><ComboBox x:Name="ChOperator" Width="210" Style="{StaticResource EtbPopulationCombo}" Margin="0,0,12,8" AutomationProperties.Name="Operator filter"/><ComboBox x:Name="ChTool" Width="180" Style="{StaticResource EtbPopulationCombo}" Margin="0,0,12,8" AutomationProperties.Name="Tool filter"/></WrapPanel>
    <TextBox x:Name="ChSearch" AutomationProperties.Name="Search users, actions or results" ToolTip="Search users, actions, results or details" Margin="0,0,0,12"/>
  </StackPanel>
  <TextBlock x:Name="ChStatus" Grid.Row="1" Foreground="#7878A0" TextWrapping="Wrap" Margin="0,0,0,12"/>
  <DataGrid x:Name="ChGrid" Grid.Row="2" AutoGenerateColumns="False" IsReadOnly="True" RowStyle="{StaticResource DgRow}" CellStyle="{StaticResource DgCell}"><DataGrid.Columns><DataGridTextColumn Header="Time" Binding="{Binding Timestamp}" Width="150"/><DataGridTextColumn Header="Operator" Binding="{Binding Operator}" Width="170"/><DataGridTextColumn Header="Tool" Binding="{Binding Tool}" Width="140"/><DataGridTextColumn Header="Action" Binding="{Binding Action}" Width="130"/><DataGridTextColumn Header="Target" Binding="{Binding Target}" Width="190"/><DataGridTextColumn Header="Result" Binding="{Binding Result}" Width="100"/><DataGridTextColumn Header="Detail" Binding="{Binding Detail}" Width="300"/></DataGrid.Columns></DataGrid>
  <WrapPanel Grid.Row="3" Margin="0,12,0,0"><Button x:Name="ChReload" Content="Refresh history" Style="{StaticResource EtbAction}"/><Button x:Name="ChExport" Content="Export shown records" Style="{StaticResource EtbAction}" IsEnabled="False"/></WrapPanel>
</Grid>
'@

function Initialize-ChangeHistoryTool {
    $reader=[Xml.XmlReader]::Create([IO.StringReader]::new((Invoke-ThemeXaml $Script:ChXaml)))
    try { $panel=[Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    $Script:CH_UI=@{}
    foreach ($key in 'From','To','Operator','Tool','Search','Status','Grid','Reload','Export') { $Script:CH_UI[$key]=$panel.FindName("Ch$key") }
    $Script:CH_UI.From.SelectedDate=[datetime]::Today.AddDays(-30); $Script:CH_UI.To.SelectedDate=[datetime]::Today
    $Script:CH_UI.From.Add_SelectedDateChanged({ Update-ChFilter })
    $Script:CH_UI.To.Add_SelectedDateChanged({ Update-ChFilter })
    $Script:CH_UI.Operator.Add_SelectionChanged({ Update-ChFilter })
    $Script:CH_UI.Tool.Add_SelectionChanged({ Update-ChFilter })
    $Script:CH_UI.Search.Add_TextChanged({ Invoke-EtbDebounced -Key 'CH_Search' -Command 'Update-ChFilter' })
    $Script:CH_UI.Reload.Add_Click({ Start-ChLoad })
    $Script:CH_UI.Export.Add_Click({ Export-EtbRows @($Script:CH_UI.Grid.ItemsSource) 'change-history' })
    Register-ConnectCallback 'Start-ChLoad'
    $Script:ResetCallbacks.Add({
        Stop-EtbAsyncWork $Script:CH_Timer; $Script:CH_Rows=@(); $Script:CH_Errors=@()
        $Script:CH_UI.Grid.ItemsSource=@(); $Script:CH_UI.Operator.ItemsSource=@(); $Script:CH_UI.Tool.ItemsSource=@()
        $Script:CH_UI.Search.Text=''; $Script:CH_UI.Export.IsEnabled=$false; $Script:CH_UI.Reload.IsEnabled=$true
        $Script:CH_UI.Status.Text='Connect to a tenant to browse its local change history.'
    })
    $Script:CH_UI.Status.Text='Connect to a tenant to browse its local change history.'
    return $panel
}
