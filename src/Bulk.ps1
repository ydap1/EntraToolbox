# Shared bulk-operation tracking. Request bodies and tokens never enter result rows.
$Script:BulkRuns = [Collections.ObjectModel.ObservableCollection[PSObject]]::new()
$Script:BR_UI = $null

function Export-EtbRows {
    param([object[]]$Rows, [string]$Name = 'results')
    if (-not $Rows.Count) { return }
    $dialog = [Microsoft.Win32.SaveFileDialog]::new()
    $dialog.Filter = 'CSV files (*.csv)|*.csv'
    $dialog.FileName = "$Name-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
    if ($dialog.ShowDialog() -eq $true) {
        try { $Rows | ConvertTo-EtbCsvRow | Export-Csv $dialog.FileName -NoTypeInformation -Encoding utf8 }
        catch { Write-AppLog "Export failed: $($_.Exception.Message)" 'Danger' }
    }
}

function Register-EtbBulkRun {
    param($Timer, [string]$Name, [int]$Total)
    $run = [pscustomobject]@{
        Name = "$(Get-Date -Format HH:mm:ss)  $Name"; Tool = $Name
        Tenant = $Script:CurrentTenantId; Generation = $Script:SessionGeneration
        Total = $Total; State = 'Running'; Timer = $Timer; Ref = $Timer.Tag.Ref
        Rows = [Collections.ObjectModel.ObservableCollection[PSObject]]::new()
    }
    $Timer.Tag.Ref['BulkRun'] = $run
    $Script:BulkRuns.Insert(0, $run)
    Write-AppLog "$Name started. Open Bulk Results for progress, Stop and exports." 'Accent'
    if ($Script:BR_UI) { $Script:BR_UI.Runs.SelectedItem = $run }
}

function Update-EtbBulkRun {
    param($Ref, [switch]$Finished)
    $run = $Ref['BulkRun']
    if (-not $run) { return }
    $row = $null
    while ($Ref['BulkQueue'].TryDequeue([ref]$row)) { $run.Rows.Add($row) }
    if ($Finished) {
        $run.Timer = $null
        $run.State = if ($Ref['Error']) { "Interrupted: $($Ref['Error'])" }
            elseif ($Ref['CancelRequested']) { 'Stopped; remaining actions were not started' } else { 'Finished' }
    }
    Update-BrDisplay
}

function Update-BrDisplay {
    if (-not $Script:BR_UI) { return }
    $run = $Script:BR_UI.Runs.SelectedItem
    if (-not $run) {
        $Script:BR_UI.Grid.ItemsSource = @()
        $Script:BR_UI.Status.Text = 'Bulk operations appear here during this tenant session.'
        foreach ($key in 'Stop','Export','Failures','Retry','Check') { $Script:BR_UI[$key].IsEnabled = $false }
        return
    }
    $Script:BR_UI.Grid.ItemsSource = $run.Rows
    $ok = @($run.Rows | Where-Object Result -eq 'Succeeded').Count
    $failed = @($run.Rows | Where-Object Result -eq 'Failed').Count
    $unknown = @($run.Rows | Where-Object Result -eq 'Uncertain').Count
    $Script:BR_UI.Status.Text = "$($run.State) — $ok succeeded, $failed failed, $unknown uncertain. $($run.Rows.Count) write requests completed$(if ($run.Total) { " / up to $($run.Total) planned" })."
    $Script:BR_UI.Progress.Maximum = [math]::Max(1, [math]::Max($run.Total, $run.Rows.Count))
    $Script:BR_UI.Progress.Value = $run.Rows.Count
    $Script:BR_UI.Stop.IsEnabled = $null -ne $run.Timer -and -not $run.Ref['CancelRequested']
    $Script:BR_UI.Export.IsEnabled = $run.Rows.Count -gt 0
    $Script:BR_UI.Failures.IsEnabled = ($failed + $unknown) -gt 0
    $idle = -not $run.Timer -and -not $Script:BR_Busy -and $run.Generation -eq $Script:SessionGeneration
    $Script:BR_UI.Retry.IsEnabled = $idle -and -not $Script:DryMode -and @($run.Rows | Where-Object { $_.Result -eq 'Failed' -and $_.Retry }).Count -gt 0
    $Script:BR_UI.Check.IsEnabled = $idle -and @($run.Rows | Where-Object { $_.Result -eq 'Uncertain' -and $_.Retry }).Count -gt 0
}

