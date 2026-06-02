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
    'https://graph.microsoft.com/GroupMember.ReadWrite.All',
    'https://graph.microsoft.com/Team.Create',
    'https://graph.microsoft.com/TeamMember.ReadWrite.All'
)

# Per-tool callbacks fired after a new tenant connects (token ready) or before reset (token null)
$Script:ConnectCallbacks = [System.Collections.Generic.List[scriptblock]]::new()
$Script:ResetCallbacks   = [System.Collections.Generic.List[scriptblock]]::new()

# Reusable IPublicClientApplication per tenant — keeps the in-memory MSAL cache alive
# across tenant switches within the same session so silent re-auth never opens the browser.
$Script:MsalApps = @{}

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

function Get-TenantCacheFile {
    param([string]$TenantId)
    $cacheDir = Join-Path $Global:AppRoot 'config\msal_cache'
    if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
    Join-Path $cacheDir "token_cache_$($TenantId -replace '[^a-zA-Z0-9]','').bin"
}

function Get-TenantAccountHint {
    param([string]$TenantId)
    $t = @(Get-SavedTenants) | Where-Object { $_.TenantId -eq $TenantId } | Select-Object -First 1
    if ($t -and $t.AccountHint) { return $t.AccountHint }
    return $null
}

function Set-TenantAccountHint {
    param([string]$TenantId, [string]$AccountHint)
    $all = @(Get-SavedTenants)
    foreach ($t in $all) {
        if ($t.TenantId -eq $TenantId) {
            $t | Add-Member -NotePropertyName 'AccountHint' -NotePropertyValue $AccountHint -Force
        }
    }
    ConvertTo-Json @($all) -Depth 3 | Set-Content -Path (Get-TenantsConfigPath) -Encoding UTF8
}

function Disconnect-Tenant {
    param([Parameter(Mandatory)][string]$TenantId)
    $Script:AccessToken     = $null
    $Script:CurrentTenantId = $null
    $Script:MsalApps.Remove($TenantId)
    $cacheFile = Get-TenantCacheFile -TenantId $TenantId
    if (Test-Path $cacheFile) { Remove-Item $cacheFile -Force -ErrorAction SilentlyContinue }
    Set-TenantAccountHint -TenantId $TenantId -AccountHint ''
    Write-Log "Tenant $TenantId disconnected and credentials cleared" 'INFO'
}

