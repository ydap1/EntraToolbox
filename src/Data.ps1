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
