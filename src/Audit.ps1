<#
    Persistent change record for Art's Entra Toolbox.
    Dot-sourced by Auth.ps1.

    The activity pane at the bottom of the window is a live view capped at 500
    lines and discarded when the app closes. This writes the same operations to
    disk so "what did I change last Tuesday, and for whom?" has an answer.

    One CSV per tenant per month under config\audit\. Only operations that
    actually changed directory state are recorded — dry runs and demo mode
    change nothing, so they are not part of the record. Passwords are never
    written here; use the tool's own CSV export for those.
#>

$Script:AuditPathLogged = $false

function Get-EtbAuditPath {
    $dir = Join-Path $Global:AppRoot 'config\audit'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tenant = if ($Script:CurrentTenantId) { $Script:CurrentTenantId } else { 'no-tenant' }
    Join-Path $dir "$tenant-$(Get-Date -Format 'yyyy-MM').csv"
}

# Called on the UI thread from a tool's completion handler, once per affected
# object. Never called from a worker runspace: those have no access to the
# script-scope tenant state and would race each other on the same file.
function Write-EtbAudit {
    param(
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][string]$Action,
        [string]$Target = '',
        [string]$Result = 'OK',
        [string]$Detail = ''
    )
    if ($Script:DemoMode) { return }
    try {
        $path = Get-EtbAuditPath
        [pscustomobject]@{
            Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Operator  = $Script:CurrentAccountUPN
            Tenant    = $Script:CurrentTenantId
            Tool      = $Tool
            Action    = $Action
            Target    = $Target
            Result    = $Result
            Detail    = $Detail
        } | ConvertTo-EtbCsvRow |
            Export-Csv -Path $path -NoTypeInformation -Encoding UTF8 -Append
        if (-not $Script:AuditPathLogged) {
            $Script:AuditPathLogged = $true
            Write-AppLog "Recording changes to $path" 'Muted'
        }
    } catch {
        # A failed audit write must never abort the operation being audited.
        Write-Log "Audit write failed: $_" 'ERROR'
    }
}

function Read-EtbHistory {
    param([string]$Directory, [string]$Tenant)
    $rows=[Collections.Generic.List[object]]::new()
    $errors=[Collections.Generic.List[string]]::new()
    if (-not $Tenant -or -not (Test-Path -LiteralPath $Directory)) { return @{ Rows=@(); Errors=@() } }
    foreach ($file in Get-ChildItem -LiteralPath $Directory -File -Filter '*.csv') {
        if (-not $file.Name.StartsWith("$Tenant-", [StringComparison]::OrdinalIgnoreCase)) { continue }
        try {
            foreach ($row in Import-Csv -LiteralPath $file.FullName -ErrorAction Stop) {
                foreach ($column in 'Timestamp','Operator','Tenant','Tool','Action','Target','Result','Detail') {
                    if ($row.PSObject.Properties.Name -notcontains $column) { throw "Missing audit column: $column" }
                }
                if ($row.Tenant -ne $Tenant) { continue }
                $when=[datetime]::MinValue
                if (-not [datetime]::TryParseExact($row.Timestamp, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$when)) {
                    throw 'An audit timestamp is missing or invalid; some rows were not loaded.'
                }
                $rows.Add([pscustomobject]@{ Timestamp=$row.Timestamp; Operator=$row.Operator; Tenant=$row.Tenant; Tool=$row.Tool; Action=$row.Action; Target=$row.Target; Result=$row.Result; Detail=$row.Detail })
            }
        } catch { $errors.Add("$($file.Name): $($_.Exception.Message)") }
    }
    @{ Rows=@($rows | Sort-Object Timestamp -Descending); Errors=$errors.ToArray() }
}

function Select-EtbHistory {
    param([object[]]$Rows, [datetime]$From, [datetime]$To, [string]$Operator, [string]$Tool, [string]$Search)
    if ($From.Date -gt $To.Date) { throw 'Start date must be on or before end date.' }
    $start=$From.Date.ToString('yyyy-MM-dd HH:mm:ss'); $end=$To.Date.AddDays(1).ToString('yyyy-MM-dd HH:mm:ss')
    foreach ($row in $Rows) {
        if ([string]::CompareOrdinal($row.Timestamp,$start) -lt 0 -or [string]::CompareOrdinal($row.Timestamp,$end) -ge 0) { continue }
        if ($Operator -and $row.Operator -ne $Operator) { continue }
        if ($Tool -and $row.Tool -ne $Tool) { continue }
        if ($Search -and (@($row.Target,$row.Action,$row.Result,$row.Detail,$row.Operator) -join ' ').IndexOf($Search,[StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $row
    }
}
