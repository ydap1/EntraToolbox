function Get-DeptGroup([string]$d) {
    if ($d -match '^(?:Year\s*)?(\d+)')       { return [int]$Matches[1] }
    if ($d -match '^([A-Za-z]+)') { return $Matches[1] }
    return $null
}

function Get-EtbPopulationChoices {
    param([object[]]$Users, [ValidateSet('YearGroup', 'Department')][string]$Mode)
    # Use Teams Provisioning's grouping: e.g. 7A and 7B become Year 7.
    # Department mode retains the complete department name instead.
    $choices = foreach ($group in @($Users | Group-Object -Property {
        if ($Mode -eq 'YearGroup') { Get-DeptGroup $_.department } else { $_.department }
    } | Where-Object { $_.Name })) {
        $value = if ($Mode -eq 'YearGroup') { Get-DeptGroup $group.Group[0].department } else { $group.Name }
        $label = if ($value -is [int]) { "Year $value" } else { $value }
        [pscustomobject]@{ Label = "$label - $($group.Count) users"; Value = $value; Users = @($group.Group) }
    }
    $choices | Sort-Object @{ Expression = { if ($_.Value -is [int]) { 0 } else { 1 } } }, Value
}

function Set-EtbPopulationCombo {
    param($ComboBox, [object[]]$Users, [ValidateSet('YearGroup', 'Department')][string]$Mode)
    $ComboBox.Items.Clear()
    foreach ($choice in @(Get-EtbPopulationChoices -Users $Users -Mode $Mode)) {
        $item = [System.Windows.Controls.ComboBoxItem]::new()
        $item.Content = $choice.Label
        $item.Tag = $choice.Value
        $item.DataContext = $choice
        [void]$ComboBox.Items.Add($item)
    }
    $ComboBox.IsEnabled = $ComboBox.Items.Count -gt 0
    if ($ComboBox.IsEnabled) { $ComboBox.SelectedIndex = 0 }
}

function ConvertTo-EtbCsvRow {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline, Mandatory)]$InputObject)
    process {
        $row = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $value = $property.Value
            # CSV quoting alone does not stop spreadsheet formula execution.
            if ($value -is [string] -and $value -match '^[\s\uFEFF]*[=+@-]|^[\t\r\n]') {
                $value = "'$value"
            }
            $row[$property.Name] = $value
        }
        [pscustomobject]$row
    }
}

function Clear-EtbList {
    param($List)
    $List.ItemsSource = $null
    $List.Items.Clear()
}

function Set-EtbListItems {
    param($List, [object[]]$Items)
    Clear-EtbList $List
    $List.DisplayMemberPath = 'Content'
    # Preserve the tool's existing selection/hover style while binding tooltips
    # to data. WPF now creates and recycles containers only for visible rows.
    if (-not $List.ItemContainerStyle) {
        $style = [System.Windows.Style]::new([System.Windows.Controls.ListBoxItem])
        $style.BasedOn = $List.TryFindResource([System.Windows.Controls.ListBoxItem])
        $style.Setters.Add([System.Windows.Setter]::new(
            [System.Windows.Controls.ToolTipService]::ToolTipProperty,
            [System.Windows.Data.Binding]::new('ToolTip')))
        $List.ItemContainerStyle = $style
    }
    $List.ItemsSource = @($Items)
}
