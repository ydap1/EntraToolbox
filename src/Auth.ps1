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

# ── Global app log ──────────────────────────────────────────────────────────
# Shared RichTextBox for the slide-up log pane at the bottom of the window.
# Set by MainWindow after XAML is loaded; tools call Write-AppLog.
$Script:AppLogBox = $null
$Script:DryMode   = $false

function Write-AppLog {
    param(
        [string]$Msg,
        [string]$Color = 'TextDim'
    )
    $ts   = Get-Date -Format 'HH:mm:ss'
    $line = "[$ts]  $Msg"
    Write-Log $line 'DEBUG'
    if (-not $Script:AppLogBox) { return }
    $Script:MainUI.Window.Dispatcher.Invoke([Action]{
        try {
            $para = New-Object System.Windows.Documents.Paragraph
            $run  = New-Object System.Windows.Documents.Run $line
            $run.Foreground = Get-ThemeHex $Color
            $para.Inlines.Add($run)
            $para.Margin = '0'
            $Script:AppLogBox.Document.Blocks.Add($para)
            if ($Script:AppLogBox.Document.Blocks.Count -gt 500) {
                $Script:AppLogBox.Document.Blocks.Remove($Script:AppLogBox.Document.Blocks.FirstBlock)
            }
            $Script:AppLogBox.ScrollToEnd()
        } catch {}
    }, 'Normal')
}

# ── In-tab rich-text log ──────────────────────────────────────────────────────
# Deprecated — tools should use Write-AppLog instead.  Kept for backward compat.
function Write-RichLog {
    param(
        $LogBox,
        [string]$Msg,
        [string]$Color = 'TextDim'
    )
    if (-not $LogBox) { Write-Log $Msg 'DEBUG'; return }
    $ts   = Get-Date -Format 'HH:mm:ss'
    $para = New-Object System.Windows.Documents.Paragraph
    $run  = New-Object System.Windows.Documents.Run "[$ts]  $Msg"
    $run.Foreground = Get-ThemeHex $Color
    $para.Inlines.Add($run)
    $para.Margin = '0'
    $LogBox.Document.Blocks.Add($para)
    $LogBox.ScrollToEnd()
}

# ── WPF callback session bridge ───────────────────────────────────────────────
# Dot-sourced functions live in the Start.ps1 script scope. WPF DispatcherTimer
# ticks and deferred UI callbacks can run in a child scope where those commands
# are not visible — causing "term X is not recognized" crashes. Set
# $Script:EtbSessionState once at startup (see Start.ps1) and route every
# dispatcher/async completion through Invoke-EtbScript.
$Script:EtbSessionState = $null

function Invoke-EtbScript {
    param(
        [Parameter(Mandatory)][scriptblock]$Script,
        [object[]]$ArgumentList = @()
    )
    if (-not $Script:EtbSessionState) {
        if ($ArgumentList.Count) { & $Script @ArgumentList } else { & $Script }
        return
    }
    # InvokeScript(string, object[]) runs the script in a child scope of the
    # captured session state so dot-sourced functions (Write-Log, etc.) are visible.
    # PowerShell unwraps $ArgumentList into individual positional $args entries
    # that map to the script's param() block.
    $Script:EtbSessionState.InvokeCommand.InvokeScript(
        $Script.ToString(),
        $ArgumentList
    )
}

# Invoke a dot-sourced function by name. Scriptblocks like { Start-Foo } capture the
# Initialize-* scope and break under InvokeScript — building the call from a string avoids that.
function Invoke-EtbCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [object[]]$ArgumentList = @()
    )
    $scriptText = if ($ArgumentList.Count) {
        "param(`$EtbArgs) & $Command @EtbArgs"
    } else {
        "& $Command"
    }
    if (-not $Script:EtbSessionState) {
        $sb = [scriptblock]::Create($scriptText)
        if ($ArgumentList.Count) { & $sb $ArgumentList } else { & $sb }
        return
    }
    $Script:EtbSessionState.InvokeCommand.InvokeScript(
        $scriptText,
        $ArgumentList
    )
}

function Register-ConnectCallback {
    param([Parameter(Mandatory)][string]$Command)
    $Script:ConnectCallbacks.Add($Command)
}

function New-EtbDispatcherTimer {
    param([int]$IntervalMs = 300)
    $dispatcher = if ($Script:MainUI -and $Script:MainUI.Window) {
        $Script:MainUI.Window.Dispatcher
    } else {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher
    }
    $timer = New-Object System.Windows.Threading.DispatcherTimer(
        [System.Windows.Threading.DispatcherPriority]::Background, $dispatcher)
    $timer.Interval = [TimeSpan]::FromMilliseconds($IntervalMs)
    $timer
}

