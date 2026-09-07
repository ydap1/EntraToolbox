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

# ── Worker Graph resilience preamble ──────────────────────────────────────────
# Prepended to every Start-AsyncWork worker script. Defines a function named
# Invoke-RestMethod which shadows the cmdlet (functions win command resolution),
# so every Graph call in every tool transparently retries on 429 throttling
# (honouring Retry-After) and transient 502/503/504 with exponential backoff.
# Non-retryable errors are rethrown untouched, so existing per-tool catch blocks
# (401/403 classification etc.) keep working exactly as before.
$Script:EtbWorkerPreamble = Get-Content (Join-Path $PSScriptRoot 'Graph.ps1') -Raw
. (Join-Path $PSScriptRoot 'Graph.ps1')
. (Join-Path $PSScriptRoot 'Data.ps1')
. (Join-Path $PSScriptRoot 'Audit.ps1')

# ── WPF-safe async runspace + completion timer ────────────────────────────────
# Runs $Script in a background Runspace with $Ref (synchronized hashtable), $Token
# (current access token unless -NoToken), and any extra $Vars set as session vars.
# When the runspace sets $Ref['Done']=$true, the DispatcherTimer stops itself,
# disposes the runspace, and invokes $OnComplete on the UI thread with $Ref as $args[0].
# Optional $OnProgress is called on every tick (UI thread) with $Ref before the Done
# check — useful for draining streaming progress queues that the worker fills as it runs.
# 401 responses are caught centrally and reported as $Ref['Error']='401'.
# Returns the DispatcherTimer so callers can Stop() a prior in-flight invocation.
$Script:SessionGeneration = 0
$Script:AsyncJobs = [System.Collections.Generic.List[object]]::new()
$Script:WorkerCleanupTimer = $null

function Complete-EtbAsyncWork {
    param($Timer)
    $state = $Timer.Tag
    if (-not $state -or -not $state.Async.IsCompleted) { return }
    if ($state.StopAsync -and -not $state.StopAsync.IsCompleted) { return }
    $Timer.Stop()
    try {
        if ($state.StopAsync) { $state.PS.EndStop($state.StopAsync) }
        $state.PS.EndInvoke($state.Async) | Out-Null
    } catch { } finally {
        $state.PS.Dispose()
        $state.RS.Dispose()
        $Timer.Tag = $null
        [void]$Script:AsyncJobs.Remove($Timer)
    }
}

function Stop-EtbAsyncWork {
    param($Timer)
    if (-not $Timer) { return }
    $Timer.Stop()
    $state = $Timer.Tag
    if (-not $state -or -not $state.PS) { return }
    $state.Ref['Cancelled'] = $true
    if (-not $state.Async.IsCompleted -and -not $state.StopAsync) {
        $state.StopAsync = $state.PS.BeginStop($null, $null)
    }
    Complete-EtbAsyncWork $Timer
}

# Cooperative cancellation for long batches. Unlike Stop-EtbAsyncWork, which
# aborts the pipeline and never reaches OnComplete, this asks the worker to stop
# at its next loop iteration. The request it is already on finishes, results
# collected so far are kept, and OnComplete still runs — so the tool can report
# how far it got and re-enable its own controls.
function Request-EtbAsyncCancel {
    param($Timer)
    if (-not $Timer -or -not $Timer.Tag -or -not $Timer.Tag.Ref) { return }
    $Timer.Tag.Ref['CancelRequested'] = $true
}

# Access tokens expire after roughly an hour. A worker captures the token when
# it starts, so a batch that outlives it used to fail the rest of its items with
# 401. The silent refresh publishes the new token into every live worker's $Ref,
# and the Graph shim in Graph.ps1 picks it up on the next request.
function Publish-EtbWorkerToken {
    foreach ($job in $Script:AsyncJobs.ToArray()) {
        if ($job.Tag -and $job.Tag.Ref) { $job.Tag.Ref['Token'] = $Script:AccessToken }
    }
}

function Start-EtbWorkerCleanup {
    if (-not $Script:WorkerCleanupTimer) {
        $Script:WorkerCleanupTimer = New-EtbDispatcherTimer
        $Script:WorkerCleanupTimer.Add_Tick({
            Invoke-EtbScript {
                foreach ($job in $Script:AsyncJobs.ToArray()) {
                    # Existing tools stop their timer when a selection changes.
                    # Cancel and reap its pipeline too, without blocking WPF.
                    if (-not $job.IsEnabled) { Stop-EtbAsyncWork $job }
                }
                if ($Script:AsyncJobs.Count -eq 0) { $Script:WorkerCleanupTimer.Stop() }
            }
        })
    }
    $Script:WorkerCleanupTimer.Start()
}

function Reset-EtbSessionWork {
    $Script:SessionGeneration++
    foreach ($job in $Script:AsyncJobs.ToArray()) {
        if (-not $job.Tag.Independent) { Stop-EtbAsyncWork $job }
    }
    $Script:TokenRefreshBusy = $false
    $Script:AuthRef = $null
    $Script:CurrentTenantId = $null
    $Script:CurrentAccountUPN = $null
    $Script:AuditPathLogged = $false
    $Script:TokenExpiresOn = $null
    $Script:AccessToken = $null
}

