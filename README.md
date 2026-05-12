# Entra Tools

A WPF PowerShell toolkit for Entra ID (Azure AD) tenant management. Built for school IT teams.

## Tools

| Tab | Description |
|-----|-------------|
| **Password Reset** | Reset passwords for a year group of students. Generates memorable passwords (e.g. `Tiger.flame.desk47!`). Dry-run mode previews without writing. Exports CSV. |
| **Last Device** | Look up the Intune-managed devices a user has recently signed into. Real-time search across all users; click a device to copy its name. |

## Setup

**One-time, per machine:**

```batch
powershell.exe -ExecutionPolicy Bypass -File ".\Bootstrap.ps1"
```

This downloads `MSAL.PS` into a local `Modules\` folder. No admin rights required.

## Launch

```batch
Launch.cmd
```

Prefers PowerShell 7 (`pwsh.exe`), falls back to Windows PowerShell 5.1.

## Adding a Tenant

1. Click **+** in the tenant bar
2. Enter your **Tenant ID** (from Entra ID > Overview)
3. Optionally enter a display name
4. Click **Connect** — a browser window opens for interactive login
5. The tenant is saved to `config\tenants.json` and remembered on next launch

Tenants can be removed with the **−** button.

## Password Reset — Usage

1. Select a tenant and connect
2. Users are loaded automatically; pick a year group from the dropdown
3. Click **Load Students**
4. Choose **Dry Run** (preview) or **Live Run** (writes to Entra)
5. Click **Generate Passwords** / **Reset Passwords Now**
6. Click **Export CSV** to save `DisplayName, UPN, Department, Password, Status`

**Password format:** `Animal.word.word##!`  e.g. `Cobra.frost.key31@`
- Uppercase, lowercase, digit, special character — satisfies Entra complexity rules
- `forceChangePasswordNextSignIn` is set to `false`

**Year group detection:** the leading digits of the `Department` field determine the group (`10HB` → Year 10). Non-numeric prefixes (e.g. `Nursery`) appear as named groups. Disabled accounts are excluded.

## Last Device — Usage

1. Select and connect a tenant
2. All users load automatically into the left panel
3. Type in the search box to filter by name or UPN
4. Click a user — their Intune-managed devices appear on the right, sorted by most-recent check-in
5. Click a device to copy its name to the clipboard

> **Note:** Intune does not support server-side filtering on `usersLoggedOn`, so all devices are paged client-side. This may take a moment on large tenants.

## File Structure

```
Password_Year3\
├── Launch.cmd          launch script (prefers PS7, falls back to 5.1)
├── Start.ps1           entry point
├── Bootstrap.ps1       one-time module installer
├── version.txt         SemVer version
├── README.md
├── .gitignore
├── config\             gitignored — created at runtime
│   └── tenants.json    saved tenant profiles
├── Modules\            gitignored — populated by Bootstrap.ps1
│   └── MSAL.PS\
└── src\
    ├── Auth.ps1        shared auth (MSAL), tenant config, Graph REST helpers
    ├── MainWindow.ps1  main shell window, tenant bar, tab host
    └── Tools\
        ├── PasswordReset.ps1   password reset tab
        └── LastDevice.ps1      last device lookup tab
```

## Technical Notes

- **Auth:** `MSAL.PS` with the well-known Microsoft Intune PowerShell client ID — no Azure app registration needed. Interactive auth on first use; silent token refresh on subsequent use.
- **Graph calls:** Direct `Invoke-RestMethod` with `Authorization: Bearer` header — no Microsoft.Graph SDK dependency.
- **Async pattern:** Graph fetches run in background runspaces; a `DispatcherTimer` polls and updates the UI on the WPF thread (avoids deadlocks from calling `Get-MsalToken -Interactive` on the UI thread).
- **Required scopes:** `User.ReadWrite.All`, `DeviceManagementManagedDevices.Read.All`

## Changelog

### v0.1.0
- Initial release
- Password Reset tab: year group detection, memorable password generation, dry/live run, CSV export
- Last Device tab: searchable user list, async Intune device lookup, clipboard copy
- Centralised MSAL auth with tenant profiles saved to `config\tenants.json`
- Tenant display name fetched from `/v1.0/organization` and shown in header
