<#
    Shared authentication and Graph REST helpers for Art's Entra Toolbox.
    Dot-sourced by Start.ps1.

    Auth strategy: MSAL.PS acquires the token interactively once, then silently from
    its in-memory cache. Token stored in $Script:AccessToken.
    All Graph calls use Invoke-RestMethod with a Bearer header - no Graph SDK needed.
#>

# ── Debug logger ───────────────────────────────────────────────────────────────
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'HH:mm:ss.fff'
    $color = switch ($Level) {
        'INFO'  { 'Cyan' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'DEBUG' { 'DarkGray' }
    }
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $color
}

function Get-ThemeHex([string]$Semantic) {
    switch ($Semantic) {
        'Text'      { '#E2E2F0' }
        'TextDim'   { '#7878A0' }
        'Muted'     { '#50507A' }
        'Accent'    { '#6366F1' }
        'Success'   { '#22C55E' }
        'Danger'    { '#EF4444' }
        'Warning'   { '#FBBF24' }
        'Border'    { '#3C3C5A' }
        'Card'      { '#242436' }
        'Surface'   { '#1C1C2A' }
        'Bg'        { '#12121C' }
        'Hover'     { '#1E1E38' }
        'Selected'  { '#2A2A50' }
        'GridLine'  { '#1E1E32' }
        'AltRow'    { '#181826' }
        'SubHeader' { '#1A1A2C' }
        'SuccessBg' { '#0D2B1A' }
        'DangerBg'  { '#2B0D0D' }
        'WarnText'  { '#CC6666' }
        default     { $Semantic }
    }
}

function Invoke-ThemeXaml([string]$Xaml) { $Xaml }


# ── Shared state ───────────────────────────────────────────────────────────────
$Script:AccessToken       = $null
$Script:CurrentTenantId   = $null

# Well-known Microsoft Intune PowerShell public client app ID - no app registration needed
$Script:GraphClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'

# Combined scopes for all tools
$Script:GraphScopes = @(
    'https://graph.microsoft.com/User.ReadWrite.All',
    'https://graph.microsoft.com/DeviceManagementManagedDevices.Read.All',
    'https://graph.microsoft.com/AuditLog.Read.All',
    'https://graph.microsoft.com/GroupMember.ReadWrite.All'
)

# Per-tool callbacks fired after a new tenant connects (token ready) or before reset (token null)
$Script:ConnectCallbacks = [System.Collections.Generic.List[scriptblock]]::new()
$Script:ResetCallbacks   = [System.Collections.Generic.List[scriptblock]]::new()

# Async auth state
$Script:AuthRef     = $null
$Script:AuthTimer   = $null
$Script:AuthSuccess = $null
$Script:AuthFailure = $null

# ── Tenant config ──────────────────────────────────────────────────────────────
function Get-TenantsConfigPath {
    $dir = Join-Path $Global:AppRoot 'config'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    Join-Path $dir 'tenants.json'
}

function Get-SavedTenants {
    $p = Get-TenantsConfigPath
    if (-not (Test-Path $p)) { return @() }
    $raw = Get-Content -Path $p -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    return @($raw | ConvertFrom-Json)
}

function Save-Tenant {
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [string]$DisplayName = ''
    )
    $existing = @(Get-SavedTenants)
    if ($existing | Where-Object { $_.TenantId -eq $TenantId }) { return }
    $all = $existing + @([PSCustomObject]@{ TenantId = $TenantId; DisplayName = $DisplayName })
    ConvertTo-Json @($all) -Depth 3 | Set-Content -Path (Get-TenantsConfigPath) -Encoding UTF8
}

function Remove-SavedTenant {
    param([Parameter(Mandatory)][string]$TenantId)
    $remaining = @(Get-SavedTenants | Where-Object { $_.TenantId -ne $TenantId })
    ConvertTo-Json @($remaining) -Depth 3 | Set-Content -Path (Get-TenantsConfigPath) -Encoding UTF8
}

