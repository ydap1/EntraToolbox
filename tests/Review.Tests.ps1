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

    . "$root/src/Import.ps1"
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
            $themed = Invoke-ThemeXaml $node.Value
            $null = [xml]$themed
            # Shared styles are appended only when absent; a duplicate key here
            # would still be valid XML but would fail at XamlReader.Load.
            $dupes = @([regex]::Matches($themed, 'x:Key="([^"]+)"') |
                ForEach-Object { $_.Groups[1].Value } |
                Group-Object | Where-Object Count -gt 1)
            if ($dupes) { throw "$($file.Name): duplicate resource key $($dupes[0].Name)" }
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
    Start-UprPasswordReset -User ([pscustomobject]@{ id='test'; displayName='Test User' }) -Password (ConvertTo-SecureString 'cat.sun.cup42!' -AsPlainText -Force) -Force $true
    Assert ($Script:UPR_UI.InlineStatus.Text -like '*No changes made*' -and $Script:UPR_UI.PromptStatus.Text -eq 'unchanged' -and $Script:AsyncJobs.Count -eq 0) 'dry-run password reset leaves actual account state untouched'
    $Script:DryMode = $false
    & {
        function Start-AsyncWork {
            param($Script, $OnComplete, $Vars, $RefSeed)
            $Script:CapturedCompletion = $OnComplete
            $Script:CapturedRef = $RefSeed
        }
        $Script:UPR_ProfTimer = $null
        $Script:UPR_UI = @{
            PromptStatus = [pscustomobject]@{ Text=''; Foreground='' }
            BtnReset = [pscustomobject]@{ IsEnabled=$true }
            UserList = [pscustomobject]@{ SelectedItem = [pscustomobject]@{ Tag = [pscustomobject]@{ id='old-user' } } }
        }
        Start-UprProfileLoad -UserId 'old-user'
        $Script:UPR_UI.UserList.SelectedItem.Tag.id = 'new-user'
        $Script:UPR_UI.PromptStatus.Text = 'New user status'
        & $Script:CapturedCompletion $Script:CapturedRef
        Assert ($Script:UPR_UI.PromptStatus.Text -eq 'New user status') 'late profile reads cannot overwrite a different selected user'
    }


    # ── Shared style injection ────────────────────────────────────────────────
    $bare = Invoke-ThemeXaml '<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"><Grid.Resources></Grid.Resources></Grid>'
    Assert ($bare -like '*TargetType="DataGrid"*' -and $bare -like '*x:Key="DgRow"*') 'a document without its own grid styles is given the shared ones'
    $owned = Invoke-ThemeXaml '<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"><Grid.Resources><Style TargetType="DataGrid"><Setter Property="RowHeight" Value="99"/></Style></Grid.Resources></Grid>'
    Assert (([regex]::Matches($owned, '<Style TargetType="DataGrid">')).Count -eq 1) 'a tool that declares its own style is not given a competing copy'
    Assert ($owned -like '*Value="99"*') 'the tool keeps its own values'

    # ── User list import ──────────────────────────────────────────────────────
    $parsed = @(Get-EtbUpnsFromText "a@school.test`r`nB@SCHOOL.TEST`na@school.test`nnot-a-upn`n`n")
    Assert ($parsed.Count -eq 2) 'pasted usernames are de-duplicated case-insensitively and junk is dropped'
    $row = @(Get-EtbUpnsFromText '"Smith, John",jsmith@school.test,Year 7')
    Assert ($row.Count -eq 1 -and $row[0] -eq 'jsmith@school.test') 'a whole spreadsheet row yields just its username'
    $csvPath = Join-Path $Global:AppRoot 'import.csv'
    'Name,Email' | Set-Content $csvPath
    'Ann,ann@school.test' | Add-Content $csvPath
    Assert ((@(Get-EtbUpnsFromCsv -Path $csvPath))[0] -eq 'ann@school.test') 'CSV import finds the username column whatever it is called'
    $lookup = Select-EtbUsersByUpn -Users @([pscustomobject]@{ userPrincipalName = 'ann@school.test'; id = '1' }) -Upns @('ANN@school.test', 'gone@school.test')
    Assert ($lookup.Matched.Count -eq 1 -and $lookup.Missing -eq 'gone@school.test') 'unmatched names are reported rather than silently dropped'

    # ── Change record ─────────────────────────────────────────────────────────
    $Script:CurrentTenantId   = 'tenant-under-test'
    $Script:CurrentAccountUPN = 'admin@school.test'
    $Script:DemoMode = $false
    Write-EtbAudit -Tool 'Year Group Passwords' -Action 'Reset password' -Target 'pupil@school.test'
    $auditPath = Get-EtbAuditPath
    $logged = @(Import-Csv $auditPath)
    Assert ($logged.Count -eq 1 -and $logged[0].Target -eq 'pupil@school.test' -and $logged[0].Operator -eq 'admin@school.test') 'a live change is recorded with its operator and target'
    Assert (($logged[0].PSObject.Properties.Name -notcontains 'Password')) 'the change record has no password column'
    $Script:DemoMode = $true
    Write-EtbAudit -Tool 'Year Group Passwords' -Action 'Reset password' -Target 'demo@school.test'
    $Script:DemoMode = $false
    Assert ((@(Import-Csv $auditPath)).Count -eq 1) 'demo mode records nothing'
    $Script:CurrentTenantId = $null

    # ── Mid-batch token refresh ───────────────────────────────────────────────
    $Ref = @{ Token = 'REFRESHED' }
    Assert-Throws { Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/users' -Headers @{ Authorization = 'Bearer DEMO' } } 'Demo mode'
    $Ref = $null
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

    # A stopped batch must still reach OnComplete, or the tool is left disabled
    # with no idea how far it got.
    $Script:CancelDone = $null
    $job = Start-AsyncWork -RefSeed @{ Processed = 0 } -Script {
        for ($i = 0; $i -lt 200; $i++) {
            if ($Ref['CancelRequested']) { break }
            $Ref['Processed']++
            Start-Sleep -Milliseconds 10
        }
    } -OnComplete { param($ref) $Script:CancelDone = $ref['Processed'] }
    Start-Sleep -Milliseconds 150
    Request-EtbAsyncCancel $job
    Wait-JobCleanup $job
    Assert ($null -ne $Script:CancelDone -and $Script:CancelDone -lt 200) 'a cancelled batch stops early and still reports its progress'

    # Long batches outlive the token they captured at launch.
    $Script:AccessToken = 'ORIGINAL'
    $job = Start-AsyncWork -Script { Start-Sleep -Milliseconds 400 } -OnComplete { }
    Assert ($job.Tag.Ref['Token'] -eq 'ORIGINAL') 'a worker starts with the current token'
    $Script:AccessToken = 'REFRESHED'
    Publish-EtbWorkerToken
    Assert ($job.Tag.Ref['Token'] -eq 'REFRESHED') 'a silent refresh reaches workers already running'
    Wait-JobCleanup $job
    $Script:AccessToken = $null
    $job = Start-AsyncWork -Script { Get-Item '/etb-missing-path-974397' } -OnComplete { param($ref) $Script:WorkerError = $ref.Error }
    Wait-JobCleanup $job
    Assert ([bool]$Script:WorkerError) 'worker cmdlet failures cannot be reported as success'
    $Script:DryMode = $true
    $job = Start-AsyncWork -Script { Invoke-RestMethod -Uri 'http://localhost:1/' -Method POST } -OnComplete { param($ref) $Script:ReadOnlyError = $ref.Error }
    $Script:DryMode = $false
    Wait-JobCleanup $job
    Assert ($Script:ReadOnlyError -like '*Dry run is active*') 'background workers retain the dry-run policy captured at launch'
    Assert ($Script:GraphScopes -contains 'https://graph.microsoft.com/DeviceManagementManagedDevices.PrivilegedOperations.All' -and $Script:GraphScopes -contains 'https://graph.microsoft.com/User-PasswordProfile.ReadWrite.All') 'device sync and password resets request documented scopes'

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
                $payload = if ($path -eq '/pages') {
                    '{"value":[{"id":1}],"@odata.nextLink":"' + $ctx.Request.Url.GetLeftPart([UriPartial]::Authority) + '/page2"}'
                } elseif ($path -eq '/page2') { '{"value":[{"id":2}]}' }
                elseif ($path -eq '/cycle') { '{"value":[],"@odata.nextLink":"' + $ctx.Request.Url.AbsoluteUri + '"}' }
                else { '{"ok":true}' }
                $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
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
        $pages = @(Get-EtbGraphCollection -Uri "http://localhost:$port/pages")
        Assert ($pages.Count -eq 2 -and $pages[1].id -eq 2) 'collection reads include subsequent pages'
        Assert-Throws { Get-EtbGraphCollection -Uri "http://localhost:$port/cycle" } 'repeated pagination link'
    } finally {
        $listener.Stop(); $listener.Close()
        $server.EndInvoke($serverAsync) | Out-Null
        $server.Dispose()
    }
} finally {
    Remove-Item $Global:AppRoot -Recurse -Force -ErrorAction SilentlyContinue
}
