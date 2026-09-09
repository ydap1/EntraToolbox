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

function Assert-GmEditableGroup {
    param($Group)
    if (-not $Group.id -or $Group.groupTypes -contains 'DynamicMembership' -or $Group.isAssignableToRole -or $Group.onPremisesSyncEnabled -or
        ($Group.groupTypes -notcontains 'Unified' -and (-not $Group.securityEnabled -or $Group.mailEnabled))) {
        throw 'Choose a cloud-managed security or Microsoft 365 group with assigned membership. Synced, dynamic, role-assignable and mail-enabled security groups are not editable here.'
    }
}

function Get-GmPlan {
    param([object[]]$Current, [object[]]$Desired, [object[]]$Owners, [ValidateSet('Add missing','Match user roster')][string]$Mode)
    $wanted=@{}; $existing=@{}; $ownerIds=@{}
    foreach ($u in $Desired) { if ($u.id) { $wanted[$u.id]=$u } }
    foreach ($u in $Current) { if ($u.id) { $existing[$u.id]=$u } }
    foreach ($o in $Owners) { $ownerIds[$o.id]=$true }
    foreach ($id in $wanted.Keys | Sort-Object) {
        $u=$wanted[$id]
        [pscustomobject]@{ Id=$id; Target=$u.userPrincipalName; Action= $(if ($existing.ContainsKey($id)) { 'Keep' } else { 'Add' }); Result='Preview'; Detail='' }
    }
    foreach ($id in $existing.Keys | Sort-Object) {
        if ($wanted.ContainsKey($id)) { continue }
        $u=$existing[$id]
        $remove = $Mode -eq 'Match user roster' -and -not $ownerIds.ContainsKey($id)
        [pscustomobject]@{ Id=$id; Target=$u.userPrincipalName; Action= $(if ($remove) { 'Remove' } else { 'Keep' }); Result='Preview'; Detail= $(if ($ownerIds.ContainsKey($id)) { 'Owner preserved.' } else { '' }) }
    }
}

function Get-GmPlanSignature {
    param([object[]]$Plan)
    (@($Plan | ForEach-Object { "$($_.Id):$($_.Action):$($_.Detail)" } | Sort-Object) -join '|')
}

function Get-GmSnapshot {
    param([string]$GroupId, $Headers)
    $base = "https://graph.microsoft.com/v1.0/groups/$GroupId"
    $group = Invoke-RestMethod -Uri ($base + '?$select=id,displayName,groupTypes,securityEnabled,mailEnabled,isAssignableToRole,onPremisesSyncEnabled') -Headers $Headers
    Assert-GmEditableGroup $group
    # Read the direct collection instead of a cast query backed by an eventual index.
    $members = @(Get-EtbGraphCollection -Uri ($base + '/members?$select=id,displayName,userPrincipalName&$top=999') -Headers $Headers | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.user' })
    $owners = @(Get-EtbGraphCollection -Uri ($base + '/owners?$select=id&$top=999') -Headers $Headers)
    @{ Group=$group; Members=$members; Owners=$owners }
}


function Test-EtbLicenceRecoveryState {
    param($Request, $Headers)
    $body=$Request.Body | ConvertFrom-Json
    $state=Invoke-RestMethod -Uri $Request.VerifyUri -Headers $Headers
    $assign=@($body.addLicenses).Count -gt 0
    $skuId=if ($assign) { $body.addLicenses[0].skuId } else { $body.removeLicenses[0] }
    $direct=@($state.licenseAssignmentStates | Where-Object { $_.skuId -eq $skuId -and -not $_.assignedByGroup })
    if ($assign) { return @($direct | Where-Object { $_.state -eq 'Active' -and (-not $_.error -or $_.error -eq 'None') }).Count -gt 0 }
    return $direct.Count -eq 0
}


function Assert-EtbLicenceRetry {
    param($Request, $Headers)
    $body=$Request.Body | ConvertFrom-Json
    if (-not @($body.addLicenses).Count) { return }
    $current=Invoke-RestMethod -Uri $Request.VerifyUri -Headers $Headers
    if (@($current.licenseAssignmentStates | Where-Object skuId -eq $body.addLicenses[0].skuId).Count) {
        throw 'A licence assignment now exists or is pending. Preview the user in Bulk Licences before changing it.'
    }
}