# ── Async auth ─────────────────────────────────────────────────────────────────
# Get-MsalToken -Interactive MUST NOT run on the WPF UI thread (deadlock).
# Run it in a background runspace and poll with a DispatcherTimer.
function Start-TenantConnectAsync {
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][scriptblock]$OnSuccess,
        [Parameter(Mandatory)][scriptblock]$OnFailure
    )

    Write-Log "Auth: starting token acquisition for tenant $TenantId" 'DEBUG'
    $Script:AuthRef     = [hashtable]::Synchronized(@{ Done = $false; Token = $null; Error = $null })
    $Script:AuthSuccess = $OnSuccess
    $Script:AuthFailure = $OnFailure

    $clientId = $Script:GraphClientId
    $scopes   = $Script:GraphScopes

    # Persistent token cache — DPAPI-encrypted MSAL V3 format, stored per-app
    $cacheDir = Join-Path $Global:AppRoot 'config\msal_cache'
    if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('AuthRef',  $Script:AuthRef)
    $rs.SessionStateProxy.SetVariable('TenantId', $TenantId)
    $rs.SessionStateProxy.SetVariable('ClientId', $clientId)
    $rs.SessionStateProxy.SetVariable('Scopes',   $scopes)
    $rs.SessionStateProxy.SetVariable('CacheDir', $cacheDir)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        try {
            Import-Module MSAL.PS -ErrorAction Stop

            $cacheFile = Join-Path $CacheDir 'token_cache.bin'
            $app = New-MsalClientApplication -ClientId $ClientId -TenantId $TenantId

            # MSAL.PS polls Get-MsalToken via Start-Sleep — MSAL executes on a thread pool
            # thread that has no PS runspace. Scriptblock delegates fail there, so we compile
            # a native C# class to handle cache I/O entirely in .NET.
            try {
                $msalDll = ([System.AppDomain]::CurrentDomain.GetAssemblies() |
                    Where-Object { $_.GetName().Name -eq 'Microsoft.Identity.Client' } |
                    Select-Object -First 1).Location

                $refs = [System.Collections.Generic.List[string]]::new()
                $refs.Add($msalDll)

                # ProtectedData (DPAPI) is available on Windows PS7 — include if possible
                $withDpapi = $false
                try {
                    $pdDll = [System.Security.Cryptography.ProtectedData].Assembly.Location
                    if ($pdDll) { $refs.Add($pdDll); $withDpapi = $true }
                } catch { }

                $src = if ($withDpapi) { @'
using System; using System.IO; using System.Security.Cryptography; using Microsoft.Identity.Client;
public static class EntraToolboxCache {
    private static string F; private static readonly object L = new object();
    public static void Enable(ITokenCache c, string path) { F=path; c.SetBeforeAccess(B); c.SetAfterAccess(A); }
    private static void B(TokenCacheNotificationArgs n) { lock(L){ if(!File.Exists(F))return; try{ byte[]d=File.ReadAllBytes(F); try{d=ProtectedData.Unprotect(d,null,DataProtectionScope.CurrentUser);}catch{} n.TokenCache.DeserializeMsalV3(d); }catch{} } }
    private static void A(TokenCacheNotificationArgs n) { if(!n.HasStateChanged)return; lock(L){ try{ byte[]d=n.TokenCache.SerializeMsalV3(); try{d=ProtectedData.Protect(d,null,DataProtectionScope.CurrentUser);}catch{} string dir=Path.GetDirectoryName(F); if(!Directory.Exists(dir))Directory.CreateDirectory(dir); File.WriteAllBytes(F,d); }catch{} } }
}
'@ } else { @'
using System; using System.IO; using Microsoft.Identity.Client;
public static class EntraToolboxCache {
    private static string F; private static readonly object L = new object();
    public static void Enable(ITokenCache c, string path) { F=path; c.SetBeforeAccess(B); c.SetAfterAccess(A); }
    private static void B(TokenCacheNotificationArgs n) { lock(L){ if(!File.Exists(F))return; try{n.TokenCache.DeserializeMsalV3(File.ReadAllBytes(F));}catch{} } }
    private static void A(TokenCacheNotificationArgs n) { if(!n.HasStateChanged)return; lock(L){ try{ string dir=Path.GetDirectoryName(F); if(!Directory.Exists(dir))Directory.CreateDirectory(dir); File.WriteAllBytes(F,n.TokenCache.SerializeMsalV3()); }catch{} } }
}
'@ }

                # Only compile once per AppDomain (multiple auth calls share the process)
                $typeKnown = $false
                try { $typeKnown = $null -ne [EntraToolboxCache] } catch { }
                if (-not $typeKnown) {
                    Add-Type -TypeDefinition $src -ReferencedAssemblies $refs.ToArray() -ErrorAction Stop
                }
                [EntraToolboxCache]::Enable($app.UserTokenCache, $cacheFile)
            } catch { }

            $token = $null
            try {
                $token = Get-MsalToken -PublicClientApplication $app -Scopes $Scopes `
                                       -Silent -ErrorAction Stop
            } catch { $token = $null }
            if (-not $token) {
                $token = Get-MsalToken -PublicClientApplication $app -Scopes $Scopes -Interactive
            }
            if ($token -and $token.AccessToken) {
                $AuthRef['Token'] = $token.AccessToken
            } else {
                $AuthRef['Error'] = 'Token acquisition returned null.'
            }
        } catch {
            $AuthRef['Error'] = $_.Exception.Message
        } finally {
            $AuthRef['Done'] = $true
        }
    })
    $ps.BeginInvoke() | Out-Null

    if ($Script:AuthTimer) { $Script:AuthTimer.Stop() }
    $Script:AuthTimer          = [System.Windows.Threading.DispatcherTimer]::new()
    $Script:AuthTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $Script:AuthTimer.Add_Tick({
        try {
            if (-not $Script:AuthRef['Done']) { return }
            $Script:AuthTimer.Stop()
            if ($Script:AuthRef['Error']) {
                Write-Log "Auth failed: $($Script:AuthRef['Error'])" 'ERROR'
                & $Script:AuthFailure $Script:AuthRef['Error']
                return
            }
            Write-Log 'Auth succeeded - token acquired' 'INFO'
            $Script:AccessToken = $Script:AuthRef['Token']
            & $Script:AuthSuccess
        } catch {
            Write-Log "Auth timer tick error: $_" 'ERROR'
        }
    })
    $Script:AuthTimer.Start()
}

# ── Graph REST helpers ─────────────────────────────────────────────────────────
function Invoke-GraphGet {
    param([string]$Path)
    Invoke-RestMethod -Uri "https://graph.microsoft.com$Path" `
        -Headers @{ Authorization = "Bearer $Script:AccessToken" } `
        -Method GET -ErrorAction Stop
}

function Invoke-GraphPatch {
    param([string]$Path, [hashtable]$Body)
    Invoke-RestMethod -Uri "https://graph.microsoft.com$Path" `
        -Headers @{
            Authorization  = "Bearer $Script:AccessToken"
            'Content-Type' = 'application/json'
        } `
        -Method PATCH -Body ($Body | ConvertTo-Json -Depth 10) -ErrorAction Stop
}

function Get-GraphPaged {
    param([string]$Path)
    $items = [System.Collections.Generic.List[object]]::new()
    $url = "https://graph.microsoft.com$Path"
    do {
        $resp = Invoke-RestMethod -Uri $url `
            -Headers @{ Authorization = "Bearer $Script:AccessToken" } `
            -Method GET -ErrorAction Stop
        foreach ($i in $resp.value) { $items.Add($i) }
        $url = $resp.'@odata.nextLink'
    } while ($url)
    $items.ToArray()
}

function Get-TenantDisplayName {
    if ($Script:DemoMode) { return 'Contoso Academy' }
    try {
        $resp = Invoke-GraphGet '/v1.0/organization?$select=displayName'
        if ($resp.value -and $resp.value.Count -gt 0) { return $resp.value[0].displayName }
    } catch {}
    return ''
}