# Runs all tool ConnectCallbacks on the next dispatcher frame so auth completion
# and UI setup finish before nine parallel Graph loads start. Each callback is
# isolated — one tool failing does not block the rest.
function Invoke-ConnectCallbacks {
    $dispatcher = if ($Script:MainUI -and $Script:MainUI.Window) {
        $Script:MainUI.Window.Dispatcher
    } else {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher
    }
    $null = $dispatcher.BeginInvoke([Action]{
        Invoke-EtbScript {
            foreach ($cmd in $Script:ConnectCallbacks) {
                try { Invoke-EtbCommand $cmd }
                catch { Write-Log "Connect callback error: $_" 'ERROR' }
            }
            Set-MainStatus 'Connected.' 'Success'
        }
    })
}

# ── Background runspace factory ───────────────────────────────────────────────
# CreateRunspace() with no arguments inherits the host's session state, so all
# built-in cmdlets (Invoke-RestMethod, Get-Date, etc.) are immediately available.
# CreateDefault() + ImportPSModule can miss cmdlets in some hosts because module
# auto-discovery depends on PSModulePath being set identically.
function New-BackgroundRunspace {
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $rs
}

# ── WPF-safe async runspace + completion timer ────────────────────────────────
# Runs $Script in a background Runspace with $Ref (synchronized hashtable), $Token
# (current access token unless -NoToken), and any extra $Vars set as session vars.
# When the runspace sets $Ref['Done']=$true, the DispatcherTimer stops itself,
# disposes the runspace, and invokes $OnComplete on the UI thread with $Ref as $args[0].
# Optional $OnProgress is called on every tick (UI thread) with $Ref before the Done
# check — useful for draining streaming progress queues that the worker fills as it runs.
# 401 responses are caught centrally and reported as $Ref['Error']='401'.
# Returns the DispatcherTimer so callers can Stop() a prior in-flight invocation.
function Start-AsyncWork {
    param(
        [Parameter(Mandatory)][scriptblock]$Script,
        [Parameter(Mandatory)][scriptblock]$OnComplete,
        [scriptblock]$OnProgress = $null,
        [hashtable]$Vars     = @{},
        [hashtable]$RefSeed  = @{},
        [int]$IntervalMs     = 300,
        [switch]$NoToken
    )
    $seed = @{ Done = $false; Error = $null }
    foreach ($k in $RefSeed.Keys) { $seed[$k] = $RefSeed[$k] }
    $ref = [hashtable]::Synchronized($seed)

    $rs = New-BackgroundRunspace
    $rs.SessionStateProxy.SetVariable('Ref', $ref)
    if (-not $NoToken) { $rs.SessionStateProxy.SetVariable('Token', $Script:AccessToken) }
    foreach ($k in $Vars.Keys) { $rs.SessionStateProxy.SetVariable($k, $Vars[$k]) }
    # Compile worker source inside the background runspace so Invoke-RestMethod etc.
    # resolve against that runspace — passing a main-session scriptblock does not.
    $rs.SessionStateProxy.SetVariable('WorkerText', $Script.ToString())

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        try {
            $body = [scriptblock]::Create($WorkerText)
            & $body
        }
        catch {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 401) {
                $Ref['Error'] = '401'
            } else {
                $Ref['Error'] = $_.Exception.Message
            }
        }
        finally { $Ref['Done'] = $true }
    })
    $async = $ps.BeginInvoke()

    $timer = New-EtbDispatcherTimer -IntervalMs $IntervalMs
    # Stash state on Tag — scriptblocks attached to events don't capture locals
    # like $OnComplete by closure, but $this gives them the timer at tick time.
    $timer.Tag = @{
        Ref        = $ref
        PS         = $ps
        RS         = $rs
        Async      = $async
        OnComplete = $OnComplete
        OnProgress = $OnProgress
    }
    $timer.Add_Tick({
        if ($this.Tag.OnProgress) {
            try { Invoke-EtbScript $this.Tag.OnProgress @($this.Tag.Ref) }
            catch { Invoke-EtbScript { Write-Log "Async OnProgress error: $_" 'ERROR' } }
        }
        if (-not $this.Tag.Ref['Done']) { return }
        $this.Stop()
        try { $this.Tag.PS.EndInvoke($this.Tag.Async) | Out-Null } catch {}
        $this.Tag.PS.Dispose()
        $this.Tag.RS.Close()
        $this.Tag.RS.Dispose()
        try { Invoke-EtbScript $this.Tag.OnComplete @($this.Tag.Ref) }
        catch { Invoke-EtbScript { Write-Log "Async OnComplete error: $_" 'ERROR' } }
    })
    $timer.Start()
    return $timer
}