function Get-BrExportRows {
    param($Run, [switch]$FailuresOnly)
    foreach ($row in $Run.Rows) {
        if ($FailuresOnly -and $row.Result -notin 'Failed','Uncertain') { continue }
        [pscustomobject]@{ Time = $row.Time; Tool = $Run.Tool; Target = $row.Target; Action = $row.Action; Result = $row.Result; Detail = $row.Detail }
    }
}

function Start-BrRecovery {
    param([switch]$Check)
    $run = $Script:BR_UI.Runs.SelectedItem
    if (-not $run -or $run.Timer -or $Script:BR_Busy -or $run.Generation -ne $Script:SessionGeneration) { return }
    if (-not $Check -and ($Script:DryMode -or $Script:DemoMode)) { return }
    $rows = @($run.Rows | Where-Object { $_.Retry -and $_.Result -eq $(if ($Check) { 'Uncertain' } else { 'Failed' }) })
    if (-not $rows.Count) { return }
    if (-not $Check -and [Windows.MessageBox]::Show("Retry $($rows.Count) confirmed failed requests from $($run.Tool)? Review the result rows first. Refresh the original tool afterwards.", 'Retry failed requests', 'YesNo', 'Question') -ne 'Yes') { return }
    $Script:BR_Busy = $true
    Update-BrDisplay
    $Script:BR_RecoveryTimer = Start-AsyncWork -Vars @{ Items = $rows; CheckOnly = [bool]$Check } -RefSeed @{ Source = $run; Recovery = @() } -Script {
        $headers = @{ Authorization = "Bearer $Token" }
        foreach ($item in $Items) {
            if ($Ref['CancelRequested']) { break }
            $request = $item.Retry
            $result = $item.Result; $detail = ''
            try {
                if ($CheckOnly) {
                    # Only compare readable fields or membership references. Never infer a password or creation outcome.
                    if ($request.Method -eq 'PATCH') {
                        $expected = $request.Body | ConvertFrom-Json -AsHashtable
                        $actual = Invoke-RestMethod -Uri ($request.Uri + '?$select=' + ($expected.Keys -join ',')) -Headers $headers
                        $matches = $true
                        foreach ($key in $expected.Keys) { if ($actual.$key -cne $expected[$key]) { $matches = $false } }
                    } else {
                        try {
                            $null = Invoke-RestMethod -Uri $request.VerifyUri -Headers $headers
                            $exists = $true
                        } catch {
                            if ([int]$_.Exception.Response.StatusCode -ne 404) { throw }
                            $exists = $false
                        }
                        $matches = $exists -eq ($request.Method -eq 'POST')
                    }
                    # A current-state check is not proof that a timed-out write cannot still complete.
                    $result = if ($matches) { 'Succeeded' } else { 'Uncertain' }
                    $detail = if ($matches) { 'Desired state verified by a fresh read.' } else { 'Desired state not observed. Outcome remains uncertain; review in the original tool.' }
                } else {
                    $params = @{ Uri = $request.Uri; Method = $request.Method; Headers = $headers }
                    if ($request.Body) { $params.Body = $request.Body; $params.ContentType = 'application/json' }
                    $null = Invoke-RestMethod @params
                    $result = 'Succeeded'; $detail = 'Confirmed failure retried successfully.'
                }
            } catch {
                $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                $result = if ($CheckOnly) { 'Uncertain' } else { Get-EtbWriteResult $status }
                $detail = $_.Exception.Message
            }
            $Ref['Recovery'] += [pscustomobject]@{ Row = $item; Result = $result; Detail = $detail; Check = $CheckOnly }
        }
    } -OnComplete {
        param($ref)
        $Script:BR_Busy = $false
        foreach ($entry in $ref.Recovery) {
            $entry.Row.Result = $entry.Result; $entry.Row.Detail = $entry.Detail
            Write-EtbAudit -Tool $ref.Source.Tool -Action $(if ($entry.Check) { 'Verify outcome' } else { 'Retry' }) -Target $entry.Row.Target -Result $entry.Result -Detail $entry.Detail
        }
        if ($ref.Error) { Write-AppLog "Recovery interrupted: $($ref.Error)" 'Warning' }
        $Script:BR_UI.Grid.Items.Refresh()
        Update-BrDisplay
    }
}

