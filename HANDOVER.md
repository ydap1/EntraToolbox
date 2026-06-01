# Entra Toolbox — Handover Document

**Version:** 0.1.0  
**Repo:** `EntraToolbox` (GitHub: ydap1/EntraToolbox)  
**Stack:** PowerShell 7 · WPF · MSAL.PS · Microsoft Graph REST API  
**Platform:** Windows only (DPAPI, WPF)

---

## What It Is

A desktop GUI (WPF, dark theme) for day-to-day Entra ID / Intune admin tasks at a school tenant. No Azure app registration required — it uses the well-known Microsoft Intune PowerShell public client ID (`14d82eec-204b-4c2f-b7e8-296a70dab67e`). No Graph SDK dependency — all API calls are plain `Invoke-RestMethod` with a Bearer header.

Multi-tenant: multiple tenants can be saved and switched between. Token cache is persisted to disk across sessions so the user does not need to re-authenticate unless the refresh token has expired.

---

## Tabs

| Tab | File | Description |
|-----|------|-------------|
| **Year Group Passwords** | `src/Tools/PasswordReset.ps1` | Bulk password reset by school year group (detected from the `Department` field). Memorable password format (`Animal.word.word##!`). Dry-run mode, multi-select grid, CSV export. |
| **User Password Reset** | `src/Tools/UserPasswordReset.ps1` | Single-user password reset. Shows live `forceChangePasswordNextSignIn` status. Includes a Groups tab showing all transitive group/role memberships. |
| **Last Device** | `src/Tools/LastDevice.ps1` | Four sub-tabs: By User, By Device, Stale Devices (7/30/60/90 days), and click-to-expand time logs. Uses Intune `managedDevices` API. |
| **Sign-In Logs** | `src/Tools/SignInLogs.ps1` | Last 50 sign-ins for any user — app, result (colour-coded), IP, location, device. |
| **Group Copy** | `src/Tools/GroupCopy.ps1` | Copy all direct security/M365 group memberships from a source user to a target user. Skips groups the target already belongs to. Does not modify the source user. |

---

## Graph Scopes

| Scope | Used by |
|-------|---------|
| `User.ReadWrite.All` | All tabs — read users, reset passwords |
| `DeviceManagementManagedDevices.Read.All` | Last Device tab |
| `AuditLog.Read.All` | Sign-In Logs tab |
| `GroupMember.ReadWrite.All` | Group Copy tab (write), User Password Reset groups view (read) |

Scopes are requested together on first interactive login. Changing the scope list requires the user to re-consent (delete `config\msal_cache\token_cache.bin` or use a fresh browser session).

---

## How to Run

```batch
Launch.cmd
```

- Requires `pwsh.exe` (PowerShell 7). The launcher checks and exits with a download link if missing.
- On first run, `Start.ps1` downloads `MSAL.PS` from PSGallery into `Modules\MSAL.PS\`. No admin rights required.
- `Modules\` and `config\` are gitignored — they are created at runtime and never committed.

---

## File Structure

```
EntraToolbox\
├── Launch.cmd                  Entry point — launches pwsh.exe with Start.ps1
├── Start.ps1                   Bootstraps MSAL.PS, dot-sources all src\ files, calls Show-MainWindow
├── version.txt                 SemVer version string (currently 0.1.0)
├── README.md                   Public-facing readme
├── NOTES.md                    Internal usage notes and changelog
├── HANDOVER.md                 This file
├── config\                     [gitignored] Created at runtime
│   ├── tenants.json            Saved tenant profiles (TenantId + DisplayName)
│   └── msal_cache\
│       └── token_cache.bin     DPAPI-encrypted MSAL V3 token cache
├── Modules\                    [gitignored] Populated on first run
│   └── MSAL.PS\4.37.0.0\
└── src\
    ├── Auth.ps1                Shared auth, tenant CRUD, Graph REST helpers (Invoke-GraphGet etc.)
    ├── Demo.ps1                Demo/test mode — offline data, no real API calls
    ├── MainWindow.ps1          WPF shell window, tenant bar, tab host, Add/Remove tenant dialogs
    └── Tools\
        ├── PasswordReset.ps1
        ├── UserPasswordReset.ps1
        ├── LastDevice.ps1
        ├── SignInLogs.ps1
        └── GroupCopy.ps1
