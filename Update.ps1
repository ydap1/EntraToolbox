#Requires -Version 7.0
# Launch.cmd enters here before loading application code, which may be updated.
param([Parameter(ValueFromRemainingArguments)][string[]]$LaunchArguments)

function Get-EtbUpdateNotes {
    param([string]$Source, [string]$Version)
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Source, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw 'Release notes could not be parsed.' }
    $history = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq 'Script:IH_History'
    }, $true)
    if (-not $history) { throw 'Release notes were not found.' }
    foreach ($table in $history.Right.FindAll({ param($node) $node -is [Management.Automation.Language.HashtableAst] }, $true)) {
        $fields = @{}
        foreach ($pair in $table.KeyValuePairs) {
            if ($pair.Item1 -is [Management.Automation.Language.StringConstantExpressionAst]) {
                $fields[$pair.Item1.Value] = $pair.Item2.PipelineElements[0].Expression
            }
        }
        if ($fields.Version -isnot [Management.Automation.Language.StringConstantExpressionAst] -or $fields.Version.Value -ne $Version) { continue }
        if ($fields.Changes -isnot [Management.Automation.Language.ArrayExpressionAst]) { throw 'Release notes are not a literal list.' }
        foreach ($statement in $fields.Changes.SubExpression.Statements) {
            $expression = $statement.PipelineElements[0].Expression
            $literals = if ($expression -is [Management.Automation.Language.ArrayLiteralAst]) { $expression.Elements } else { @($expression) }
            foreach ($literal in $literals) {
                if ($literal -isnot [Management.Automation.Language.StringConstantExpressionAst]) { throw 'Release notes contain a nonliteral entry.' }
                # Do not allow downloaded text to send terminal control sequences.
                $literal.Value -replace '[\x00-\x1f\x7f-\x9f]', ' '
            }
        }
        return
    }
    throw "No release notes for v$Version."
}

function Get-EtbStartupUpdate {
    param([string]$AppRoot)
    $local = [version](Get-Content (Join-Path $AppRoot 'version.txt') -Raw -ErrorAction Stop).Trim()
    # Pin the version, description and installed source to the same commit.
    $commit = (Invoke-RestMethod -Uri 'https://api.github.com/repos/ydap1/EntraToolbox/commits/main' -Headers @{ 'User-Agent' = 'EntraToolbox-Updater' } -TimeoutSec 8 -ErrorAction Stop).sha
    if ($commit -notmatch '^[a-f0-9]{40}$') { throw 'The update server returned an invalid commit.' }
    $base = "https://raw.githubusercontent.com/ydap1/EntraToolbox/$commit"
    $remoteText = ([string](Invoke-RestMethod -Uri "$base/version.txt" -TimeoutSec 8 -ErrorAction Stop)).Trim()
    if ($remoteText -notmatch '^\d+\.\d+\.\d+$') { throw 'The update server returned an invalid version.' }
    if ([version]$remoteText -le $local) { return $null }
    $notes = try {
        $source = [string](Invoke-RestMethod -Uri "$base/src/Tools/UpdateHistory.ps1" -TimeoutSec 8 -ErrorAction Stop)
        @(Get-EtbUpdateNotes -Source $source -Version $remoteText)
    } catch { @('Release description unavailable. See Update History after updating.') }
    [pscustomobject]@{ Local = $local.ToString(); Version = $remoteText; Commit = $commit; Notes = @($notes) }
}

function Invoke-EtbUpdateGit {
    param([string]$AppRoot, [string[]]$Arguments)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = 'git'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $info.Environment['GCM_INTERACTIVE'] = 'Never'
    foreach ($argument in @('-C', $AppRoot) + $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw 'Git timed out after 30 seconds. Check your connection and repository before retrying.'
        }
        $output = $stdout.GetAwaiter().GetResult().Trim()
        $errorText = $stderr.GetAwaiter().GetResult().Trim()
        if ($process.ExitCode -ne 0) { throw "Git $($Arguments[0]) failed: $errorText" }
        return $output
    } finally { $process.Dispose() }
}