# ── Async auth ─────────────────────────────────────────────────────────────────
# Get-MsalToken -Interactive MUST NOT run on the WPF UI thread (deadlock).
# Run it in a background runspace and poll with a DispatcherTimer.
# On first connect the user authenticates interactively; the account UPN and a
# DPAPI-encrypted MSAL cache are saved so every subsequent launch authenticates
# silently (no browser popup) until Disconnect-Tenant is called.
function Start-TenantConnectAsync {
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][scriptblock]$OnSuccess,
        [Parameter(Mandatory)][scriptblock]$OnFailure
    )

    Write-Log "Auth: starting token acquisition for tenant $TenantId" 'DEBUG'
    $cacheFile   = Get-TenantCacheFile  -TenantId $TenantId
    $accountHint = Get-TenantAccountHint -TenantId $TenantId
    if ($accountHint) { Write-Log "Auth: using saved account hint $accountHint" 'DEBUG' }

    # Reuse the existing app for this tenant if we have one — its in-memory MSAL cache
    # means silent auth within the same session never opens the browser.
    $existingApp = if ($Script:MsalApps.ContainsKey($TenantId)) { $Script:MsalApps[$TenantId] } else { $null }
    if ($existingApp) { Write-Log "Auth: reusing cached app for tenant $TenantId" 'DEBUG' }

    $Script:AuthRef = [hashtable]::Synchronized(@{
        Done         = $false
        Token        = $null
        Error        = $null
        TenantId     = $TenantId
        AccountUPN   = $null
        CacheEnabled = $false
        CacheWarning = $null
        App          = $null
    })
    $Script:AuthSuccess = $OnSuccess
    $Script:AuthFailure = $OnFailure

    $clientId = $Script:GraphClientId
    $scopes   = $Script:GraphScopes

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('AuthRef',      $Script:AuthRef)
    $rs.SessionStateProxy.SetVariable('TenantId',     $TenantId)
    $rs.SessionStateProxy.SetVariable('ClientId',     $clientId)
    $rs.SessionStateProxy.SetVariable('Scopes',       $scopes)
    $rs.SessionStateProxy.SetVariable('CacheFile',    $cacheFile)
    $rs.SessionStateProxy.SetVariable('AccountHint',  $accountHint)
    $rs.SessionStateProxy.SetVariable('ExistingApp',  $existingApp)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        try {
            Import-Module MSAL.PS -ErrorAction Stop

            if ($ExistingApp) {
                # Reuse the in-session app — no file cache setup needed; tokens are in memory.
                $app = $ExistingApp
                $AuthRef['CacheEnabled'] = $true
            } else {
                $app = New-MsalClientApplication -ClientId $ClientId -TenantId $TenantId

                # Hook a file-based token cache so silent re-auth works across restarts.
                # MSAL callbacks fire from a .NET thread pool thread with no PS runspace,
                # so we must use a compiled C# class — PS scriptblocks would crash there.
                # Hashtable (System.Collections) is used instead of Dictionary<,> because
                # generic type resolution can fail in a minimal background runspace.
                try {
                    $msalMod = Get-Module MSAL.PS -ErrorAction SilentlyContinue
                    $msalDll = $null
                    if ($msalMod) {
                        $msalDll = Get-ChildItem -Path $msalMod.ModuleBase `
                                       -Filter 'Microsoft.Identity.Client.dll' -Recurse `
                                       -ErrorAction SilentlyContinue |
                                   Select-Object -First 1 -ExpandProperty FullName
                    }
                    if (-not $msalDll) {
                        $msalDll = ([System.AppDomain]::CurrentDomain.GetAssemblies() |
                            Where-Object { $_.GetName().Name -eq 'Microsoft.Identity.Client' } |
                            Select-Object -First 1).Location
                    }
                    if (-not $msalDll -or -not (Test-Path $msalDll)) {
                        throw "Microsoft.Identity.Client.dll not found"
                    }

                    $src = @'
using System; using System.IO; using System.Collections; using Microsoft.Identity.Client;
public static class EntraToolboxCache {
    private static readonly Hashtable _map = new Hashtable();
    private static readonly object L = new object();
    public static void Enable(ITokenCache c, string path) { lock(L){_map[c]=path;} c.SetBeforeAccess(B); c.SetAfterAccess(A); }
    private static void B(TokenCacheNotificationArgs n) { lock(L){ string f=(string)_map[n.TokenCache]; if(f==null||!File.Exists(f))return; try{n.TokenCache.DeserializeMsalV3(File.ReadAllBytes(f));}catch{} } }
    private static void A(TokenCacheNotificationArgs n) { if(!n.HasStateChanged)return; lock(L){ string f=(string)_map[n.TokenCache]; if(f==null)return; try{ string dir=Path.GetDirectoryName(f); if(!Directory.Exists(dir))Directory.CreateDirectory(dir); File.WriteAllBytes(f,n.TokenCache.SerializeMsalV3()); }catch{} } }
}
'@
                    $typeKnown = $false
                    try { $typeKnown = $null -ne [EntraToolboxCache] } catch { }
                    if (-not $typeKnown) {
                        Add-Type -TypeDefinition $src -ReferencedAssemblies @($msalDll) -ErrorAction Stop
                    }
                    [EntraToolboxCache]::Enable($app.UserTokenCache, $CacheFile)
                    $AuthRef['CacheEnabled'] = $true
                } catch {
                    $AuthRef['CacheWarning'] = "Token cache setup failed: $_"
                }
            }

            # Step 1: silent auth
            $token    = $null
            $silentEx = $null
            try {
                $silentParams = @{
                    PublicClientApplication = $app
                    Scopes                  = $Scopes
                    Silent                  = $true
                    ErrorAction             = 'Stop'
                }
                if ($AccountHint) { $silentParams['LoginHint'] = $AccountHint }
                $token = Get-MsalToken @silentParams
            } catch {
                $silentEx = $_.Exception
                $token    = $null
            }

            # Step 2: interactive fallback
            if (-not $token) {
                $iParams = @{
                    PublicClientApplication = $app
                    Scopes                  = $Scopes
                    Interactive             = $true
                }
                # Carry the claims challenge so Azure AD prompts for MFA even when an
                # SSO session exists — without this, AADSTS50076 loops back on itself.
                try {
                    $claims = $silentEx.Claims
                    if ($claims) { $iParams['ExtraQueryParameters'] = @{ claims = $claims } }
                } catch { }
                try {
                    $token = Get-MsalToken @iParams -ErrorAction Stop
                } catch {
                    # If AADSTS50076 still comes back from interactive, strip the stale
                    # SSO session by adding prompt=login and try once more.
                    if ($_.Exception.Message -match 'AADSTS5007[69]') {
                        [void]$iParams.Remove('ExtraQueryParameters')
                        $iParams['ExtraQueryParameters'] = @{ prompt = 'login' }
                        $token = Get-MsalToken @iParams
                    } else {
                        throw
                    }
                }
            }
            if ($token -and $token.AccessToken) {
                $AuthRef['Token']      = $token.AccessToken
                $AuthRef['AccountUPN'] = $token.Account.Username
                $AuthRef['App']        = $app
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
            if ($Script:AuthRef['CacheWarning']) {
                Write-Log "Auth: $($Script:AuthRef['CacheWarning'])" 'WARN'
            } elseif ($Script:AuthRef['CacheEnabled']) {
                Write-Log 'Auth: token cache hooked successfully' 'DEBUG'
            }
            Write-Log 'Auth succeeded - token acquired' 'INFO'
            $Script:AccessToken     = $Script:AuthRef['Token']
            $Script:CurrentTenantId = $Script:AuthRef['TenantId']
            if ($Script:AuthRef['App']) {
                $Script:MsalApps[$Script:AuthRef['TenantId']] = $Script:AuthRef['App']
            }
            # OnSuccess may call Save-Tenant (new-tenant dialog), so run it first to
            # ensure the tenant row exists before we write the account hint into it.
            & $Script:AuthSuccess
            if ($Script:AuthRef['AccountUPN']) {
                Set-TenantAccountHint -TenantId $Script:AuthRef['TenantId'] `
                                      -AccountHint $Script:AuthRef['AccountUPN']
                Write-Log "Auth: account hint saved ($($Script:AuthRef['AccountUPN']))" 'DEBUG'
            }
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
