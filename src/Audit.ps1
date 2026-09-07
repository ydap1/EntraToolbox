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
