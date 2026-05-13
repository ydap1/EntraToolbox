# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Art's Entra Toolbox — a WPF PowerShell GUI for school IT teams to manage Entra ID (Azure AD) tenants. No Azure app registration needed: it uses the well-known Microsoft Intune PowerShell public client ID (`14d82eec-204b-4c2f-b7e8-296a70dab67e`) with interactive MSAL auth.

## Running the app

**First time (one-time per machine):**
```batch
powershell.exe -ExecutionPolicy Bypass -File ".\Bootstrap.ps1"
```
Downloads `MSAL.PS` into `Modules\` — no admin rights needed.

**Launch:**
```batch
Launch.cmd
```
Requires PowerShell 7 (`pwsh.exe`). All console output (debug log) appears in the cmd window that Launch.cmd opens.

There is no build step, linter, or test suite — the app runs directly from source.

## Architecture

All source files are dot-sourced by `Start.ps1` at startup in this order:
1. `src/Auth.ps1` — shared state, MSAL auth, Graph REST helpers, `Write-Log`
2. `src/Tools/PasswordReset.ps1` — Year Group Passwords tab
3. `src/Tools/UserPasswordReset.ps1` — User Password Reset tab
4. `src/Tools/LastDevice.ps1` — Last Device tab (By User / By Device / Stale Devices)
5. `src/Tools/SignInLogs.ps1` — Sign-In Logs tab
6. `src/MainWindow.ps1` — shell window, tenant bar, wires tabs together

Because everything runs in a single PowerShell session, all script-scoped variables (`$Script:*`) defined in Auth.ps1 are accessible to all tool files.

### Key shared state (Auth.ps1)

| Variable | Purpose |
|---|---|
| `$Script:AccessToken` | Bearer token for all Graph calls — set after MSAL auth |
| `$Script:CurrentTenantId` | Active tenant |
| `$Script:ConnectCallbacks` | List of scriptblocks called after a tenant connects (each tool registers one to trigger its data load) |
| `$Script:ResetCallbacks` | Called when switching/removing tenants to clear tool state |

### Tool pattern

Each tool file exposes one function: `Initialize-<ToolName>Tool`. It:
- Parses its XAML string to build its UI panel
- Registers callbacks in `$Script:ConnectCallbacks` / `$Script:ResetCallbacks`
- Returns the WPF panel, which MainWindow assigns to its `TabItem.Content`

### Async pattern

Graph calls and MSAL auth **must not** block the WPF UI thread. The pattern used throughout:
1. Start a background `Runspace` + `PowerShell` instance with a synchronized `[hashtable]` ref
2. Start a `DispatcherTimer` that polls the ref every 500 ms
3. On completion, the timer tick updates the UI (safe — runs on the UI thread) and stops itself

### Graph calls

Three helpers in `Auth.ps1`:
- `Invoke-GraphGet [path]` — GET, returns response object
- `Invoke-GraphPatch [path] [body hashtable]` — PATCH
- `Get-GraphPaged [path]` — GET with automatic `@odata.nextLink` pagination, returns array

All calls use `Invoke-RestMethod` directly with a `Bearer` header — no Microsoft.Graph SDK.

### Logging

`Write-Log [message] [level]` is defined in `Auth.ps1` and available everywhere. Levels: `INFO` (cyan), `WARN` (yellow), `ERROR` (red), `DEBUG` (dark grey). Every WPF event handler is wrapped in `try/catch` that calls `Write-Log` so silent WPF swallowed exceptions surface in the console.

### Tenant config

Tenant profiles (TenantId + DisplayName) are persisted to `config\tenants.json` (gitignored, created at runtime). Functions: `Get-SavedTenants`, `Save-Tenant`, `Remove-SavedTenant`.

## Graph scopes

All four scopes are requested together at first interactive auth:
- `User.ReadWrite.All`
- `DeviceManagementManagedDevices.Read.All`
- `AuditLog.Read.All`
- `GroupMember.Read.All`

Adding a new scope requires updating `$Script:GraphScopes` in `Auth.ps1`. Users will be re-prompted for consent on next interactive sign-in.

## UI conventions

- Dark theme: background `#12121C`, surface `#1C1C2A`, accent `#6366F1`
- XAML is stored as here-strings (`@'...'@`) inside each `.ps1` file — no separate `.xaml` files
- WPF controls are found with `FindName()` after `XamlReader::Load()` and stored in a `$Script:*_UI` hashtable
- `GridSplitter` between sidebar and content; sidebar minimum width 200 px across all tools
- Password format: `Animal.word.word##!` — generated with `New-Password` in `PasswordReset.ps1` using `System.Security.Cryptography.RandomNumberGenerator`