# ── Theme ────────────────────────────────────────────────────────────────────
# Neutral slate-grey dark theme with an amber accent (replaces the old indigo/purple).
# Colours live in one place: $Script:Theme maps a semantic name to its hex value, and
# $Script:ThemeMap maps every legacy hex literal still embedded in the XAML here-strings
# to its new value so Invoke-ThemeXaml can re-skin the whole UI centrally.
$Script:Theme = @{
    Text      = '#E6E9EF'
    TextDim   = '#8A93A3'
    Muted     = '#5B6472'
    Accent    = '#F59E0B'
    Success   = '#22C55E'
    Danger    = '#EF4444'
    Warning   = '#FBBF24'
    Border    = '#323943'
    Card      = '#21262E'
    Surface   = '#181B21'
    Bg        = '#0F1115'
    Hover     = '#1E232B'
    Selected  = '#2A323D'
    GridLine  = '#1E232B'
    AltRow    = '#14171C'
    SubHeader = '#161A20'
    SuccessBg = '#0D2B1A'
    DangerBg  = '#2B0D0D'
    WarnText  = '#CC6666'
}

# Legacy-hex → new-hex translation applied to every XAML string at load time.
$Script:ThemeMap = [ordered]@{
    '#12121C' = $Script:Theme.Bg        # window background
    '#1C1C2A' = $Script:Theme.Surface   # surfaces / bars
    '#242436' = $Script:Theme.Card      # cards / inputs
    '#3C3C5A' = $Script:Theme.Border    # borders / secondary buttons
    '#6366F1' = $Script:Theme.Accent    # accent (was indigo)
    '#E2E2F0' = $Script:Theme.Text      # primary text
    '#7878A0' = $Script:Theme.TextDim   # dim text
    '#50507A' = $Script:Theme.Muted     # muted text
    '#1E1E38' = $Script:Theme.Hover     # row hover
    '#2A2A50' = $Script:Theme.Selected  # row selected
    '#1E1E32' = $Script:Theme.GridLine  # grid lines
    '#181826' = $Script:Theme.AltRow    # alternating rows
    '#1A1A2C' = $Script:Theme.SubHeader # sub headers
    '#C0C0E0' = '#C2C9D4'               # tab hover text
    '#2E2E48' = $Script:Theme.Selected  # combo-item hover
    '#7C3AED' = '#475569'               # demo button (was vivid purple → slate)
}

# Dark minimal scrollbar injected into every XAML via Invoke-ThemeXaml.
# Two ControlTemplates: vertical (default) and horizontal (via Orientation trigger).
# No arrow repeat-buttons — track + thumb only.
$Script:ThemeScrollBarStyle = @"
<Style TargetType="ScrollBar">
  <Setter Property="Background" Value="Transparent"/>
  <Setter Property="Width"      Value="8"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ScrollBar">
        <Grid>
          <Border Background="$($Script:Theme.Surface)" CornerRadius="4"/>
          <Track x:Name="PART_Track" IsDirectionReversed="True">
            <Track.Thumb>
              <Thumb>
                <Thumb.Template>
                  <ControlTemplate TargetType="Thumb">
                    <Border x:Name="bd" Background="$($Script:Theme.Border)" CornerRadius="4" Margin="1"/>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="bd" Property="Background" Value="$($Script:Theme.Muted)"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </Thumb.Template>
              </Thumb>
            </Track.Thumb>
          </Track>
        </Grid>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
  <Style.Triggers>
    <Trigger Property="Orientation" Value="Horizontal">
      <Setter Property="Height" Value="8"/>
      <Setter Property="Width"  Value="Auto"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid>
              <Border Background="$($Script:Theme.Surface)" CornerRadius="4"/>
              <Track x:Name="PART_Track">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border x:Name="bd" Background="$($Script:Theme.Border)" CornerRadius="4" Margin="1"/>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="bd" Property="Background" Value="$($Script:Theme.Muted)"/>
                          </Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Trigger>
  </Style.Triggers>
</Style>
"@

function Get-ThemeHex([string]$Semantic) {
    if ($Script:Theme.ContainsKey($Semantic)) { return $Script:Theme[$Semantic] }
    return $Semantic
}

