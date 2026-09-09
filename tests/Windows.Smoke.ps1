#Requires -Version 7.0
# Run with pwsh -NoProfile -STA -File tests/Windows.Smoke.ps1 on Windows.
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This smoke test needs Windows WPF.' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Launch pwsh with -STA.' }
$root = Split-Path $PSScriptRoot
$Global:AppRoot = Join-Path ([IO.Path]::GetTempPath()) ('etb-wpf-' + [guid]::NewGuid())
New-Item $Global:AppRoot -ItemType Directory | Out-Null
$window = $null
try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    . "$root/src/Auth.ps1"
    . "$root/src/Import.ps1"
    . "$root/src/Demo.ps1"
    foreach ($file in Get-ChildItem "$root/src/Tools" -Filter *.ps1) { . $file.FullName }
    . "$root/src/MainWindow.ps1"
    $Script:EtbSessionState = $ExecutionContext.SessionState
    $Script:SmokeErrors = [Collections.Generic.List[string]]::new()
    function Write-Log {
        param($Message, $Level)
        if ($Level -eq 'ERROR') { $Script:SmokeErrors.Add($Message) }
    }
    # Construct every XAML document under every theme, including templates.
    $documents = [Collections.Generic.List[string]]::new()
    foreach ($file in Get-ChildItem "$root/src" -Recurse -Filter *.ps1) {
        $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
        foreach ($node in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.StringConstantExpressionAst] -and $a.Value -match '^<(Grid|Window)\s+xmlns=' }, $true)) {
            $documents.Add($node.Value)
        }
    }
    # These are built once from $Script:Theme when Auth.ps1 is dot-sourced, so
    # each must be rebuilt per preset or the loop would keep re-testing the
    # first theme's colours in every injected style.
    $authAst = [Management.Automation.Language.Parser]::ParseFile("$root/src/Auth.ps1", [ref]$null, [ref]$null)
    $themeAssignments = foreach ($name in '$Script:ThemeMap', '$Script:ThemeScrollBarStyle', '$Script:ThemeSharedStyles') {
        $found = $authAst.Find({ param($a) $a -is [Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq $name }.GetNewClosure(), $true)
        if (-not $found) { throw "Smoke test could not find the $name assignment in Auth.ps1." }
        $found.Extent.Text
    }
    foreach ($preset in $Script:ThemePresets.Keys) {
        $Script:Theme = $Script:ThemeBase.Clone()
        foreach ($key in $Script:ThemePresets[$preset].Keys) { $Script:Theme[$key] = $Script:ThemePresets[$preset][$key] }
        foreach ($assignment in $themeAssignments) { . ([scriptblock]::Create($assignment)) }
        foreach ($xaml in $documents) {
            $reader = [Xml.XmlNodeReader]::new([xml](Invoke-ThemeXaml $xaml))
            try { $view = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
            if ($xaml -eq $Script:TpXaml) {
                foreach ($pair in @(@('TpRbClass', 'TpRbStandard'), @('TpRbYearGroup', 'TpRbDirect'))) {
                    $first = $view.FindName($pair[0])
                    $second = $view.FindName($pair[1])
                    [void]$first.ApplyTemplate()
                    [void]$second.ApplyTemplate()
                    foreach ($selected in @($second, $first)) {
                        $peer = [Windows.Automation.Peers.RadioButtonAutomationPeer]::new($selected)
                        $selection = [Windows.Automation.Provider.ISelectionItemProvider]$peer.GetPattern([Windows.Automation.Peers.PatternInterface]::SelectionItem)
                        $selection.Select()
                        foreach ($radio in @($first, $second)) {
                            $dot = $radio.Template.FindName('SelectedDot', $radio)
                            $expected = if ($radio -eq $selected) { 'Visible' } else { 'Collapsed' }
                            if (-not $dot -or $dot.Visibility -ne $expected -or [bool]$radio.IsChecked -ne ($radio -eq $selected)) {
                                throw "Teams radio selection is not visible or exclusive for $($radio.Name) in theme $preset."
                            }
                        }
                    }
                }
                $owner = $view.FindName('TpGrid').Columns[3].CellTemplate.LoadContent()
                $row = [pscustomobject]@{ IsOwner = $false }
                $owner.DataContext = $row
                [void]$owner.ApplyTemplate()
                $peer = [Windows.Automation.Peers.CheckBoxAutomationPeer]::new($owner)
                $toggle = [Windows.Automation.Provider.IToggleProvider]$peer.GetPattern([Windows.Automation.Peers.PatternInterface]::Toggle)
                $toggle.Toggle()
                $tick = $owner.Template.FindName('Check', $owner)
                if (-not $row.IsOwner -or $tick.Visibility -ne 'Visible') {
                    throw "Owner checkbox did not show a tick and update its member in theme $preset."
                }
                $toggle.Toggle()
                if ($row.IsOwner -or $tick.Visibility -ne 'Collapsed') {
                    throw "Owner checkbox did not clear in theme $preset."
                }
            }
        }
    }
    $window = Show-MainWindow -AppVersion 'smoke' -InitializeOnly
    $Script:DemoMode = $true
    $Script:AccessToken = 'DEMO'
    foreach ($name in @($Script:NavInitializers.Keys)) {
        Set-NavSelection $name
        foreach ($load in $Script:NavConnectFns[$name]) { Invoke-EtbCommand $load }
        if (-not $Script:NavContents.ContainsKey($name)) { throw "Panel failed: $name" }
        foreach ($width in 900, 1280, 1600) {
            $window.Measure([Windows.Size]::new($width, 800))
            $window.Arrange([Windows.Rect]::new(0, 0, $width, 800))
            $window.UpdateLayout()
        }
    }
    Set-NavSelection 'Overview'
    $Script:UO_UI.Users.SelectedIndex=0
    if (-not $Script:UO_UI.Summary.Text.Contains($Script:UO_UI.Users.SelectedItem.userPrincipalName)) { throw 'Overview did not load the selected demo user.' }
    Set-NavSelection 'SignIn'
    $Script:SL_UI.UserList.SelectedIndex=0
    if ($Script:SL_Entries.Count -ne 50) { throw 'Sign-ins did not load a first demo page.' }
    Start-SlLogsLoad $Script:SL_UI.UserList.SelectedItem.Tag.id -More
    if ($Script:SL_Entries.Count -ne 70) { throw 'Sign-in Load more did not append the second demo page.' }
    $Script:SL_UI.Failures.IsChecked=$true; Update-SlResults
    if (@($Script:SL_UI.LogsGrid.ItemsSource | Where-Object Result -eq 'Success').Count) { throw 'Sign-in failure filter retained successes.' }
    Set-NavSelection 'BulkLicence'
    Add-EtbRosterUsers $Script:BL_Roster @($Script:Demo_Users | Select-Object -First 2)
    Start-BlPreview
    if ($Script:BL_Plan.Count -ne 2 -or -not $Script:BL_UI.Apply.IsEnabled) { throw 'Bulk licence demo preview failed.' }
    Start-BlApply
    if (@($Script:BL_Plan | Where-Object Result -eq 'Demo').Count -ne 2) { throw 'Bulk licence demo apply was not simulated.' }
    Set-NavSelection 'GroupManager'
    $Script:GM_UI.Groups.SelectedIndex=0
    Add-EtbRosterUsers $Script:GM_Roster @($Script:Demo_Users | Select-Object -Last 2)
    $Script:GM_UI.Mode.SelectedItem='Match user roster'
    Start-GmPreview
    if (-not $Script:GM_Plan.Count -or -not $Script:GM_UI.Apply.IsEnabled) { throw 'Group Manager demo preview failed.' }
    Start-GmApply
    if (-not @($Script:GM_Plan | Where-Object Result -eq 'Demo').Count) { throw 'Group Manager demo apply was not simulated.' }
    Set-NavSelection 'BulkResults'
    $Script:BR_UI.Runs.SelectedIndex=0
    if (-not $Script:BR_UI.Grid.ItemsSource.Count -or $Script:BR_UI.Retry.IsEnabled) { throw 'Demo bulk results are missing or incorrectly replayable.' }
    Set-NavSelection 'ChangeHistory'
    Start-ChLoad
    if ($Script:CH_UI.Grid.ItemsSource.Count -ne 2) { throw 'Demo change history did not load.' }
    foreach ($tool in @(
        @{ Nav = 'Teams'; UI = $Script:TP_UI; Rows = $Script:TP_Rows }
        @{ Nav = 'YearGroup'; UI = $Script:PwReset_UI; Rows = $Script:PwReset_Rows }
    )) {
        Set-NavSelection $tool.Nav
        foreach ($source in @(@('CboYear', 'BtnLoad'), @('CboDept', 'BtnLoadDept'))) {
            $combo = $tool.UI[$source[0]]
            if ($combo -isnot [Windows.Controls.ComboBox] -or $combo.Items.Count -eq 0) { throw "$($tool.Nav): missing population dropdown." }
            $combo.SelectedIndex = 0
            $tool.UI[$source[1]].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            $expected = @($combo.SelectedItem.DataContext.Users.id | Sort-Object)
            $actual = @($tool.Rows.Id | Sort-Object)
            if (($expected -join ',') -ne ($actual -join ',')) { throw "$($tool.Nav): $($source[0]) loaded the wrong users." }
            if ($tool.UI.Grid.SelectedItems.Count -ne $actual.Count) { throw "$($tool.Nav): loaded users were not selected." }
        }
        if ($tool.Nav -eq 'Teams') { $tool.UI.TeamName.Text = 'Keep this team name' }
        $yearChoice = $tool.UI.CboYear.SelectedItem
        $deptChoice = $tool.UI.CboDept.SelectedItem
        $tool.UI.BtnClear.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if ($tool.Rows.Count -ne 0 -or $tool.UI.BtnClear.IsEnabled -or $tool.UI.CboYear.SelectedItem -ne $yearChoice -or $tool.UI.CboDept.SelectedItem -ne $deptChoice) {
            throw "$($tool.Nav): Clear all failed to empty the list and preserve dropdown choices."
        }
        if ($tool.Nav -eq 'Teams' -and $tool.UI.TeamName.Text -ne 'Keep this team name') { throw 'Clear all lost the team name.' }
        if ($tool.Nav -eq 'YearGroup' -and ($tool.UI.BtnExport.IsEnabled -or $tool.UI.BtnPrint.IsEnabled -or $tool.UI.BtnRun.IsEnabled)) {
            throw 'Password actions remain enabled after clearing users.'
        }
    }
    Set-NavSelection 'BulkUpn'
    $Script:BUC_UI.YearCombo.SelectedIndex = 0
    $Script:BUC_UI.BtnAddYear.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    $expectedCount = $Script:BUC_UI.YearCombo.SelectedItem.DataContext.Users.Count
    if ($Script:BUC_Rows.Count -ne $expectedCount) { throw 'Bulk UPN year dropdown did not add the expected users.' }
    $overlappingDepartment = $Script:BUC_UI.YearCombo.SelectedItem.DataContext.Users[0].department
    $Script:BUC_UI.DeptCombo.SelectedItem = $Script:BUC_UI.DeptCombo.Items | Where-Object Tag -eq $overlappingDepartment | Select-Object -First 1
    $Script:BUC_UI.BtnAddDept.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    if ($Script:BUC_Rows.Count -ne $expectedCount) { throw 'Bulk UPN department selection duplicated existing users.' }
    if (-not $Script:BUC_UI.OfficeCombo.IsEnabled) { throw 'Bulk UPN office selector was lost.' }
    Set-NavSelection 'SecurityGroup'
    if ($Script:SG_UI.Years -isnot [Windows.Controls.ComboBox] -or $Script:SG_UI.Departments -isnot [Windows.Controls.ComboBox]) {
        throw 'Year groups and departments must both use dropdowns.'
    }
    if ($Script:SG_UI.Departments.Items.Count -eq 0) { throw 'Security group demo has no departments.' }
    $Script:SG_UI.Name.Text = 'Demo security group'
    $Script:SG_UI.Years.SelectedIndex = 0
    $Script:SG_UI.AddYear.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    if ($Script:SG_Rows.Count -ne $Script:SG_UI.Years.SelectedItem.Users.Count) { throw 'Security group year selection failed.' }
    $Script:SG_UI.Description.Text = 'Keep this description'
    $Script:SG_UI.Clear.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    if ($Script:SG_Rows.Count -ne 0 -or $Script:SG_UI.Clear.IsEnabled -or $Script:SG_UI.Name.Text -ne 'Demo security group' -or $Script:SG_UI.Description.Text -ne 'Keep this description') {
        throw 'Security group Clear all did not preserve the group details.'
    }
    $Script:SG_UI.Departments.SelectedIndex = 0
    $Script:SG_UI.AddDepartment.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    if ($Script:SG_Rows.Count -eq 0 -or -not $Script:SG_UI.Create.IsEnabled) { throw 'Security group department selection failed.' }
    $userCount = $Script:SG_Rows.Count
    $Script:SG_UI.DeviceSearch.Text = 'ctx-lt'
    Update-SgDeviceSearch
    if ($Script:SG_UI.DeviceMatches.Items.Count -ne 2) { throw 'Security group device search failed.' }
    $Script:SG_UI.DeviceMatches.SelectAll()
    $Script:SG_UI.AddDevices.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    $Script:SG_UI.AddDevices.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    if ($Script:SG_Rows.Count -ne ($userCount + 2) -or @($Script:SG_Rows | Where-Object MemberType -eq 'Device').Count -ne 2) { throw 'Mixed group device selection or deduplication failed.' }
    $Script:SG_UI.Create.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    if ($Script:SG_UI.Status.Text -notlike '*No changes made*') { throw 'Security group demo creation failed.' }
    $Script:SG_UI.Clear.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    if ($Script:SG_Rows.Count) { throw 'Clear all did not remove mixed members.' }
    $Script:SG_UI.AddDevices.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    if ($Script:SG_Rows.Count -ne 2) { throw 'Device-only group selection failed.' }
    $Script:SG_UI.Create.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    if ($Script:SG_UI.Status.Text -notlike '*2 members*No changes made*') { throw 'Device-only group preview failed.' }
    $Script:SG_UI.New.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    if ($Script:SG_UI.DeviceSearch.Text -or $Script:SG_Rows.Count -or $Script:SG_UI.DeviceMatches.SelectedItems.Count) { throw 'New group did not reset device selection.' }
    foreach ($callback in $Script:ResetCallbacks) { & $callback }
    if ($Script:SG_Devices.Count -or $Script:SG_UI.DeviceMatches.Items.Count -or $Script:SG_UI.ReloadDevices.IsEnabled -or $Script:SG_DeviceTimer) { throw 'Tenant reset did not clear device state.' }
    if ($Script:SmokeErrors.Count) { throw ($Script:SmokeErrors -join "`n") }
    if ($Script:AsyncJobs.Count) { throw 'Demo navigation unexpectedly started network workers.' }
    Write-Host "PASS: $($documents.Count) XAML documents, $($Script:ThemePresets.Count) themes, $($Script:NavContents.Count) demo panels at three widths."
} finally {
    if ($window) { $window.Close() }
    Remove-Item $Global:AppRoot -Recurse -Force -ErrorAction SilentlyContinue
}