function Install-EtbStartupUpdate {
    param([string]$AppRoot, [string]$Commit)
    if ($Commit -notmatch '^[a-f0-9]{40}$') { throw 'Invalid update commit.' }
    if (-not (Test-Path (Join-Path $AppRoot '.git'))) { throw 'Automatic updates need a Git clone. Download the latest copy from github.com/ydap1/EntraToolbox instead.' }
    $top = Invoke-EtbUpdateGit $AppRoot @('rev-parse', '--show-toplevel')
    if ([IO.Path]::GetFullPath($top) -ne [IO.Path]::GetFullPath($AppRoot)) { throw 'The application must be at the repository root.' }
    $branch = Invoke-EtbUpdateGit $AppRoot @('branch', '--show-current')
    if ($branch -ne 'main') { throw 'Automatic updates only run on main. Your current branch has not been changed.' }
    $remote = Invoke-EtbUpdateGit $AppRoot @('remote', 'get-url', 'origin')
    if ($remote -notmatch '^(https://github\.com/|git@github\.com:)ydap1/EntraToolbox(\.git)?/?$') { throw 'Origin does not point to the official EntraToolbox repository.' }
    if (Invoke-EtbUpdateGit $AppRoot @('status', '--porcelain', '--untracked-files=all')) { throw 'Local changes or untracked files found. Commit or move them before updating; nothing has been reset.' }
    $null = Invoke-EtbUpdateGit $AppRoot @('fetch', '--no-tags', 'origin', 'main')
    $fetched = Invoke-EtbUpdateGit $AppRoot @('rev-parse', 'FETCH_HEAD')
    if ($fetched -ne $Commit) { throw 'The available update changed while the prompt was open. Relaunch to review the latest description.' }
    $null = Invoke-EtbUpdateGit $AppRoot @('merge-base', '--is-ancestor', 'HEAD', $Commit)
    # Refuse to overwrite even ignored files if a release starts tracking them.
    $null = Invoke-EtbUpdateGit $AppRoot @('merge', '--ff-only', '--no-edit', '--no-overwrite-ignore', $Commit)
    if ((Invoke-EtbUpdateGit $AppRoot @('rev-parse', 'HEAD')) -ne $Commit) { throw 'The installed revision could not be verified.' }
}

function Invoke-EtbStartupUpdate {
    param([string]$AppRoot)
    Write-Host '[startup] Checking for updates…' -ForegroundColor DarkGray
    try { $update = Get-EtbStartupUpdate $AppRoot } catch {
        Write-Host "[startup] Update check unavailable: $($_.Exception.Message). Opening the installed version." -ForegroundColor Yellow
        return $true
    }
    if (-not $update) {
        Write-Host '[startup] Already up to date.' -ForegroundColor DarkGray
        return $true
    }
    Write-Host "`nUpdate available: v$($update.Local) -> v$($update.Version)" -ForegroundColor Yellow
    Write-Host 'Latest changes:'
    foreach ($note in $update.Notes) { Write-Host "  - $note" }
    do { $answer = (Read-Host 'Update now? Yes/No [No]').Trim() } while ($answer -notmatch '^(y|yes|n|no)?$')
    if ($answer -notmatch '^(y|yes)$') {
        Write-Host '[startup] Update skipped. Opening the installed version.'
        return $true
    }
    Write-Host '[startup] Updating…' -ForegroundColor Yellow
    try {
        Install-EtbStartupUpdate -AppRoot $AppRoot -Commit $update.Commit
        Write-Host "[startup] Updated to v$($update.Version). Starting Entra Toolbox." -ForegroundColor Green
        return $true
    } catch {
        Write-Host "[startup] Update not completed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'The app will not start after an unsuccessful update. Resolve the issue and relaunch, or choose No to use the installed version.' -ForegroundColor Yellow
        return $false
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    if (-not (Invoke-EtbStartupUpdate -AppRoot $PSScriptRoot)) {
        $null = Read-Host 'Press Enter to close'
        exit 1
    }
    & (Join-Path $PSScriptRoot 'Start.ps1') @LaunchArguments
}