# Re-skin a XAML here-string by swapping every legacy hex literal for its themed value.
function Invoke-ThemeXaml([string]$Xaml) {
    foreach ($old in $Script:ThemeMap.Keys) {
        $Xaml = $Xaml.Replace($old, $Script:ThemeMap[$old])
    }
    $Xaml = $Xaml.Replace('FontFamily="Segoe UI"', 'FontFamily="Fredoka, Segoe UI"')
    $Xaml = $Xaml.Replace('</Grid.Resources>',   "$Script:ThemeScrollBarStyle</Grid.Resources>")
    $Xaml = $Xaml.Replace('</Window.Resources>', "$Script:ThemeScrollBarStyle</Window.Resources>")
    $Xaml
}


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
    'https://graph.microsoft.com/TeamMember.ReadWrite.All',
    'https://graph.microsoft.com/SecurityEvents.Read.All'
)

# Per-tool callbacks fired after a new tenant connects (token ready) or before reset (token null)
$Script:ConnectCallbacks = [System.Collections.Generic.List[string]]::new()
$Script:ResetCallbacks   = [System.Collections.Generic.List[scriptblock]]::new()

# Reusable IPublicClientApplication per tenant — keeps the in-memory MSAL cache alive
# across tenant switches within the same session so silent re-auth never opens the browser.
$Script:MsalApps = @{}

# Async auth state
$Script:AuthRef     = $null
$Script:AuthTimer   = $null
$Script:AuthPS      = $null
$Script:AuthRS      = $null
$Script:AuthAsync   = $null
$Script:AuthSuccess = $null
$Script:AuthFailure = $null

function Complete-AuthWorker {
    if ($Script:AuthPS) {
        try { $Script:AuthPS.EndInvoke($Script:AuthAsync) | Out-Null } catch {}
        $Script:AuthPS.Dispose()
        $Script:AuthPS = $null
    }
    if ($Script:AuthRS) {
        $Script:AuthRS.Close()
        $Script:AuthRS.Dispose()
        $Script:AuthRS = $null
    }
    $Script:AuthAsync = $null
}

# ── Token cache persistence helper ───────────────────────────────────────────────
# MSAL.NET v4 removed the parameterless TokenCache.Serialize/DeserializeMsalV3 — they
# may only be called on the cache handed to a before/after-access notification. We can't
# do that with a PowerShell scriptblock delegate because MSAL fires the notification on
# its own threads (no Runspace attached → the delegate can't run). So we compile a tiny
# C# helper (the same technique as MSAL.PS's own TokenCacheHelper, which it disables on
# PS7) and register it on each app. The cache is stored DPAPI-encrypted for the current
# Windows user. Compiled once; the type is then visible to every background runspace.
$Script:TokenCacheHelperReady = $false
function Initialize-TokenCacheHelper {
    if (([System.Management.Automation.PSTypeName]'EtbTokenCacheHelper').Type) {
        $Script:TokenCacheHelperReady = $true
        return
    }
    try {
        # Force the DPAPI assembly to load so we can reference its on-disk location.
        $null = [System.Security.Cryptography.DataProtectionScope]
        $idClient = [AppDomain]::CurrentDomain.GetAssemblies() |
            Where-Object { $_.GetName().Name -eq 'Microsoft.Identity.Client' } | Select-Object -First 1
        if (-not $idClient) { throw 'Microsoft.Identity.Client assembly is not loaded' }
        $protData = [AppDomain]::CurrentDomain.GetAssemblies() |
            Where-Object { $_.GetName().Name -eq 'System.Security.Cryptography.ProtectedData' } | Select-Object -First 1
        $refs = @($idClient.Location)
        if ($protData -and $protData.Location) { $refs += $protData.Location }

        $src = @'
using System;
using System.IO;
using System.Security.Cryptography;
using Microsoft.Identity.Client;

public class EtbTokenCacheHelper
{
    private readonly string _path;
    public EtbTokenCacheHelper(string path) { _path = path; }

    public void Enable(IPublicClientApplication app)
    {
        app.UserTokenCache.SetBeforeAccess(Before);
        app.UserTokenCache.SetAfterAccess(After);
    }

    private void Before(TokenCacheNotificationArgs args)
    {
        try
        {
            if (File.Exists(_path))
            {
                byte[] raw = ProtectedData.Unprotect(File.ReadAllBytes(_path), null, DataProtectionScope.CurrentUser);
                args.TokenCache.DeserializeMsalV3(raw);
            }
        }
        catch { }
    }

    private void After(TokenCacheNotificationArgs args)
    {
        if (!args.HasStateChanged) { return; }
        try
        {
            byte[] enc = ProtectedData.Protect(args.TokenCache.SerializeMsalV3(), null, DataProtectionScope.CurrentUser);
            Directory.CreateDirectory(Path.GetDirectoryName(_path));
            File.WriteAllBytes(_path, enc);
        }
        catch { }
    }
}
'@
        Add-Type -TypeDefinition $src -ReferencedAssemblies $refs -IgnoreWarnings -WarningAction SilentlyContinue -ErrorAction Stop
        $Script:TokenCacheHelperReady = $true
        Write-Log 'Auth: token cache helper compiled — sign-in will persist across restarts' 'DEBUG'
    } catch {
        $Script:TokenCacheHelperReady = $false
        Write-Log "Auth: token cache helper unavailable — sign-in will NOT persist: $($_.Exception.Message)" 'WARN'
    }
}

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