```

---

## Architecture

### Async pattern

Every Graph fetch follows the same pattern to avoid deadlocking the WPF UI thread:

1. **Runspace** — a fresh `[System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()` with variables injected via `SessionStateProxy.SetVariable`. The runspace runs the HTTP calls in the background.
2. **Synchronized hashtable** — `[hashtable]::Synchronized(@{ Done=$false; Data=$null; Error=$null })` shared between the UI thread and the runspace.
3. **DispatcherTimer** — polls every 500 ms on the WPF UI thread. When `Done` becomes `true` it stops the timer, reads results, and updates the UI.

This pattern is repeated for every async operation: user loads, device loads, password resets, group copies, etc.

### Auth (`src/Auth.ps1`)

- `Start-TenantConnectAsync` runs MSAL token acquisition in a background runspace (interactive auth MUST NOT run on the WPF thread — it deadlocks).
- Silent token acquisition is attempted first; if it fails, falls back to interactive browser login.
- **Persistent cache:** a native C# class (`EntraToolboxCache`) is compiled via `Add-Type` at runtime. It registers `SetBeforeAccess`/`SetAfterAccess` callbacks on `$app.UserTokenCache`. Callbacks are pure .NET delegates (no PowerShell scriptblocks) because MSAL.PS polls the async task via `Start-Sleep`, meaning MSAL executes on a thread-pool thread with no PS runspace — scriptblock delegates would fail there. Cache is DPAPI-encrypted (`ProtectedData.Protect`) with a fallback to plaintext if DPAPI is unavailable.
- `Invoke-GraphGet`, `Invoke-GraphPatch`, `Get-GraphPaged` are thin wrappers around `Invoke-RestMethod`.
- `$Script:ConnectCallbacks` and `$Script:ResetCallbacks` are lists of scriptblocks fired by the tenant bar when a tenant connects or is removed. Each tool registers its own reset/load callback.

### XAML

All XAML is defined as PowerShell here-strings (`@'...'@`) inside each tool's `.ps1` file. Parsed with `[System.Windows.Markup.XamlReader]::Load(...)` using a `MemoryStream`. Controls are retrieved with `$window.FindName('ControlName')` and stored in a hashtable (`$Script:UI` or `$Script:GC_UI`, etc.) for easy access.

### Demo mode

`$Script:DemoMode = $true` (set in `src/Demo.ps1`, toggled via a flag) routes all async calls to `*Demo` variants that return hardcoded data. Useful for development without a live tenant.

---

## Token Cache — Implementation Detail

`Enable-MsalTokenCacheOnDisk` from MSAL.PS 4.37 only compiles `TokenCacheHelper.cs` on Windows PowerShell 5 — on PS7 the `Add-Type` call is explicitly commented out in `MSAL.PS.ps1`. The `-CacheDirectory` parameter also does not exist in this version.

The workaround in `src/Auth.ps1` (`Start-TenantConnectAsync`):

```powershell
# Get the loaded MSAL DLL
$msalDll = ([System.AppDomain]::CurrentDomain.GetAssemblies() |
    Where-Object { $_.GetName().Name -eq 'Microsoft.Identity.Client' } |
    Select-Object -First 1).Location

# Compile EntraToolboxCache (once per AppDomain)
Add-Type -TypeDefinition $cSharpSource -ReferencedAssemblies $refs.ToArray()

# Wire callbacks
[EntraToolboxCache]::Enable($app.UserTokenCache, $cacheFile)
```

The compiled class uses `lock` for thread safety, DPAPI for encryption, and MSAL's `SerializeMsalV3`/`DeserializeMsalV3` for the binary format. If `Add-Type` fails for any reason the outer `try/catch` swallows it and auth still works — just without cross-session persistence.

---

## Tenant Management

- Tenants stored in `config\tenants.json`: `[{ TenantId: "...", DisplayName: "..." }]`
- Added via the **+** button in the header bar (dialog takes Tenant ID + optional display name)
- Removed via the **−** button (confirmation dialog)
- On launch, saved tenants are loaded into the dropdown; the first one is selected automatically and a silent token acquisition is attempted

---

## Known Limitations / Future Work

- **Group Copy — dynamic groups excluded:** `GET /users/{id}/memberOf` only returns groups the user is a direct member of. Dynamic groups appear in `memberOf` if the user satisfies the rule, but adding someone to a dynamic group via `POST /groups/{id}/members/$ref` will fail — Graph returns 400. The tool silently skips 4xx errors.
- **Group Copy — role-assignable groups:** Groups with `isAssignableToRole: true` cannot have members added via the standard `members/$ref` endpoint without `RoleManagement.ReadWrite.Directory`. These fail silently (4xx swallowed).
- **Token expiry during a session:** The access token lasts ~1 hour. Long sessions will get 401 errors from Graph. The tool does not auto-refresh mid-session. Fix: check token expiry before each Graph call and call `Start-TenantConnectAsync` again if needed.
- **Last Device — large tenants:** `DeviceManagementManagedDevices` is fully paged client-side for the By Device and Stale Devices sub-tabs. On a tenant with thousands of devices this can be slow.
- **MSAL cache is shared across tenants:** `config\msal_cache\token_cache.bin` holds accounts for all tenants in a single MSAL V3 cache file. Clearing it forces re-login for all tenants.
- **No automated tests:** The codebase has no test suite. The Demo mode provides a manual smoke-test path.

---

## Adding a New Tab

1. Create `src/Tools/MyTool.ps1`. Expose a single `Initialize-MyTool` function that returns the root `FrameworkElement` (typically a `Grid`).
2. Register connect/reset callbacks inside `Initialize-MyTool`:
   ```powershell
   $Script:ConnectCallbacks.Add({ Start-MyToolLoad })
   $Script:ResetCallbacks.Add({  Reset-MyToolUi   })
   ```
3. Add a dot-source line to `Start.ps1` before `MainWindow.ps1`:
   ```powershell
   . (Join-Path $PSScriptRoot 'src\Tools\MyTool.ps1')
   ```
4. In `src/MainWindow.ps1` XAML, add `<TabItem x:Name="TabMyTool" Header="My Tool"/>` to the `TabControl`.
5. In `Show-MainWindow`, add:
   ```powershell
   TabMyTool = $window.FindName('TabMyTool')
   # ...
   $Script:MainUI.TabMyTool.Content = Initialize-MyTool
   ```

---

## Debug Console

`Launch.cmd` keeps the console window open. Log output format:

```
[HH:mm:ss.fff][LEVEL] message
```

| Level | Colour |
|-------|--------|
| `INFO` | Cyan |
| `WARN` | Yellow |
| `ERROR` | Red |
| `DEBUG` | Dark grey |

Every WPF event handler is wrapped in `try/catch { Write-Log $_ 'ERROR' }` so silent WPF swallows are surfaced.