$Script:BrXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Background="#12121C" Margin="16">
  <Grid.Resources></Grid.Resources>
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <ComboBox x:Name="BrRuns" DisplayMemberPath="Name" Style="{StaticResource EtbPopulationCombo}" AutomationProperties.Name="Bulk runs"/>
  <StackPanel Grid.Row="1" Margin="0,12"><TextBlock x:Name="BrStatus" Foreground="#E2E2F0" TextWrapping="Wrap"/><ProgressBar x:Name="BrProgress" Height="6" Margin="0,8,0,0"/></StackPanel>
  <DataGrid x:Name="BrGrid" Grid.Row="2" AutoGenerateColumns="False" IsReadOnly="True" RowStyle="{StaticResource DgRow}" CellStyle="{StaticResource DgCell}">
    <DataGrid.Columns><DataGridTextColumn Header="Time" Binding="{Binding Time}" Width="85"/><DataGridTextColumn Header="Target" Binding="{Binding Target}" Width="2*"/><DataGridTextColumn Header="Action" Binding="{Binding Action}" Width="80"/><DataGridTextColumn Header="Result" Binding="{Binding Result}" Width="100"/><DataGridTextColumn Header="Detail" Binding="{Binding Detail}" Width="2*"/></DataGrid.Columns>
  </DataGrid>
  <StackPanel Grid.Row="3" Margin="0,12,0,0">
    <WrapPanel><Button Style="{StaticResource EtbAction}" x:Name="BrStop" Content="Stop" Padding="12,8" Margin="0,0,8,8"/><Button Style="{StaticResource EtbAction}" x:Name="BrExport" Content="Export results" Padding="12,8" Margin="0,0,8,8"/><Button Style="{StaticResource EtbAction}" x:Name="BrFailures" Content="Export failures" Padding="12,8" Margin="0,0,8,8"/><Button Style="{StaticResource EtbAction}" x:Name="BrRetry" Content="Retry confirmed failures" Padding="12,8" Margin="0,0,8,8"/><Button Style="{StaticResource EtbAction}" x:Name="BrCheck" Content="Check uncertain outcomes" Padding="12,8" Margin="0,0,8,8"/></WrapPanel>
    <TextBlock Text="Stop finishes the current request. Password resets and object creation must be reviewed in their original tool; they are never replayed here. Results are cleared when switching tenants." Foreground="#7878A0" TextWrapping="Wrap"/>
  </StackPanel>
</Grid>
'@

function Initialize-BulkResultsTool {
    $reader = [Xml.XmlReader]::Create([IO.StringReader]::new((Invoke-ThemeXaml $Script:BrXaml)))
    try { $panel = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    $Script:BR_UI = @{}
    foreach ($key in 'Runs','Grid','Status','Progress','Stop','Export','Failures','Retry','Check') { $Script:BR_UI[$key] = $panel.FindName("Br$key") }
    $Script:BR_UI.Runs.ItemsSource = $Script:BulkRuns
    $Script:BR_UI.Runs.Add_SelectionChanged({ Update-BrDisplay })
    $Script:BR_UI.Stop.Add_Click({ Request-EtbAsyncCancel $Script:BR_UI.Runs.SelectedItem.Timer; Update-BrDisplay })
    $Script:BR_UI.Export.Add_Click({ Export-EtbRows @(Get-BrExportRows $Script:BR_UI.Runs.SelectedItem) 'bulk-results' })
    $Script:BR_UI.Failures.Add_Click({ Export-EtbRows @(Get-BrExportRows $Script:BR_UI.Runs.SelectedItem -FailuresOnly) 'bulk-failures' })
    $Script:BR_UI.Retry.Add_Click({ Start-BrRecovery })
    $Script:BR_UI.Check.Add_Click({ Start-BrRecovery -Check })
    if ($Script:BulkRuns.Count) { $Script:BR_UI.Runs.SelectedIndex = 0 }
    Update-BrDisplay
    return $panel
}
