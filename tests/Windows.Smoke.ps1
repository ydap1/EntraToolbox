#Requires -Version 7.0
# Run with pwsh -NoProfile -STA -File tests/Windows.Smoke.ps1 on Windows.
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This smoke test needs Windows WPF.' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Launch pwsh with -STA.' }
$root = Split-Path $PSScriptRoot
$Global:AppRoot = Join-Path ([IO.Path]::GetTempPath()) ('etb-wpf-' + [guid]::NewGuid())
New-Item $Global:AppRoot -ItemType Directory | Out-Null
$window = $null
try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    . "$root/src/Auth.ps1"
    . "$root/src/Demo.ps1"
    foreach ($file in Get-ChildItem "$root/src/Tools" -Filter *.ps1) { . $file.FullName }
    . "$root/src/MainWindow.ps1"
    $Script:EtbSessionState = $ExecutionContext.SessionState
    $Script:SmokeErrors = [Collections.Generic.List[string]]::new()
    function Write-Log {
        param($Message, $Level)
        if ($Level -eq 'ERROR') { $Script:SmokeErrors.Add($Message) }
    }
    # Construct every XAML document under every theme, including templates.
    $documents = [Collections.Generic.List[string]]::new()
    foreach ($file in Get-ChildItem "$root/src" -Recurse -Filter *.ps1) {
        $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
        foreach ($node in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.StringConstantExpressionAst] -and $a.Value -match '^<(Grid|Window)\s+xmlns=' }, $true)) {
            $documents.Add($node.Value)
        }
    }
    $authAst = [Management.Automation.Language.Parser]::ParseFile("$root/src/Auth.ps1", [ref]$null, [ref]$null)
    $mapAssignment = $authAst.Find({ param($a) $a -is [Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$Script:ThemeMap' }, $true)
    foreach ($preset in $Script:ThemePresets.Keys) {
        $Script:Theme = $Script:ThemeBase.Clone()
        foreach ($key in $Script:ThemePresets[$preset].Keys) { $Script:Theme[$key] = $Script:ThemePresets[$preset][$key] }
        . ([scriptblock]::Create($mapAssignment.Extent.Text))
        foreach ($xaml in $documents) {
            $reader = [Xml.XmlNodeReader]::new([xml](Invoke-ThemeXaml $xaml))
            try { $null = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
        }
    }
    $window = Show-MainWindow -AppVersion 'smoke' -InitializeOnly
    $Script:DemoMode = $true
    $Script:AccessToken = 'DEMO'
    foreach ($name in @($Script:NavInitializers.Keys)) {
        Set-NavSelection $name
        foreach ($load in $Script:NavConnectFns[$name]) { Invoke-EtbCommand $load }
        if (-not $Script:NavContents.ContainsKey($name)) { throw "Panel failed: $name" }
        foreach ($width in 900, 1280, 1600) {
            $window.Measure([Windows.Size]::new($width, 800))
            $window.Arrange([Windows.Rect]::new(0, 0, $width, 800))
            $window.UpdateLayout()
        }
    }
    if ($Script:SmokeErrors.Count) { throw ($Script:SmokeErrors -join "`n") }
    if ($Script:AsyncJobs.Count) { throw 'Demo navigation unexpectedly started network workers.' }
    Write-Host "PASS: $($documents.Count) XAML documents, $($Script:ThemePresets.Count) themes, $($Script:NavContents.Count) demo panels at three widths."
} finally {
    if ($window) { $window.Close() }
    Remove-Item $Global:AppRoot -Recurse -Force -ErrorAction SilentlyContinue
}
