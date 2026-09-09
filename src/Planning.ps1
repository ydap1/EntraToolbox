# WPF-free operation planning, also loaded in Graph worker runspaces.
function Get-BlPlanRow {
    param($User, [string]$SkuId, [ValidateSet('Assign','Remove')][string]$Action)
    $states = @($User.licenseAssignmentStates | Where-Object skuId -eq $SkuId)
    $direct = @($states | Where-Object { -not $_.assignedByGroup })
    $inherited = @($states | Where-Object { $_.assignedByGroup })
    $assigned = @($User.assignedLicenses | Where-Object skuId -eq $SkuId)
    $source = if ($direct.Count -and $inherited.Count) { 'Direct + group' } elseif ($direct.Count) { 'Direct' } elseif ($inherited.Count) { 'Group' } elseif ($assigned.Count) { 'Unknown' } else { 'None' }
    $result = 'Ready'; $detail = ''
    if ($Action -eq 'Assign') {
        if ($states.Count -or $assigned.Count) { $result = 'Skip'; $detail = 'Already assigned; existing service plans are preserved.' }
        elseif (-not $User.usageLocation) { $result = 'Blocked'; $detail = 'Set the user usage location before assigning a licence.' }
    } else {
        if (-not $direct.Count) { $result = 'Skip'; $detail = 'No direct assignment to remove. Group-inherited licences must be managed at their source.' }
        elseif ($inherited.Count) { $detail = 'Remove the direct assignment only; group-inherited access remains.' }
    }
    $errors = @($states | Where-Object { $_.error -and $_.error -ne 'None' } | ForEach-Object { $_.error }) -join ', '
    if ($errors) { $detail += " Assignment errors: $errors." }
    [pscustomobject]@{ Id=$User.id; Target=$User.userPrincipalName; Action=$Action; Source=$source; Result=$result; Detail=$detail; SkuId=$SkuId }
}

function Get-BlAvailableSeats {
    param($Sku)
    [math]::Max(0, [int64]$Sku.prepaidUnits.enabled - [int64]$Sku.consumedUnits)
}