function Start-AsyncWork {
    param(
        [Parameter(Mandatory)][scriptblock]$Script,
        [Parameter(Mandatory)][scriptblock]$OnComplete,
        [scriptblock]$OnProgress = $null,
        [hashtable]$Vars     = @{},
        [hashtable]$RefSeed  = @{},
        [int]$IntervalMs     = 300,
        [switch]$NoToken,
        [switch]$SessionIndependent
    )
    $seed = @{ Done = $false; Error = $null; Cancelled = $false; CancelRequested = $false }
    foreach ($k in $RefSeed.Keys) { $seed[$k] = $RefSeed[$k] }
    $ref = [hashtable]::Synchronized($seed)

    $rs = New-BackgroundRunspace
    $rs.SessionStateProxy.SetVariable('Ref', $ref)
    $rs.SessionStateProxy.SetVariable('DryMode', $Script:DryMode)
    if (-not $NoToken) {
        $rs.SessionStateProxy.SetVariable('Token', $Script:AccessToken)
        # Also on $Ref so a silent refresh can replace it mid-run.
        $ref['Token'] = $Script:AccessToken
    }
    foreach ($k in $Vars.Keys) { $rs.SessionStateProxy.SetVariable($k, $Vars[$k]) }
    # Compile worker source inside the background runspace so Invoke-RestMethod etc.
    # resolve against that runspace — passing a main-session scriptblock does not.
    # The resilience preamble is prepended so its Invoke-RestMethod retry shim is
    # in scope for the whole worker body.
    $rs.SessionStateProxy.SetVariable('WorkerText', $Script:EtbWorkerPreamble + "`n" + $Script.ToString())

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        $ErrorActionPreference = 'Stop'
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
        Generation = $Script:SessionGeneration
        Independent = [bool]$SessionIndependent
        StopAsync  = $null
        PS         = $ps
        RS         = $rs
        Async      = $async
        OnComplete = $OnComplete
        OnProgress = $OnProgress
    }
    $timer.Add_Tick({
        if (-not $this.Tag.Independent -and $this.Tag.Generation -ne $Script:SessionGeneration) {
            Stop-EtbAsyncWork $this
            return
        }
        if ($this.Tag.OnProgress) {
            try { Invoke-EtbScript $this.Tag.OnProgress @($this.Tag.Ref) }
            catch { Invoke-EtbScript { Write-Log "Async OnProgress error: $_" 'ERROR' } }
        }
        if (-not $this.Tag.Async.IsCompleted) { return }
        $this.Stop()
        $state = $this.Tag
        Complete-EtbAsyncWork $this
        try { Invoke-EtbScript $state.OnComplete @($state.Ref) }
        catch { Write-Log "Async OnComplete error: $_" 'ERROR' }
    })
    $Script:AsyncJobs.Add($timer)
    Start-EtbWorkerCleanup
    $timer.Start()
    return $timer
}

# ── App settings (small key/value store, e.g. last-used tenant, theme, font) ────
# Defined before the Theme section below because theme/font selection reads them
# at dot-source time.
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

