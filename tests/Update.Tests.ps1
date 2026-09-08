#Requires -Version 7.0
# Offline updater checks; all Git writes are confined to temporary repositories.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. (Join-Path $root 'Update.ps1')
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "PASS $Message"
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    $message = ''
    try { & $Action } catch { $message = $_.Exception.Message }
    Assert ($message -like "*$Pattern*") "rejects $Pattern"
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('etb-update-tests-' + [guid]::NewGuid())
New-Item $scratch -ItemType Directory | Out-Null
try {
    $current = (Get-Content (Join-Path $root 'version.txt') -Raw).Trim()
    $history = Get-Content (Join-Path $root 'src/Tools/UpdateHistory.ps1') -Raw
    $notes = @(Get-EtbUpdateNotes $history $current)
    Assert ($notes.Count -gt 0) 'latest release descriptions are read from the existing update history'
    $Script:NotesExecuted = $false
    $source = @'
$Script:NotesExecuted = $true
$Script:IH_History = @(@{ Version = '1.0.0'; Changes = @('A user''s device', 'Second change') })
'@
    $notes = @(Get-EtbUpdateNotes $source '1.0.0')
    Assert ($notes.Count -eq 2 -and $notes[0] -eq "A user's device" -and -not $Script:NotesExecuted) 'release notes handle quoted text without executing downloaded PowerShell'
    $source = @'
$Script:IH_History = @(@{ Version = '1.0.0'; Changes = @($(throw 'must not execute')) })
'@
    Assert-Throws { Get-EtbUpdateNotes $source '1.0.0' } 'nonliteral'
    Assert-Throws { Get-EtbUpdateNotes '$Script:IH_History = @(' '1.0.0' } 'could not be parsed'
    & {
        $calls = [Collections.Generic.List[string]]::new()
        $commit = 'a' * 40
        $version = '99.0.0'
        $notesUnavailable = $false
        function Invoke-RestMethod {
            param($Uri, $Headers, $TimeoutSec, $ErrorAction)
            $calls.Add($Uri)
            Assert ($TimeoutSec -le 8) 'startup network requests have a bounded timeout'
            if ($Uri -like 'https://api.github.com/*') { return @{ sha = $commit } }
            Assert ($Uri -like "https://raw.githubusercontent.com/ydap1/EntraToolbox/$commit/*") 'version and description use the same pinned commit'
            if ($Uri -like '*/version.txt') { return $version }
            if ($notesUnavailable) { throw 'Notes unavailable' }
            return '$Script:IH_History = @(@{ Version = ''99.0.0''; Changes = @(''Device support'') })'
        }
        $update = Get-EtbStartupUpdate $root
        Assert ($update.Version -eq '99.0.0' -and $update.Commit -eq $commit -and $update.Notes[0] -eq 'Device support') 'update metadata includes the latest version, commit and description'
        $notesUnavailable = $true
        Assert ((Get-EtbStartupUpdate $root).Notes[0] -like '*description unavailable*') 'unavailable release notes are explicitly reported'
        $version = $current
        $calls.Clear()
        Assert ($null -eq (Get-EtbStartupUpdate $root) -and $calls.Count -eq 2) 'current installations skip notes and do not offer an update'
        $version = '0.1.0'
        Assert ($null -eq (Get-EtbStartupUpdate $root)) 'newer local versions are never downgraded'
        $version = 'not a version'
        Assert-Throws { Get-EtbStartupUpdate $root } 'invalid version'
        $commit = 'bad commit'
        Assert-Throws { Get-EtbStartupUpdate $root } 'invalid commit'
    }
    & {
        $messages = [Collections.Generic.List[string]]::new()
        $answers = [Collections.Generic.Queue[string]]::new()
        $state = @{ Installs = 0; Available = $true; Offline = $false; Fail = $false }
        function Write-Host { param($Object, $ForegroundColor) $messages.Add([string]$Object) }
        function Read-Host { param($Prompt) $messages.Add($Prompt); $answers.Dequeue() }
        function Get-EtbStartupUpdate {
            if ($state.Offline) { throw 'Offline' }
            if ($state.Available) { [pscustomobject]@{ Local = '1.0.0'; Version = '2.0.0'; Commit = ('a' * 40); Notes = @('Latest device improvement') } }
        }
        function Install-EtbStartupUpdate {
            param($AppRoot, $Commit)
            $state.Installs++
            if ($state.Fail) { throw 'Local edits' }
        }
        foreach ($answer in 'No', '', 'n') {
            $answers.Enqueue($answer)
            Assert ((Invoke-EtbStartupUpdate $root) -and $state.Installs -eq 0) 'No or Enter starts the installed version without Git writes'
        }
        Assert ($messages.IndexOf('  - Latest device improvement') -lt $messages.IndexOf('Update now? Yes/No [No]')) 'the latest description is printed before requesting consent'
        $answers.Enqueue('invalid'); $answers.Enqueue('YES')
        Assert ((Invoke-EtbStartupUpdate $root) -and $state.Installs -eq 1) 'Yes installs once and permits launching the updated app'
        $state.Fail = $true
        $answers.Enqueue('y')
        Assert (-not (Invoke-EtbStartupUpdate $root)) 'an unsuccessful update prevents launching potentially partial files'
        $state.Available = $false
        Assert (Invoke-EtbStartupUpdate $root) 'up-to-date startup does not ask for input'
        $state.Offline = $true
        Assert (Invoke-EtbStartupUpdate $root) 'offline startup still launches the installed app'
    }
    Write-Host 'PASS Yes/No, description ordering, offline and unsuccessful-update startup paths'

    # Real fetch and fast-forward operations, with only the approved remote name
    # substituted so these tests never need GitHub or credentials.
    $origin = Join-Path $scratch 'origin'
    $checkout = Join-Path $scratch 'checkout with spaces'
    New-Item $origin -ItemType Directory | Out-Null
    $null = Invoke-EtbUpdateGit $origin @('init', '-b', 'main')
    $null = Invoke-EtbUpdateGit $origin @('config', 'user.name', 'ydap1')
    $null = Invoke-EtbUpdateGit $origin @('config', 'user.email', 'artemiy600@gmail.com')
    Set-Content (Join-Path $origin 'version.txt') '1.0.0'
    Set-Content (Join-Path $origin '.gitignore') "config/`nModules/"
    $null = Invoke-EtbUpdateGit $origin @('add', '.')
    $null = Invoke-EtbUpdateGit $origin @('commit', '-m', 'test: seed updater fixture')
    $null = Invoke-EtbUpdateGit $scratch @('clone', $origin, $checkout)
    Set-Content (Join-Path $origin 'version.txt') '2.0.0'
    $null = Invoke-EtbUpdateGit $origin @('commit', '-am', 'test: publish updater fixture')
    $tip = Invoke-EtbUpdateGit $origin @('rev-parse', 'HEAD')
    New-Item (Join-Path $checkout 'config') -ItemType Directory | Out-Null
    Set-Content (Join-Path $checkout 'config/tenants.json') 'keep tenant configuration'
    $realGit = ${function:Invoke-EtbUpdateGit}
    & {
        function Invoke-EtbUpdateGit {
            param($AppRoot, $Arguments)
            if ($Arguments[0] -eq 'remote') { return 'https://github.com/ydap1/EntraToolbox.git' }
            if ($Arguments[0] -eq 'fetch') { return & $realGit $AppRoot @('fetch', '--no-tags', $origin, 'main') }
            & $realGit $AppRoot $Arguments
        }
        Set-Content (Join-Path $checkout 'notes.txt') 'local notes'
        Assert-Throws { Install-EtbStartupUpdate $checkout $tip } 'Local changes'
        Assert ((Get-Content (Join-Path $checkout 'notes.txt')) -eq 'local notes') 'untracked user files remain untouched'
        Remove-Item (Join-Path $checkout 'notes.txt')
        $null = Invoke-EtbUpdateGit $checkout @('switch', '-c', 'feature')
        Assert-Throws { Install-EtbStartupUpdate $checkout $tip } 'only run on main'
        $null = Invoke-EtbUpdateGit $checkout @('switch', 'main')
        Assert-Throws { Install-EtbStartupUpdate $checkout ('b' * 40) } 'update changed'
        Install-EtbStartupUpdate $checkout $tip
        Assert ((Get-Content (Join-Path $checkout 'version.txt')) -eq '2.0.0' -and (Invoke-EtbUpdateGit $checkout @('rev-parse', 'HEAD')) -eq $tip) 'a clean Git clone fast-forwards to exactly the reviewed commit'
        Assert ((Get-Content (Join-Path $checkout 'config/tenants.json')) -eq 'keep tenant configuration') 'updates preserve ignored tenant configuration'
        # A future release must not overwrite an ignored local configuration file.
        New-Item (Join-Path $origin 'config') -ItemType Directory | Out-Null
        Set-Content (Join-Path $origin 'config/tenants.json') 'unexpected tracked config'
        $null = Invoke-EtbUpdateGit $origin @('add', '-f', 'config/tenants.json')
        $null = Invoke-EtbUpdateGit $origin @('commit', '-m', 'test: cover ignored file collision')
        $collision = Invoke-EtbUpdateGit $origin @('rev-parse', 'HEAD')
        Assert-Throws { Install-EtbStartupUpdate $checkout $collision } 'Git merge failed'
        Assert ((Get-Content (Join-Path $checkout 'config/tenants.json')) -eq 'keep tenant configuration') 'ignored-file collisions are rejected without overwriting data'
        Set-Content (Join-Path $checkout 'local.txt') 'local work'
        $null = Invoke-EtbUpdateGit $checkout @('add', 'local.txt')
        $null = Invoke-EtbUpdateGit $checkout @('-c', 'user.name=ydap1', '-c', 'user.email=artemiy600@gmail.com', 'commit', '-m', 'test: retain divergent local work')
        $localTip = Invoke-EtbUpdateGit $checkout @('rev-parse', 'HEAD')
        Assert-Throws { Install-EtbStartupUpdate $checkout $collision } 'Git merge-base failed'
        Assert ((Invoke-EtbUpdateGit $checkout @('rev-parse', 'HEAD')) -eq $localTip -and (Get-Content (Join-Path $checkout 'local.txt')) -eq 'local work') 'divergent local commits are preserved without a reset or merge commit'
    }
    Assert-Throws { Install-EtbStartupUpdate $checkout $tip } 'official EntraToolbox repository'
    Assert-Throws { Install-EtbStartupUpdate $scratch $tip } 'need a Git clone'
    Assert-Throws { Install-EtbStartupUpdate $checkout 'bad' } 'Invalid update commit'
    Write-Host 'All offline updater checks passed.'
} finally {
    Remove-Item $scratch -Recurse -Force
}
