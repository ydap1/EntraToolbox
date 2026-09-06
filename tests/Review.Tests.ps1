#Requires -Version 7.0
# Offline regression checks: real runspaces and a loopback HTTP server, no tenant.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$Global:AppRoot = Join-Path ([IO.Path]::GetTempPath()) ('etb-tests-' + [guid]::NewGuid())
New-Item $Global:AppRoot -ItemType Directory | Out-Null
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "PASS $Message"
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    $message = ''
    try { & $Action } catch { $message = $_.Exception.Message }
    Assert ($message -like "*$Pattern*") "rejects $Pattern"
}
try {
    $parseErrors = @()
    foreach ($file in @(Get-ChildItem $root/src -Recurse -Filter *.ps1) + @(Get-Item $root/Start.ps1)) {
        $e = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$e)
        $parseErrors += $e
    }
    Assert ($parseErrors.Count -eq 0) "all application scripts parse ($($parseErrors -join '; '))"
    . "$root/src/Auth.ps1"

    . "$root/src/Tools/PasswordReset.ps1"
    $passwords = @(1..1000 | ForEach-Object { New-Password })
    Assert (@($passwords | Where-Object { $_ -notmatch '^[a-z]{3}\.[a-z]{3}\.[a-z]{3}[1-9][0-9]!$' }).Count -eq 0) 'classroom password format is preserved'
    $csv = [pscustomobject]@{ Name = '=HYPERLINK("bad")'; Upn = 'student@school.test'; Password = 'cat.sun.cup42!'; Count = -2 } | ConvertTo-EtbCsvRow
    Assert ($csv.Name.StartsWith("'=") -and $csv.Upn -eq 'student@school.test' -and $csv.Password -eq 'cat.sun.cup42!' -and $csv.Count -eq -2) 'CSV formula protection preserves ordinary values and passwords'
    foreach ($file in Get-ChildItem "$root/src/Tools" -Filter *.ps1) { . $file.FullName }
    . "$root/src/Demo.ps1"
    $missing = @()
    $xamlCount = 0
    foreach ($file in Get-ChildItem "$root/src" -Recurse -Filter *.ps1) {
        $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
        foreach ($command in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.CommandAst] }, $true)) {
            $name = $command.GetCommandName()
            if ($name -eq 'if') { throw "Invalid conditional argument: $($command.Extent)" }
            if ($name -like 'Start-*Demo' -and -not (Get-Command $name -ErrorAction SilentlyContinue)) { $missing += $name }
        }
        foreach ($node in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.StringConstantExpressionAst] -and $a.Value -match '^<(Grid|Window)\s+xmlns=' }, $true)) {
            $null = [xml](Invoke-ThemeXaml $node.Value)
            $xamlCount++
        }
    }
    Assert ($missing.Count -eq 0) "all referenced demo loaders exist ($($missing -join ', '))"
    Assert ($xamlCount -gt 10) "all $xamlCount application XAML documents are well-formed after theme substitution"
    # Dry run must not launch a worker, claim success, or change prompt status.
    $Script:DryMode = $true
    $Script:DemoMode = $false
    $Script:UPR_UI = @{ InlineStatus = [pscustomobject]@{ Text=''; Foreground=''; Visibility='' }; PromptStatus = [pscustomobject]@{ Text='unchanged' } }
    function Set-MainStatus { param($Text, $Color) }
    function Write-UprLog { param($Msg, $Color) }
    Start-UprPasswordReset -User ([pscustomobject]@{ id='test'; displayName='Test User' }) -Password 'cat.sun.cup42!' -Force $true
    Assert ($Script:UPR_UI.InlineStatus.Text -like '*No changes made*' -and $Script:UPR_UI.PromptStatus.Text -eq 'unchanged' -and $Script:AsyncJobs.Count -eq 0) 'dry-run password reset leaves actual account state untouched'
    $Script:DryMode = $false

    $Script:AppFont = 'Font & "quoted"'
    $fontXaml = Invoke-ThemeXaml '<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><TextBlock FontFamily="Segoe UI"/></Grid>'
    $null = [xml]$fontXaml
    Assert ($fontXaml -like '*&amp;*' -and $fontXaml -like '*&quot;*') 'saved font names are safely escaped in XAML'
    $Script:AppFont = 'Segoe UI'
    $Script:Theme.Accent = '#F59E0B'
    $accentXaml = Invoke-ThemeXaml '<Button Background="#6366F1" Foreground="White"/>'
    Assert ($accentXaml -like '*Foreground="#000000"*') 'amber action buttons use contrasting dark text'

    # Substitute only the dispatcher for Linux. Pipelines/runspaces are real.
    function New-EtbDispatcherTimer {
        param([int]$IntervalMs)
        $t = [pscustomobject]@{ Tag=$null; IsEnabled=$false; Handler=$null }
        $t | Add-Member ScriptMethod Add_Tick { param($handler) $this.Handler = $handler }
        $t | Add-Member ScriptMethod Start { $this.IsEnabled = $true }
        $t | Add-Member ScriptMethod Stop { $this.IsEnabled = $false }
        $t | Add-Member ScriptMethod Fire { & $this.Handler }
        $t
    }
    function Wait-JobCleanup($Timer) {
        $deadline = [datetime]::UtcNow.AddSeconds(10)
        while ($Timer.Tag -and [datetime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 20
            if ($Timer.IsEnabled) { $Timer.Fire() }
            $Script:WorkerCleanupTimer.Fire()
        }
        Assert ($null -eq $Timer.Tag) 'worker releases its pipeline, runspace and timer state'
    }
    $Script:Completed = 0
    $job = Start-AsyncWork -Script { $Ref['Value'] = 42 } -OnComplete { param($ref) $Script:Completed = $ref.Value }
    Wait-JobCleanup $job
    Assert ($Script:Completed -eq 42) 'completed worker delivers its result'
    $job = Start-AsyncWork -Script { Start-Sleep -Seconds 30 } -OnComplete { $Script:Completed = -1 }
    $job.Stop()
    Wait-JobCleanup $job
    Assert ($Script:Completed -eq 42) 'superseded worker is canceled without a stale callback'
    $job = Start-AsyncWork -NoToken -Script { $Ref['Token'] = 'OLD TENANT' } -OnComplete { $Script:AccessToken = $args[0].Token }
    Reset-EtbSessionWork
    $Script:AccessToken = 'NEW TENANT'
    Wait-JobCleanup $job
    Assert ($Script:AccessToken -eq 'NEW TENANT') 'late refresh cannot overwrite a different tenant token'
    Assert ($Script:AsyncJobs.Count -eq 0) 'worker registry returns to zero'

    $headers = @{ Authorization = 'Bearer test' }
    foreach ($uri in 'http://graph.microsoft.com/v1.0/users', 'https://example.com/users', 'https://graph.microsoft.com.evil.test/users', 'https://graph.microsoft.com:444/users') {
        Assert-Throws { Invoke-RestMethod -Uri $uri -Headers $headers } 'Refusing to send credentials'
    }
    $Script:DryMode = $true
    Assert-Throws { Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/users' -Method POST -Headers $headers } 'Dry run is active'
    $Script:DryMode = $false
    $Ref = @{ Cancelled = $true }
    Assert-Throws { Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/users' -Headers $headers } 'canceled'
    $Ref = $null
    $response = [Net.Http.HttpResponseMessage]::new()
    $response.Headers.RetryAfter = [Net.Http.Headers.RetryConditionHeaderValue]::new([TimeSpan]::FromSeconds(120))
    Assert ((Get-EtbRetryDelay $response 0) -eq 120) 'Retry-After longer than 60 seconds is respected'
    $response.Headers.RetryAfter = [Net.Http.Headers.RetryConditionHeaderValue]::new([DateTimeOffset]::UtcNow.AddSeconds(100))
    Assert ((Get-EtbRetryDelay $response 0) -ge 99) 'HTTP-date Retry-After is respected'
    $response.Dispose()

    # Exercise the actual HTTP cmdlet: retries, response headers, ambiguous writes.
    $portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $portProbe.Start(); $port = $portProbe.LocalEndpoint.Port; $portProbe.Stop()
    $listener = [Net.HttpListener]::new()
    $listener.Prefixes.Add("http://localhost:$port/")
    $listener.Start()
    $counts = [hashtable]::Synchronized(@{})
    $server = [powershell]::Create()
    $null = $server.AddScript({
        param($listener, $counts)
        try {
            while ($listener.IsListening) {
                $ctx = $listener.GetContext()
                $path = $ctx.Request.Url.AbsolutePath
                $counts[$path] = 1 + $counts[$path]
                $ctx.Response.ContentType = 'application/json'
                $ctx.Response.Headers.Add('Location', '/created')
                $status = if ($path -eq '/write') { 503 } elseif ($path -eq '/retry' -and $counts[$path] -eq 1) { 429 } else { 200 }
                $ctx.Response.StatusCode = $status
                $ctx.Response.Headers.Add('Retry-After', '1')
                $bytes = [Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $ctx.Response.Close()
            }
        } catch { }
    }).AddArgument($listener).AddArgument($counts)
    $serverAsync = $server.BeginInvoke()
    try {
        $result = Invoke-RestMethod -Uri "http://localhost:$port/retry" -ResponseHeadersVariable returnedHeaders
        Assert ($result.ok -and $counts['/retry'] -eq 2) '429 request retries and returns the response'
        Assert ($returnedHeaders.Location -contains '/created') 'response headers reach the caller (Teams provisioning)'
        Assert-Throws { Invoke-RestMethod -Uri "http://localhost:$port/write" -Method POST } '503'
        Assert ($counts['/write'] -eq 1) 'ambiguous writes are never replayed'
    } finally {
        $listener.Stop(); $listener.Close()
        $server.EndInvoke($serverAsync) | Out-Null
        $server.Dispose()
    }
} finally {
    Remove-Item $Global:AppRoot -Recurse -Force -ErrorAction SilentlyContinue
}