# ── Theme ────────────────────────────────────────────────────────────────────
# Colours live in one place: $Script:Theme maps a semantic name to its hex value, and
# $Script:ThemeMap maps every legacy hex literal still embedded in the XAML here-strings
# to its new value so Invoke-ThemeXaml can re-skin the whole UI centrally.
# The active preset and font are chosen in the Appearance page and persisted via
# Set-AppSetting; because colours are baked into each panel's XAML at load time,
# a change takes effect on the next launch (Appearance offers Apply & Restart).
$Script:ThemeBase = @{
    Text      = '#E6E9EF'
    TextDim   = '#A3ADBC'
    Muted     = '#8994A5'
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

# Preset name → overrides applied on top of ThemeBase.
$Script:ThemePresets = [ordered]@{
    'Slate & Amber' = @{}
    'Indigo Night'  = @{
        Accent='#6366F1'; Bg='#12121C'; Surface='#1C1C2A'; Card='#242436'; Border='#3C3C5A'
        Text='#E2E2F0'; TextDim='#A0A0C0'; Muted='#9191AD'
        Hover='#1E1E38'; Selected='#2A2A50'; GridLine='#1E1E32'; AltRow='#181826'; SubHeader='#1A1A2C'
    }
    'Ocean' = @{
        Accent='#38BDF8'; Bg='#0D1420'; Surface='#131C2B'; Card='#1A2537'; Border='#2C3A52'
        Text='#E4EAF4'; TextDim='#8C98AC'; Muted='#8C98AC'
        Hover='#182338'; Selected='#243450'; GridLine='#182338'; AltRow='#111927'; SubHeader='#141E30'
    }
    'Forest' = @{
        Accent='#34D399'; Bg='#0E1512'; Surface='#14201B'; Card='#1B2A23'; Border='#2E4438'
        Text='#E4EFE9'; TextDim='#8CA396'; Muted='#8CA396'
        Hover='#1A2921'; Selected='#273B31'; GridLine='#1A2921'; AltRow='#111B16'; SubHeader='#15221C'
    }
    'Rose' = @{
        Accent='#FB7185'; Bg='#170F13'; Surface='#1F151A'; Card='#291C22'; Border='#443039'
        Text='#F0E6EA'; TextDim='#A38C96'; Muted='#725C64'
        Hover='#271B21'; Selected='#3A2932'; GridLine='#271B21'; AltRow='#1B1216'; SubHeader='#211619'
    }
}

$Script:ThemeName = 'Slate & Amber'
try {
    $savedTheme = Get-AppSetting -Name 'ThemeName'
    if ($savedTheme -and $Script:ThemePresets.Contains([string]$savedTheme)) {
        $Script:ThemeName = [string]$savedTheme
    }
} catch {}

$Script:Theme = $Script:ThemeBase.Clone()
foreach ($k in $Script:ThemePresets[$Script:ThemeName].Keys) {
    $Script:Theme[$k] = $Script:ThemePresets[$Script:ThemeName][$k]
}

# UI font (first choice; Segoe UI stays as the fallback in the font stack).
$Script:AppFont = 'Segoe UI'
try {
    $savedFont = Get-AppSetting -Name 'FontName'
    if ($savedFont) { $Script:AppFont = [string]$savedFont }
} catch {}

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

# Injected into every '<Style TargetType="ListBox">' by Invoke-ThemeXaml.
# The stock WPF ListBox template paints the control white when IsEnabled=False
# (SystemColors.ControlBrush), which flashed a white box while tools disable
# their user lists during Graph loads. This template keeps the themed
# background and just dims the list instead.
$Script:ThemeListBoxTemplate = @'
<Setter Property="ScrollViewer.CanContentScroll" Value="True"/>
<Setter Property="VirtualizingPanel.IsVirtualizing" Value="True"/>
<Setter Property="VirtualizingPanel.VirtualizationMode" Value="Recycling"/>
<Setter Property="VirtualizingPanel.ScrollUnit" Value="Pixel"/>
<Setter Property="ItemsPanel">
  <Setter.Value><ItemsPanelTemplate><VirtualizingStackPanel/></ItemsPanelTemplate></Setter.Value>
</Setter>
<Setter Property="Template">
  <Setter.Value>
    <ControlTemplate TargetType="ListBox">
      <Border Background="{TemplateBinding Background}"
              BorderBrush="{TemplateBinding BorderBrush}"
              BorderThickness="{TemplateBinding BorderThickness}"
              Padding="{TemplateBinding Padding}">
        <ScrollViewer Focusable="False" CanContentScroll="True">
          <ItemsPresenter/>
        </ScrollViewer>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Opacity" Value="0.55"/>
        </Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
  </Setter.Value>
</Setter>
'@

# ── Shared control styles ─────────────────────────────────────────────────────
# Styles that were byte-identical across most tool XAML documents now live here
# once. Invoke-ThemeXaml appends each entry to a document's resource dictionary
# only when that document does not already declare the same style, so a tool
# that deliberately differs (a non-sortable grid, a denser list) keeps its own
# copy and no duplicate resource key is ever created.
#
# Written with themed values already substituted, because injection happens
# after Invoke-ThemeXaml's hex translation pass.
#
# Keyed on the exact opening tag used to detect a local declaration.
$Script:ThemeSharedStyles = [ordered]@{
    '<SolidColorBrush x:Key="Bg"' = @"
<SolidColorBrush x:Key="Bg"      Color="$($Script:Theme.Bg)"/>
"@
    '<SolidColorBrush x:Key="Surface"' = @"
<SolidColorBrush x:Key="Surface" Color="$($Script:Theme.Surface)"/>
"@
    '<SolidColorBrush x:Key="Card"' = @"
<SolidColorBrush x:Key="Card"    Color="$($Script:Theme.Card)"/>
"@
    '<SolidColorBrush x:Key="Border"' = @"
<SolidColorBrush x:Key="Border"  Color="$($Script:Theme.Border)"/>
"@
    '<SolidColorBrush x:Key="Accent"' = @"
<SolidColorBrush x:Key="Accent"  Color="$($Script:Theme.Accent)"/>
"@
    '<SolidColorBrush x:Key="Danger"' = @"
<SolidColorBrush x:Key="Danger"  Color="$($Script:Theme.Danger)"/>
"@
    '<SolidColorBrush x:Key="Success"' = @"
<SolidColorBrush x:Key="Success" Color="$($Script:Theme.Success)"/>
"@
    '<SolidColorBrush x:Key="Text"' = @"
<SolidColorBrush x:Key="Text"    Color="$($Script:Theme.Text)"/>
"@
    '<SolidColorBrush x:Key="TextDim"' = @"
<SolidColorBrush x:Key="TextDim" Color="$($Script:Theme.TextDim)"/>
"@
    '<SolidColorBrush x:Key="Muted"' = @"
<SolidColorBrush x:Key="Muted"   Color="$($Script:Theme.Muted)"/>
"@
    '<Style TargetType="TabControl">' = @"
<Style TargetType="TabControl">
  <Setter Property="Background"      Value="$($Script:Theme.Bg)"/>
  <Setter Property="BorderThickness" Value="0"/>
</Style>
"@
    '<Style TargetType="TabItem">' = @"
<Style TargetType="TabItem">
  <Setter Property="Foreground"      Value="$($Script:Theme.TextDim)"/>
  <Setter Property="Background"      Value="Transparent"/>
  <Setter Property="BorderThickness" Value="0"/>
  <Setter Property="Padding"         Value="14,8"/>
  <Setter Property="FontWeight"      Value="SemiBold"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="TabItem">
        <Border Padding="{TemplateBinding Padding}" Cursor="Hand">
          <Border x:Name="ind" BorderThickness="0,0,0,2" BorderBrush="Transparent" Padding="0,0,0,3">
            <ContentPresenter ContentSource="Header"/>
          </Border>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsSelected" Value="True">
            <Setter Property="Foreground" Value="$($Script:Theme.Text)"/>
            <Setter TargetName="ind" Property="BorderBrush" Value="$($Script:Theme.Accent)"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
"@
    '<Style TargetType="TextBox">' = @"
<Style TargetType="TextBox">
  <Setter Property="Background"               Value="$($Script:Theme.Card)"/>
  <Setter Property="Foreground"               Value="$($Script:Theme.Text)"/>
  <Setter Property="BorderBrush"              Value="$($Script:Theme.Border)"/>
  <Setter Property="BorderThickness"          Value="1"/>
  <Setter Property="Padding"                  Value="8,4"/>
  <Setter Property="VerticalContentAlignment" Value="Center"/>
  <Setter Property="CaretBrush"               Value="$($Script:Theme.Text)"/>
  <Setter Property="FocusVisualStyle"         Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="TextBox">
        <Border x:Name="bd" Background="{TemplateBinding Background}"
                BorderBrush="{TemplateBinding BorderBrush}"
                BorderThickness="{TemplateBinding BorderThickness}"
                CornerRadius="4">
          <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                        Background="{TemplateBinding Background}"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsEnabled" Value="False">
            <Setter TargetName="bd" Property="Background" Value="$($Script:Theme.Surface)"/>
            <Setter Property="Foreground" Value="$($Script:Theme.Border)"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
"@
    '<Style TargetType="ListBox">' = @"
<Style TargetType="ListBox">
  <Setter Property="Background"      Value="$($Script:Theme.Bg)"/>
  <Setter Property="BorderThickness" Value="0"/>
  <Setter Property="Padding"         Value="0"/>
</Style>
"@
    '<Style TargetType="ListBoxItem">' = @"
<Style TargetType="ListBoxItem">
  <Setter Property="Foreground"                 Value="$($Script:Theme.Text)"/>
  <Setter Property="Background"                 Value="Transparent"/>
  <Setter Property="Padding"                    Value="12,7"/>
  <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
  <Setter Property="Cursor"                     Value="Hand"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ListBoxItem">
        <Border x:Name="bd" Background="{TemplateBinding Background}"
                Padding="{TemplateBinding Padding}">
          <ContentPresenter VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True">
            <Setter TargetName="bd" Property="Background" Value="$($Script:Theme.Hover)"/>
          </Trigger>
          <Trigger Property="IsSelected" Value="True">
            <Setter TargetName="bd" Property="Background" Value="$($Script:Theme.Selected)"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
"@
    '<Style TargetType="DataGrid">' = @"
<Style TargetType="DataGrid">
  <Setter Property="Background"               Value="$($Script:Theme.Bg)"/>
  <Setter Property="Foreground"               Value="$($Script:Theme.Text)"/>
  <Setter Property="BorderThickness"          Value="0"/>
  <Setter Property="GridLinesVisibility"      Value="Horizontal"/>
  <Setter Property="HorizontalGridLinesBrush" Value="$($Script:Theme.GridLine)"/>
  <Setter Property="RowBackground"            Value="$($Script:Theme.Bg)"/>
  <Setter Property="AlternatingRowBackground" Value="$($Script:Theme.AltRow)"/>
  <Setter Property="ColumnHeaderHeight"       Value="34"/>
  <Setter Property="RowHeight"                Value="28"/>
  <Setter Property="AutoGenerateColumns"      Value="False"/>
  <Setter Property="CanUserAddRows"           Value="False"/>
  <Setter Property="CanUserDeleteRows"        Value="False"/>
  <Setter Property="IsReadOnly"               Value="True"/>
  <Setter Property="SelectionMode"            Value="Single"/>
  <Setter Property="SelectionUnit"            Value="FullRow"/>
  <Setter Property="FontSize"                 Value="12"/>
</Style>
"@
    '<Style TargetType="DataGridColumnHeader">' = @"
<Style TargetType="DataGridColumnHeader">
  <Setter Property="Background"      Value="$($Script:Theme.Surface)"/>
  <Setter Property="Foreground"      Value="$($Script:Theme.TextDim)"/>
  <Setter Property="FontWeight"      Value="SemiBold"/>
  <Setter Property="Padding"         Value="12,0"/>
  <Setter Property="BorderBrush"     Value="$($Script:Theme.Border)"/>
  <Setter Property="BorderThickness" Value="0,0,0,1"/>
  <Setter Property="FontSize"        Value="11"/>
</Style>
"@
    '<Style x:Key="DgRow"' = @"
<Style x:Key="DgRow" TargetType="DataGridRow">
  <Setter Property="Background" Value="Transparent"/>
  <Style.Triggers>
    <Trigger Property="IsSelected"  Value="True">
      <Setter Property="Background" Value="$($Script:Theme.Selected)"/>
    </Trigger>
    <Trigger Property="IsMouseOver" Value="True">
      <Setter Property="Background" Value="$($Script:Theme.Hover)"/>
    </Trigger>
  </Style.Triggers>
</Style>
"@
    '<Style x:Key="DgCell"' = @"
<Style x:Key="DgCell" TargetType="DataGridCell">
  <Setter Property="Background"      Value="Transparent"/>
  <Setter Property="Foreground"      Value="$($Script:Theme.Text)"/>
  <Setter Property="BorderThickness" Value="0"/>
  <Setter Property="Padding"         Value="12,0"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="DataGridCell">
        <Border Padding="{TemplateBinding Padding}" Background="{TemplateBinding Background}">
          <ContentPresenter VerticalAlignment="Center"/>
        </Border>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
"@
}

function Get-ThemeHex([string]$Semantic) {
    if ($Script:Theme.ContainsKey($Semantic)) { return $Script:Theme[$Semantic] }
    return $Semantic
}

function Get-EtbAccentForeground {
    $rgb = for ($i = 1; $i -le 5; $i += 2) {
        $c = [Convert]::ToInt32($Script:Theme.Accent.Substring($i, 2), 16) / 255.0
        if ($c -le 0.04045) { $c / 12.92 } else { [math]::Pow(($c + 0.055) / 1.055, 2.4) }
    }
    $luminance = 0.2126 * $rgb[0] + 0.7152 * $rgb[1] + 0.0722 * $rgb[2]
    if ($luminance -gt 0.179) { return '#000000' }
    return '#FFFFFF'
}

# Re-skin a XAML here-string by swapping every legacy hex literal for its themed value.
function Invoke-ThemeXaml([string]$Xaml) {
    foreach ($old in $Script:ThemeMap.Keys) {
        $Xaml = $Xaml.Replace($old, $Script:ThemeMap[$old])
    }
    # Pick readable text on each preset's accent-filled action buttons.
    $accentForeground = Get-EtbAccentForeground
    $accentButton = '<Button\b[^>]*\bBackground="' + [regex]::Escape($Script:Theme.Accent) + '"[^>]*>'
    $Xaml = [regex]::Replace($Xaml, $accentButton, {
        param($match)
        $tag = $match.Value
        if ($tag -match '\bForeground="[^"]*"') {
            return [regex]::Replace($tag, '\bForeground="[^"]*"', "Foreground=`"$accentForeground`"")
        }
        return $tag.Replace('<Button ', "<Button Foreground=`"$accentForeground`" ")
    })
    if ($Script:AppFont -and $Script:AppFont -ne 'Segoe UI') {
        $font = [System.Security.SecurityElement]::Escape("$Script:AppFont, Segoe UI")
        $Xaml = $Xaml.Replace('FontFamily="Segoe UI"', "FontFamily=`"$font`"")
    }
    $Xaml = $Xaml.Replace('</Grid.Resources>',   "$Script:ThemeScrollBarStyle</Grid.Resources>")
    $Xaml = $Xaml.Replace('</Window.Resources>', "$Script:ThemeScrollBarStyle</Window.Resources>")
    # Add each shared style the document does not already declare for itself.
    # Must run before the ListBox template pass below so an injected ListBox
    # style still receives the virtualization/disabled-state template.
    $shared = -join @(foreach ($marker in $Script:ThemeSharedStyles.Keys) {
        if (-not $Xaml.Contains($marker)) { $Script:ThemeSharedStyles[$marker] }
    })
    # Only the outermost dictionary — the first one to close. A document can
    # hold nested Grid.Resources (the main window's help overlay does), and
    # adding the same keys to each of them is at best redundant.
    if ($shared) {
        $close = @('</Window.Resources>', '</Grid.Resources>') |
            ForEach-Object { [pscustomobject]@{ Tag = $_; At = $Xaml.IndexOf($_) } } |
            Where-Object { $_.At -ge 0 } | Sort-Object At | Select-Object -First 1
        if ($close) {
            $Xaml = $Xaml.Remove($close.At, $close.Tag.Length).Insert($close.At, "$shared$($close.Tag)")
        }
    }
    $Xaml = $Xaml.Replace('<Style TargetType="ListBox">', "<Style TargetType=`"ListBox`">$Script:ThemeListBoxTemplate")
    $Xaml
}


# ── Shared state ───────────────────────────────────────────────────────────────
$Script:AccessToken       = $null
$Script:CurrentTenantId   = $null
# UPN of the signed-in administrator; named as the operator on every audit row.
$Script:CurrentAccountUPN = $null

# Well-known Microsoft Intune PowerShell public client app ID - no app registration needed
$Script:GraphClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'

# Combined scopes for all tools
$Script:GraphScopes = @(
    'https://graph.microsoft.com/User.ReadWrite.All',
    'https://graph.microsoft.com/User-PasswordProfile.ReadWrite.All',
    'https://graph.microsoft.com/User.RevokeSessions.All',
    'https://graph.microsoft.com/DeviceManagementManagedDevices.Read.All',
    'https://graph.microsoft.com/DeviceManagementManagedDevices.PrivilegedOperations.All',
    'https://graph.microsoft.com/DeviceManagementConfiguration.Read.All',
    'https://graph.microsoft.com/AuditLog.Read.All',
    'https://graph.microsoft.com/GroupMember.ReadWrite.All',
    'https://graph.microsoft.com/Team.Create',
    'https://graph.microsoft.com/TeamMember.ReadWrite.All',
    'https://graph.microsoft.com/SecurityEvents.Read.All',
    'https://graph.microsoft.com/LicenseAssignment.ReadWrite.All'
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

# Per-tenant preferences stored alongside the profile, the same way the account
# hint is. Used for things that are only meaningful within one tenant, such as
# the year group last worked on.
function Get-TenantSetting {
    param([Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][string]$Name)
    $t = @(Get-SavedTenants) | Where-Object { $_.TenantId -eq $TenantId } | Select-Object -First 1
    if ($t -and $t.PSObject.Properties.Name -contains $Name) { return $t.$Name }
    return $null
}

function Set-TenantSetting {
    param([Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][string]$Name, $Value)
    $all = @(Get-SavedTenants)
    foreach ($t in $all) {
        if ($t.TenantId -eq $TenantId) {
            $t | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
        }
    }
    ConvertTo-Json @($all) -Depth 3 | Set-Content -Path (Get-TenantsConfigPath) -Encoding UTF8
}

function Disconnect-Tenant {
    param([Parameter(Mandatory)][string]$TenantId)
    $Script:AccessToken     = $null
    $Script:CurrentTenantId = $null
    $Script:TokenExpiresOn  = $null
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

    Invoke-ResetTools
    $Script:MainUI.TenantCombo.IsEnabled = $false
    $Script:MainUI.BtnAddTenant.IsEnabled = $false
    $Script:MainUI.BtnRemove.IsEnabled = $false
    $Script:DemoMode = $false
    Write-Log "Auth: starting token acquisition for '$TenantId'" 'DEBUG'
    Initialize-TokenCacheHelper
    # $TenantId may be a GUID, a verified domain, or an admin UPN. Non-GUID input
    # is resolved to the tenant GUID inside the worker (public discovery endpoint,
    # no auth needed); a UPN also becomes the login hint so the sign-in prompt is
    # pre-filled. The cache file path is computed in the worker after resolution
    # so domain/UPN input maps to the same cache as the GUID.
    $enteredUpn  = if ($TenantId -like '*@*') { $TenantId.Trim() } else { $null }
    $cacheDir    = Split-Path (Get-TenantCacheFile -TenantId $TenantId)
    $accountHint = if ($enteredUpn) { $enteredUpn } else { Get-TenantAccountHint -TenantId $TenantId }
    if ($accountHint) { Write-Log "Auth: using account hint $accountHint" 'DEBUG' }

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
        ExpiresOn    = $null
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
    $rs.SessionStateProxy.SetVariable('CacheDir',     $cacheDir)
    $rs.SessionStateProxy.SetVariable('AccountHint',  $accountHint)
    $rs.SessionStateProxy.SetVariable('ExistingApp',  $existingApp)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        $ErrorActionPreference = 'Stop'
        try {
            Import-Module MSAL.PS -RequiredVersion '4.37.0.0' -ErrorAction Stop

            # Resolve domain / UPN input to the tenant GUID via the public OpenID
            # discovery endpoint. GUID input passes straight through.
            $guidRx      = '[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
            $resolvedTid = $TenantId
            if ($TenantId -notmatch "^$guidRx$") {
                $domain = if ($TenantId -like '*@*') { ($TenantId -split '@')[-1] } else { $TenantId }
                try {
                    $oidc = Invoke-RestMethod `
                        -Uri "https://login.microsoftonline.com/$([uri]::EscapeDataString($domain))/v2.0/.well-known/openid-configuration" `
                        -Method GET -TimeoutSec 30 -MaximumRedirection 0 -ErrorAction Stop
                } catch {
                    throw "No tenant found for '$domain'. Check the domain / UPN and try again."
                }
                if ($oidc.issuer -notmatch "($guidRx)") {
                    throw "Could not resolve a tenant ID for '$domain'."
                }
                $resolvedTid = $Matches[1]
            }
            $AuthRef['TenantId'] = $resolvedTid
            $CacheFile = Join-Path $CacheDir ("token_cache_" + ($resolvedTid -replace '[^a-zA-Z0-9]', '') + '.bin')

            $app = if ($ExistingApp) { $ExistingApp } else {
                New-MsalClientApplication -ClientId $ClientId -TenantId $resolvedTid
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
                $AuthRef['ExpiresOn']  = $token.ExpiresOn.UtcDateTime
                $AuthRef['App']        = $app
                # The cache is written to disk automatically by the after-access callback above.
            } else {
                $AuthRef['Error'] = 'Token acquisition returned null.'
            }
        } catch {
            $ex = $_.Exception
            # Plain `throw "message"` (e.g. tenant resolution failures) surfaces as a
            # RuntimeException whose type name is noise — show just the message.
            $detail = if ($ex.GetType().Name -eq 'RuntimeException') { $ex.Message }
                      else { "$($ex.GetType().Name): $($ex.Message)" }
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
    $Script:AuthTimer.Tag = @{
        Ref = $Script:AuthRef; PS = $ps; RS = $rs; Async = $Script:AuthAsync
        Generation = $Script:SessionGeneration; Independent = $false; StopAsync = $null
    }
    $Script:AsyncJobs.Add($Script:AuthTimer)
    Start-EtbWorkerCleanup
    $Script:AuthTimer.Add_Tick({
        if ($this.Tag.Generation -ne $Script:SessionGeneration) { Stop-EtbAsyncWork $this; return }
        if (-not $this.Tag.Async.IsCompleted) { return }
        $Script:AuthTimer.Stop()
        Complete-EtbAsyncWork $this
        $Script:AuthPS = $null
        $Script:AuthRS = $null
        $Script:AuthAsync = $null
        try {
            Invoke-EtbScript {
                $Script:MainUI.BtnAddTenant.IsEnabled = $true
                $Script:MainUI.TenantCombo.IsEnabled = $Script:MainUI.TenantCombo.Items.Count -gt 0
                $Script:MainUI.BtnRemove.IsEnabled = $Script:MainUI.TenantCombo.Items.Count -gt 0
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
                $Script:TokenExpiresOn  = $Script:AuthRef['ExpiresOn']
                Start-TokenRefreshTimer
                if ($Script:AuthRef['App']) {
                    $Script:MsalApps[$Script:AuthRef['TenantId']] = $Script:AuthRef['App']
                }
                # OnSuccess may call Save-Tenant (new-tenant dialog), so run it first to
                # ensure the tenant row exists before we write the account hint into it.
                Invoke-EtbScript $Script:AuthSuccess
                if ($Script:AuthRef['AccountUPN']) {
                    $Script:CurrentAccountUPN = $Script:AuthRef['AccountUPN']
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

# ── Silent token refresh ───────────────────────────────────────────────────────
# Access tokens live ~60-75 minutes. Rather than letting long sessions die with
# "session expired" errors, a once-a-minute timer checks remaining lifetime and,
# inside the final 10 minutes, silently re-acquires the token from the cached
# MSAL app on a background runspace (refresh token → no browser popup).
$Script:TokenExpiresOn    = $null
$Script:TokenRefreshTimer = $null
$Script:TokenRefreshBusy  = $false

function Start-TokenRefreshTimer {
    if ($Script:TokenRefreshTimer) { return }
    $Script:TokenRefreshTimer = New-EtbDispatcherTimer -IntervalMs 60000
    $Script:TokenRefreshTimer.Add_Tick({
        try { Invoke-EtbScript { Invoke-TokenRefreshCheck } }
        catch { Write-Host "[ERROR] Token refresh tick: $_" -ForegroundColor Red }
    })
    $Script:TokenRefreshTimer.Start()
    Write-Log 'Auth: token refresh watchdog started' 'DEBUG'
}

function Invoke-TokenRefreshCheck {
    if ($Script:DemoMode -or $Script:TokenRefreshBusy) { return }
    if (-not $Script:AccessToken -or -not $Script:CurrentTenantId -or -not $Script:TokenExpiresOn) { return }
    $remaining = ($Script:TokenExpiresOn - [datetime]::UtcNow).TotalMinutes
    if ($remaining -gt 10) { return }
    $app = $Script:MsalApps[$Script:CurrentTenantId]
    if (-not $app) { return }

    $Script:TokenRefreshBusy = $true
    Write-Log "Auth: access token expires in $([int]$remaining) min — refreshing silently" 'DEBUG'
    $null = Start-AsyncWork -NoToken `
        -Vars @{
            App    = $app
            Scopes = $Script:GraphScopes
            Hint   = (Get-TenantAccountHint -TenantId $Script:CurrentTenantId)
        } `
        -RefSeed @{ Token = $null; ExpiresOn = $null } `
        -Script {
            Import-Module MSAL.PS -RequiredVersion '4.37.0.0' -ErrorAction Stop
            $p = @{
                PublicClientApplication = $App
                Scopes                  = $Scopes
                Silent                  = $true
                ForceRefresh            = $true
                ErrorAction             = 'Stop'
            }
            if ($Hint) { $p['LoginHint'] = $Hint }
            $t = Get-MsalToken @p
            $Ref['Token']     = $t.AccessToken
            $Ref['ExpiresOn'] = $t.ExpiresOn.UtcDateTime
        } `
        -OnComplete {
            param($ref)
            $Script:TokenRefreshBusy = $false
            if ($ref['Error']) {
                Write-Log "Auth: silent token refresh failed — $($ref['Error'])" 'WARN'
                return
            }
            if ($ref['Token']) {
                $Script:AccessToken    = $ref['Token']
                $Script:TokenExpiresOn = $ref['ExpiresOn']
                Publish-EtbWorkerToken
                Write-Log 'Auth: access token refreshed silently' 'INFO'
            }
        }
}

# ── Graph REST helpers ─────────────────────────────────────────────────────────
# All three helpers route through Invoke-EtbGraphRequest, which retries 429
# throttling (honouring Retry-After) and transient 502/503/504 with backoff —
# the same policy the worker preamble applies inside background runspaces.
function Invoke-EtbGraphRequest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        [hashtable]$Body = $null
    )
    $params = @{
        Uri         = $Uri
        Method      = $Method
        Headers     = @{ Authorization = "Bearer $Script:AccessToken" }
        ErrorAction = 'Stop'
    }
    if ($Body) {
        $params.Headers['Content-Type'] = 'application/json'
        $params.Body = $Body | ConvertTo-Json -Depth 10
    }
    Invoke-RestMethod @params
}

function Invoke-GraphGet {
    param([string]$Path)
    Invoke-EtbGraphRequest -Uri "https://graph.microsoft.com$Path"
}

function Invoke-GraphPatch {
    param([string]$Path, [hashtable]$Body)
    Invoke-EtbGraphRequest -Uri "https://graph.microsoft.com$Path" -Method PATCH -Body $Body
}

function Get-GraphPaged {
    param([string]$Path)
    $items = [System.Collections.Generic.List[object]]::new()
    $url = "https://graph.microsoft.com$Path"
    do {
        $resp = Invoke-EtbGraphRequest -Uri $url
        foreach ($i in $resp.value) { $items.Add($i) }
        $url = $resp.'@odata.nextLink'
    } while ($url)
    $items.ToArray()
}

# ── Shared directory user cache ────────────────────────────────────────────────
# Every tool used to download the full user list independently (~10 identical
# paged Graph fetches per connect). Tools now call Request-EtbUsers with the
# name of a completion function; the first request triggers ONE paged fetch with
# a superset $select, and every later request is served from the cache
# instantly. Completion functions read $Script:UserCache.Users / .Error and
# apply their own client-side filters. The cache is cleared on tenant switch or
# disconnect via Clear-EtbUserCache (called from Invoke-ResetTools).
$Script:UserCache = @{
    Users   = $null   # array of user objects once loaded
    Error   = $null   # last load error ('401' = expired session)
    Loading = $false
    Waiters = [System.Collections.Generic.List[string]]::new()
    Timer   = $null
}

function Clear-EtbUserCache {
    if ($Script:UserCache.Timer) { $Script:UserCache.Timer.Stop(); $Script:UserCache.Timer = $null }
    $Script:UserCache.Users   = $null
    $Script:UserCache.Error   = $null
    $Script:UserCache.Loading = $false
    $Script:UserCache.Waiters.Clear()
}

function Request-EtbUsers {
    param([Parameter(Mandatory)][string]$OnReady)
    if ($null -ne $Script:UserCache.Users) {
        try { Invoke-EtbCommand $OnReady }
        catch { Write-Log "UserCache callback '$OnReady' error: $_" 'ERROR' }
        return
    }
    $Script:UserCache.Waiters.Add($OnReady)
    if ($Script:UserCache.Loading) { return }
    $Script:UserCache.Error   = $null
    $Script:UserCache.Loading = $true
    Write-Log 'UserCache: fetching directory users (shared load)' 'DEBUG'
    $Script:UserCache.Timer = Start-AsyncWork -RefSeed @{ Users = $null } -Script {
        $users = [System.Collections.Generic.List[object]]::new()
        $url   = 'https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName,accountEnabled,userType,department,officeLocation,onPremisesSyncEnabled,onPremisesImmutableId&$top=999'
        do {
            $resp = Invoke-RestMethod -Uri $url `
                -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
            foreach ($u in $resp.value) { $users.Add($u) }
            $url = $resp.'@odata.nextLink'
        } while ($url)
        $Ref['Users'] = $users.ToArray()
    } -OnComplete {
        param($ref)
        $Script:UserCache.Loading = $false
        if ($ref['Error']) {
            $Script:UserCache.Error = $ref['Error']
            Write-Log "UserCache: load failed — $($ref['Error'])" 'ERROR'
        } else {
            $Script:UserCache.Users = $ref['Users']
            Write-Log "UserCache: loaded $($ref['Users'].Count) users (shared across tools)" 'INFO'
        }
        $waiters = @($Script:UserCache.Waiters)
        $Script:UserCache.Waiters.Clear()
        foreach ($w in $waiters) {
            try { Invoke-EtbCommand $w }
            catch { Write-Log "UserCache callback '$w' error: $_" 'ERROR' }
        }
    }
}

# ── Debounced invocation ───────────────────────────────────────────────────────
# Search boxes rebuild their entire ListBox on every keystroke. Routing the
# TextChanged handler through this waits for a pause in typing instead.
# One timer per key; Command is a dot-sourced function name.
$Script:DebounceTimers = @{}
function Invoke-EtbDebounced {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Command,
        [int]$Ms = 200
    )
    $t = $Script:DebounceTimers[$Key]
    if (-not $t) {
        $t = New-EtbDispatcherTimer -IntervalMs $Ms
        $t.Add_Tick({
            $this.Stop()
            try { Invoke-EtbCommand $this.Tag }
            catch { Write-Log "Debounced '$($this.Tag)' error: $_" 'ERROR' }
        })
        $Script:DebounceTimers[$Key] = $t
    }
    $t.Tag = $Command
    $t.Stop()
    $t.Start()
}