# ── App settings (small key/value store, e.g. last-used tenant) ─────────────────
function Get-AppSettingsPath {
    $dir = Join-Path $Global:AppRoot 'config'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    Join-Path $dir 'settings.json'
}

function Get-AppSetting {
    param([Parameter(Mandatory)][string]$Name)
    $p = Get-AppSettingsPath
    if (-not (Test-Path $p)) { return $null }
    try {
        $s = Get-Content -Path $p -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($s.PSObject.Properties.Name -contains $Name) { return $s.$Name }
    } catch {}
    return $null
}

function Set-AppSetting {
    param([Parameter(Mandatory)][string]$Name, $Value)
    $p = Get-AppSettingsPath
    $s = if (Test-Path $p) {
        try { Get-Content -Path $p -Raw -ErrorAction Stop | ConvertFrom-Json } catch { [PSCustomObject]@{} }
    } else { [PSCustomObject]@{} }
    $s | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    ConvertTo-Json $s -Depth 5 | Set-Content -Path $p -Encoding UTF8
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
    Initialize-TokenCacheHelper
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

    $rs = New-BackgroundRunspace
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

            $app = if ($ExistingApp) { $ExistingApp } else {
                New-MsalClientApplication -ClientId $ClientId -TenantId $TenantId
            }

            # Hook the compiled token cache helper onto this app so the MSAL cache is read
            # before, and written after, every token operation (DPAPI-encrypted on disk).
            # The type is compiled once in the main session and is visible here via the
            # shared AppDomain. Registering on every connect is harmless and idempotent.
            if (([System.Management.Automation.PSTypeName]'EtbTokenCacheHelper').Type) {
                try {
                    $cacheHelper = New-Object EtbTokenCacheHelper -ArgumentList $CacheFile
                    $cacheHelper.Enable($app)
                    $AuthRef['CacheEnabled'] = $true
                } catch {
                    $AuthRef['CacheWarning'] = "Token cache persistence failed to attach: $($_.Exception.Message)"
                }
            } else {
                $AuthRef['CacheWarning'] = 'Token cache helper not compiled — tokens will not persist across restarts'
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
                # The cache is written to disk automatically by the after-access callback above.
            } else {
                $AuthRef['Error'] = 'Token acquisition returned null.'
            }
        } catch {
            $ex = $_.Exception
            $detail = "$($ex.GetType().Name): $($ex.Message)"
            if ($ex.InnerException) { $detail += " | inner: $($ex.InnerException.GetType().Name): $($ex.InnerException.Message)" }
            $AuthRef['Error'] = $detail
        } finally {
            $AuthRef['Done'] = $true
        }
    })
    $Script:AuthPS    = $ps
    $Script:AuthRS    = $rs
    $Script:AuthAsync = $ps.BeginInvoke()

    if ($Script:AuthTimer) { $Script:AuthTimer.Stop() }
    $Script:AuthTimer = New-EtbDispatcherTimer -IntervalMs 500
    $Script:AuthTimer.Add_Tick({
        if (-not $Script:AuthRef['Done']) { return }
        $Script:AuthTimer.Stop()
        Complete-AuthWorker
        try {
            Invoke-EtbScript {
                if ($Script:AuthRef['Error']) {
                    Write-Log "Auth failed: $($Script:AuthRef['Error'])" 'ERROR'
                    Invoke-EtbScript $Script:AuthFailure @($Script:AuthRef['Error'])
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
                Invoke-EtbScript $Script:AuthSuccess
                if ($Script:AuthRef['AccountUPN']) {
                    Set-TenantAccountHint -TenantId $Script:AuthRef['TenantId'] `
                                          -AccountHint $Script:AuthRef['AccountUPN']
                    Write-Log "Auth: account hint saved ($($Script:AuthRef['AccountUPN']))" 'DEBUG'
                }
            }
        } catch {
            try { Invoke-EtbScript { Write-Log "Auth timer tick error: $_" 'ERROR' } }
            catch { Write-Host "[ERROR] Auth timer tick error: $_" -ForegroundColor Red }
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
