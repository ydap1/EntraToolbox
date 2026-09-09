# Shared cohort selection for tools that preview a user roster before writing.
$Script:RosterXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Background="#1C1C2A">
  <Grid.Resources></Grid.Resources>
  <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="12">
    <TextBlock Text="Year group" Foreground="#7878A0" Margin="0,0,0,6"/><ComboBox x:Name="RYears" DisplayMemberPath="Label" Style="{StaticResource EtbPopulationCombo}" AutomationProperties.Name="Year group"/><Button x:Name="RYear" Content="Add year group" Style="{StaticResource EtbAction}" Margin="0,8,0,12"/>
    <TextBlock Text="Department" Foreground="#7878A0" Margin="0,0,0,6"/><ComboBox x:Name="RDepartments" DisplayMemberPath="Label" Style="{StaticResource EtbPopulationCombo}" AutomationProperties.Name="Department"/><Button x:Name="RDepartment" Content="Add department" Style="{StaticResource EtbAction}" Margin="0,8,0,12"/>
    <TextBlock Text="Find users" Foreground="#7878A0" Margin="0,0,0,6"/><TextBox x:Name="RSearch" AutomationProperties.Name="Find users"/><ListBox x:Name="RMatches" Height="100" DisplayMemberPath="userPrincipalName" SelectionMode="Extended" Margin="0,6,0,8"/><Button x:Name="RAdd" Content="Add selected users" Style="{StaticResource EtbAction}"/>
    <Button x:Name="RImport" Content="Paste users / import CSV…" Style="{StaticResource EtbAction}"/>
    <TextBlock x:Name="RCount" Text="0 selected users" Foreground="#E2E2F0" Margin="0,8"/>
    <ListBox x:Name="RSelected" Height="120" DisplayMemberPath="userPrincipalName" SelectionMode="Extended"/>
    <WrapPanel Margin="0,8,0,0"><Button x:Name="RRemove" Content="Remove selected" Style="{StaticResource EtbAction}"/><Button x:Name="RClear" Content="Clear all" Style="{StaticResource EtbAction}"/></WrapPanel>
    <TextBlock x:Name="RStatus" Text="Connect to load users." Foreground="#7878A0" TextWrapping="Wrap"/>
  </StackPanel></ScrollViewer>
</Grid>
'@

function Update-EtbRoster {
    param($Roster)
    $Roster.UI.Count.Text = "$($Roster.Rows.Count) selected users"
    Invoke-EtbCommand $Roster.OnChange
}

function Add-EtbRosterUsers {
    param($Roster, [object[]]$Users)
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($u in $Roster.Rows) { [void]$ids.Add($u.id) }
    foreach ($u in $Users) { if ($u.id -and $ids.Add($u.id)) { $Roster.Rows.Add($u) } }
    Update-EtbRoster $Roster
}

function Set-EtbRosterUsers {
    param($Roster, [object[]]$Users)
    $Roster.Users = $Users
    $Roster.UI.Years.ItemsSource = @(Get-EtbPopulationChoices $Users YearGroup)
    $Roster.UI.Departments.ItemsSource = @(Get-EtbPopulationChoices $Users Department)
    $Roster.UI.Status.Text = "$($Users.Count) users available. Search shows up to 50 matches."
    $Roster.Panel.IsEnabled = $true
}

function Initialize-EtbRoster {
    param([string]$OnChange)
    $reader = [Xml.XmlReader]::Create([IO.StringReader]::new((Invoke-ThemeXaml $Script:RosterXaml)))
    try { $panel = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    $roster = @{ Panel=$panel; UI=@{}; Users=@(); Rows=[Collections.ObjectModel.ObservableCollection[PSObject]]::new(); OnChange=$OnChange; ImportError=$false }
    foreach ($key in 'Years','Year','Departments','Department','Search','Matches','Add','Import','Count','Selected','Remove','Clear','Status') {
        $roster.UI[$key] = $panel.FindName("R$key"); $roster.UI[$key].Tag = $roster
    }
    $roster.UI.Selected.ItemsSource = $roster.Rows
    $roster.UI.Year.Add_Click({ $r = $this.Tag; if ($r.UI.Years.SelectedItem) { Add-EtbRosterUsers $r $r.UI.Years.SelectedItem.Users } })
    $roster.UI.Department.Add_Click({ $r = $this.Tag; if ($r.UI.Departments.SelectedItem) { Add-EtbRosterUsers $r $r.UI.Departments.SelectedItem.Users } })
    $roster.UI.Search.Add_TextChanged({
        $r = $this.Tag; $text = $r.UI.Search.Text.Trim()
        $r.UI.Matches.ItemsSource = @(if ($text) { $r.Users | Where-Object { $_.displayName.IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $_.userPrincipalName.IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 50 })
    })
    $roster.UI.Add.Add_Click({ Add-EtbRosterUsers $this.Tag @($this.Tag.UI.Matches.SelectedItems) })
    $roster.UI.Remove.Add_Click({ $r=$this.Tag; foreach ($u in @($r.UI.Selected.SelectedItems)) { [void]$r.Rows.Remove($u) }; Update-EtbRoster $r })
    $roster.UI.Clear.Add_Click({ $r=$this.Tag; $r.Rows.Clear(); $r.ImportError=$false; $r.UI.Status.Text='Selection cleared.'; Update-EtbRoster $r })
    $roster.UI.Import.Add_Click({
        $r = $this.Tag; $upns = @(Show-EtbUpnImport)
        if (-not $upns.Count) { return }
        $selection = Select-EtbUsersByUpn -Users $r.Users -Upns $upns
        $r.ImportError = $selection.Missing.Count -gt 0
        if ($r.ImportError) {
            $r.UI.Status.Text = "Nothing imported: $($selection.Missing.Count) unmatched usernames. Correct the list and import again, or Clear all."
            foreach ($upn in $selection.Missing) { Write-AppLog "User not found: $upn" 'Warning' }
            Update-EtbRoster $r
        } else {
            Add-EtbRosterUsers $r $selection.Matched
            $r.UI.Status.Text = "$($selection.Matched.Count) users matched; duplicates skipped."
        }
    })
    $panel.IsEnabled = $false
    return $roster
}
