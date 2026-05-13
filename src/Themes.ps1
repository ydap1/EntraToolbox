<#
    Theme palettes and live theme-switching for Art's Entra Toolbox.
    Dot-sourced by Start.ps1 immediately after Auth.ps1.
    Exposes: Invoke-ThemeXaml, Apply-Theme, Load-AppSettings, Save-AppSettings
#>

$Script:ThemePalettes = [ordered]@{
    'Default Dark' = @{
        Bg='#12121C'; Surface='#1C1C2A'; Card='#242436'; Border='#3C3C5A'
        Accent='#6366F1'; Text='#E2E2F0'; TextDim='#7878A0'; Muted='#50507A'
        Success='#22C55E'; Danger='#EF4444'; Warning='#FBBF24'; Hover='#1E1E38'
        Selected='#2A2A50'; GridLine='#1E1E32'; AltRow='#181826'; SubHeader='#1A1A2C'
    }
    'Gruvbox' = @{
        Bg='#282828'; Surface='#32302F'; Card='#3C3836'; Border='#504945'
        Accent='#458588'; Text='#EBDBB2'; TextDim='#A89984'; Muted='#7C6F64'
        Success='#98971A'; Danger='#CC241D'; Warning='#D65D0E'; Hover='#3C3836'
        Selected='#504945'; GridLine='#32302F'; AltRow='#282828'; SubHeader='#3C3836'
    }
    'Catppuccin Mocha' = @{
        Bg='#1E1E2E'; Surface='#181825'; Card='#313244'; Border='#45475A'
        Accent='#CBA6F7'; Text='#CDD6F4'; TextDim='#BAC2DE'; Muted='#6C7086'
        Success='#A6E3A1'; Danger='#F38BA8'; Warning='#FAB387'; Hover='#313244'
        Selected='#45475A'; GridLine='#181825'; AltRow='#1E1E2E'; SubHeader='#24273A'
    }
    'Nord' = @{
        Bg='#2E3440'; Surface='#3B4252'; Card='#434C5E'; Border='#4C566A'
        Accent='#88C0D0'; Text='#ECEFF4'; TextDim='#D8DEE9'; Muted='#616E88'
        Success='#A3BE8C'; Danger='#BF616A'; Warning='#EBCB8B'; Hover='#3B4252'
        Selected='#434C5E'; GridLine='#3B4252'; AltRow='#2E3440'; SubHeader='#3B4252'
    }
    'One Dark' = @{
        Bg='#282C34'; Surface='#21252B'; Card='#2C313C'; Border='#3E4451'
        Accent='#61AFEF'; Text='#ABB2BF'; TextDim='#828997'; Muted='#5C6370'
        Success='#98C379'; Danger='#E06C75'; Warning='#E5C07B'; Hover='#2C313C'
        Selected='#3E4451'; GridLine='#21252B'; AltRow='#282C34'; SubHeader='#2C313C'
    }
}

$Script:Theme            = $Script:ThemePalettes['Default Dark']
$Script:CurrentThemeName = 'Default Dark'

# Replace the 16 Default-Dark semantic hex values with the active theme's values.
# Input XAML must always use Default-Dark hex literals — no other values are substituted.
function Invoke-ThemeXaml([string]$Xaml) {
    $t = $Script:Theme
    $Xaml -replace '#12121C',$t.Bg      -replace '#1C1C2A',$t.Surface `
          -replace '#242436',$t.Card     -replace '#3C3C5A',$t.Border `
          -replace '#6366F1',$t.Accent   -replace '#E2E2F0',$t.Text `
          -replace '#7878A0',$t.TextDim  -replace '#50507A',$t.Muted `
          -replace '#22C55E',$t.Success  -replace '#EF4444',$t.Danger `
          -replace '#FBBF24',$t.Warning  -replace '#1E1E38',$t.Hover `
          -replace '#2A2A50',$t.Selected -replace '#1E1E32',$t.GridLine `
          -replace '#181826',$t.AltRow   -replace '#1A1A2C',$t.SubHeader
}

function Get-AppSettingsPath { Join-Path $Global:AppRoot 'config\settings.json' }

function Load-AppSettings {
    $p = Get-AppSettingsPath
    if (-not (Test-Path $p)) { return [PSCustomObject]@{ Theme = 'Default Dark' } }
    try {
        $raw = Get-Content -Path $p -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return [PSCustomObject]@{ Theme = 'Default Dark' } }
        $s = $raw | ConvertFrom-Json
        if (-not $s.Theme -or -not $Script:ThemePalettes.ContainsKey($s.Theme)) { $s.Theme = 'Default Dark' }
        return $s
    } catch { return [PSCustomObject]@{ Theme = 'Default Dark' } }
}

function Save-AppSettings {
    param([string]$Theme = 'Default Dark')
    $dir = Join-Path $Global:AppRoot 'config'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    [PSCustomObject]@{ Theme = $Theme } | ConvertTo-Json | Set-Content -Path (Get-AppSettingsPath) -Encoding UTF8
}

function New-ThemeBrush([string]$Hex) {
    $b = [System.Windows.Media.SolidColorBrush]::new(
        [System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
    $b.Freeze(); $b
}

function Apply-Theme {
    param([string]$ThemeName = 'Default Dark')
    if (-not $Script:ThemePalettes.ContainsKey($ThemeName)) { $ThemeName = 'Default Dark' }
    $Script:Theme            = $Script:ThemePalettes[$ThemeName]
    $Script:CurrentThemeName = $ThemeName
    Write-Log "Theme applied: $ThemeName" 'INFO'

    if (-not $Script:MainUI) { return }

    # Clear callbacks — re-registered by each Initialize-*Tool call below
    $Script:ConnectCallbacks.Clear()
    $Script:ResetCallbacks.Clear()

    # Re-parse each tab with the new theme colors
    $Script:MainUI.TabPwReset.Content       = Initialize-PasswordResetTool
    $Script:MainUI.TabPwUser.Content        = Initialize-UserPasswordResetTool
    $Script:MainUI.TabLastDevice.Content    = Initialize-LastDeviceTool
    $Script:MainUI.TabSignIn.Content        = Initialize-SignInLogsTool
    $Script:MainUI.TabDevCompliance.Content = Initialize-DeviceComplianceTool

    # Update main window chrome
    $t = $Script:Theme
    $Script:MainUI.Window.Background           = New-ThemeBrush $t.Bg
    $Script:MainUI.HeaderBorder.Background     = New-ThemeBrush $t.Surface
    $Script:MainUI.TenantBarBorder.Background  = New-ThemeBrush $t.Surface
    $Script:MainUI.TenantBarBorder.BorderBrush = New-ThemeBrush $t.Border
    $Script:MainUI.StatusBarBorder.Background  = New-ThemeBrush $t.Surface
    $Script:MainUI.StatusBarBorder.BorderBrush = New-ThemeBrush $t.Border
    $Script:MainUI.Status.Foreground           = New-ThemeBrush $t.Muted
    $Script:MainUI.Version.Foreground          = New-ThemeBrush $t.Border
}
