# Art's Entra Toolbox — Internal Notes

Detailed usage notes, technical reference, and changelog. Not the public-facing README.

---

## Tools

| Tab | Description |
|-----|-------------|
| **Year Group Passwords** | Reset passwords for a year group of students in bulk. Generates memorable passwords (e.g. `Tiger.flame.desk47!`). Select individual or all students. Dry-run mode previews without writing. Exports CSV. |
| **User Password Reset** | Reset the password for any individual user. Control whether they are prompted to change it on next sign-in, and view the current prompt status before resetting. View the user's group memberships. |
| **Last Device** | Four sub-tabs: **By User** — pick a user, see their Intune-managed devices sorted by most-recent check-in. **By Device** — pick any Intune device, see which users have signed into it. **Stale Devices** — filter devices by days since last check-in. **Time Logs** — chronological table of every user-device logon record across the tenant. |
| **Sign-In Logs** | Search any user and view their last 50 Entra sign-ins — date/time, application, result (colour-coded), IP address, location, and device. |

## Launch

```batch
Launch.cmd
```

Requires PowerShell 7 (`pwsh.exe`). If not installed, the launcher prints an error with a download link. Download PS7 from https://aka.ms/powershell

On first run, `Start.ps1` detects that `Modules\MSAL.PS` is missing and downloads it automatically from PSGallery. No admin rights required, nothing installed system-wide.

## Adding a Tenant

1. Click **+** in the tenant bar
2. Enter your **Tenant ID** (from Entra ID > Overview)
3. Optionally enter a display name
4. Click **Connect** — a browser window opens for interactive login
5. The tenant is saved to `config\tenants.json` and remembered on next launch

Tenants can be removed with the **−** button.

## Year Group Passwords — Usage

1. Select a tenant and connect
2. Users are loaded automatically; pick a year group from the dropdown
3. Click **Load Students** — all students are selected by default
4. Deselect individuals with Ctrl+click, or use the **All** / **None** buttons
5. Choose **Dry Run** (preview) or **Live Run** (writes to Entra)
6. Click **Generate Passwords** / **Reset Passwords Now** — only selected rows are processed
7. Click any column header to sort; click **Export CSV** to save `DisplayName, UPN, Department, Password, Status`

**Password format:** `Animal.word.word##!`  e.g. `Cobra.frost.key31@`
- Uppercase, lowercase, digit, special character — satisfies Entra complexity rules
- `forceChangePasswordNextSignIn` is set to `false`

**Year group detection:** the leading digits of the `Department` field determine the group (`10HB` → Year 10). Non-numeric prefixes (e.g. `Nursery`) appear as named groups. Disabled accounts are excluded.

## User Password Reset — Usage

1. Select and connect a tenant
2. Search for a user by name or UPN in the left panel
3. Click a user — the action panel appears on the right showing:
   - Their current `forceChangePasswordNextSignIn` status (fetched live from Graph)
   - A pre-generated password (editable; click **Regenerate** for a new one)
   - A checkbox to force a password change prompt on next sign-in
   - A **Groups** tab listing all transitive group and directory-role memberships
4. Click **Reset Password** to apply

## Last Device — Usage

### By User
1. Select and connect a tenant
2. All users load automatically into the left panel
3. Type in the search box to filter by name or UPN
4. Click a user — their Intune-managed devices appear on the right, sorted by most-recent check-in
5. Click a device to copy its name to the clipboard

### By Device
1. Select and connect a tenant — all Intune devices load automatically
2. Search by device name in the left panel
3. Click a device — the right panel shows which users have signed into it, sorted by most-recent sign-in. Hover a user to see their UPN and last sign-in time.

> **Note:** Intune does not support server-side filtering on `usersLoggedOn`, so all devices are paged client-side. This may take a moment on large tenants.

### Stale Devices
1. Select a tenant and connect — uses the same device cache as By Device
2. Choose a threshold: 7 / 30 / 60 / 90 days
3. Devices not checked in within that window are listed. Devices that have never been seen appear first.

### Time Logs (detail panels)
- **By User:** Click a device in the right panel to see a detail bar showing the last time that user signed into that specific device.
- **By Device:** Click a user in the right panel to see a detail bar showing the last time that user signed into the selected device.

## File Structure

```
EntraToolbox\
├── Launch.cmd          launch script (requires PS7)
├── Start.ps1           entry point; auto-installs MSAL.PS on first run
├── version.txt         SemVer version
├── README.md           public-facing readme
├── NOTES.md            this file
├── .gitignore
├── config\             gitignored — created at runtime
│   └── tenants.json    saved tenant profiles
├── Modules\            gitignored — populated by Bootstrap.ps1
│   └── MSAL.PS\
└── src\
    ├── Auth.ps1        shared auth (MSAL), tenant config, Graph REST helpers, Get-ThemeHex
    ├── MainWindow.ps1  main shell window, tenant bar, tab host
    └── Tools\
        ├── PasswordReset.ps1       Year Group Passwords tab
        ├── UserPasswordReset.ps1   User Password Reset tab
        ├── LastDevice.ps1          Last Device tab (By User / By Device / Stale / Time Logs)
        └── SignInLogs.ps1          Sign-In Logs tab
```

## Technical Notes

- **Auth:** `MSAL.PS` with the well-known Microsoft Intune PowerShell client ID — no Azure app registration needed. Interactive auth on first use; silent token refresh on subsequent use.
- **Graph calls:** Direct `Invoke-RestMethod` with `Authorization: Bearer` header — no Microsoft.Graph SDK dependency.
- **Async pattern:** Graph fetches run in background runspaces; a `DispatcherTimer` polls and updates the UI on the WPF thread (avoids deadlocks from calling `Get-MsalToken -Interactive` on the UI thread).
- **Required scopes:** `User.ReadWrite.All`, `DeviceManagementManagedDevices.Read.All`, `AuditLog.Read.All`, `GroupMember.Read.All`

## Debug Logging

All log output goes to the console window that `Launch.cmd` opens. Lines are formatted as:

```
[HH:mm:ss.fff][LEVEL] message
```

| Level | Colour | When |
|-------|--------|------|
| `INFO`  | Cyan   | Normal lifecycle events (window loaded, auth succeeded, users loaded, run complete) |
| `WARN`  | Yellow | Non-fatal conditions worth noting (e.g. Live Run mode selected) |
| `ERROR` | Red    | Failures — auth errors, Graph errors, unhandled exceptions in event handlers |
| `DEBUG` | Dark grey | Fine-grained detail (XAML parse, each button click, selections) |

Every WPF event handler is wrapped in `try/catch` so exceptions that WPF would otherwise swallow silently are always printed to the console before the handler exits.

## Changelog

### Unreleased

#### 2026-05-13
- **Last Device — Time Logs (detail panels):** Clicking a device in By User or a user in By Device now reveals a detail bar below the list showing the exact last logon timestamp. This replaces the earlier separate Time Logs tab.
- **Year Group Passwords — multi-select:** Rows in the grid can now be individually selected/deselected (Ctrl+click, Shift+click range, Ctrl+A). Generate/Reset only processes the selected rows. A live "X of Y selected" counter sits in the sidebar.
- **Year Group Passwords — Select All / None:** Two compact buttons below "Load Students" instantly select or deselect all loaded rows. Students are auto-selected in full when a group is loaded.
- **Year Group Passwords — sortable columns:** Click any column header to sort A→Z / Z→A (or by status/password value). Template columns (Password, Status) have explicit `SortMemberPath` bindings.

#### 2026-05-12
- **New tab — Sign-In Logs:** Search for any user and view their last 50 Entra sign-ins — date/time, application, result (Success/Failure, colour-coded), IP address, location, and device. Requires `AuditLog.Read.All` (added to the consent scope). (`src/Tools/SignInLogs.ps1`)
- **User Password Reset — Groups tab:** After selecting a user, a new "Groups" tab on the right panel shows all of their transitive Entra group and directory-role memberships (sorted alphabetically, filterable by name). Requires `GroupMember.Read.All` (added to the consent scope).
- **Last Device — Stale Devices tab:** New third sub-tab reusing the already-loaded device cache. Filter by "not checked in for 7 / 30 / 60 / 90 days". Shows device name, last user, last check-in date, and days since — devices that have never been seen appear first.
- **New scopes:** `AuditLog.Read.All` and `GroupMember.Read.All` added to the MSAL token request (`src/Auth.ps1`). Users will be re-prompted for consent on the next interactive sign-in.
- **UI polish — search boxes:** Fixed text clipping in search boxes on User Password Reset and Last Device. TextBox padding reduced from `8,6` to `8,4` and search box height increased from `32` to `34` px.
- **UI polish — dark ComboBox dropdowns:** All ComboBox controls (tenant selector, year-group selector) now use a fully custom WPF template with a dark popup (`#242436` background, `#3C3C5A` border). The default system/Aero white dropdown is replaced.
- **UI polish — draggable splitters:** Year Group Passwords, User Password Reset, and both Last Device sub-tabs now have a draggable `GridSplitter` between the sidebar and content area. Sidebar minimum width standardised to `200 px` across all tools.
- **Requires PowerShell 7:** `Launch.cmd` now requires `pwsh.exe` and exits with a clear error + download link if it is not found. Removes the silent fallback to Windows PowerShell 5.1, which had a file-encoding bug that caused non-ASCII characters in source files to corrupt string parsing.
- **Rebrand:** Renamed from "Entra Tools" to "Art's Entra Toolbox" throughout (window title, header, banners, comments).
- **New tab — User Password Reset:** Reset the password for any individual Entra user. Fetches current `forceChangePasswordNextSignIn` status live from Graph before reset. Password is pre-generated and editable; a checkbox controls whether the user is prompted to change it on next sign-in. (`src/Tools/UserPasswordReset.ps1`)
- **Last Device — By Device tab:** New reverse-lookup sub-tab. All Intune managed devices are loaded async on tenant connect. Select a device to see which users have signed into it (matched from the cached user list; no extra Graph calls per selection). Existing sub-tab renamed "By User" for clarity.
- **Tab renames:** "Password Reset" → "Year Group Passwords"; the new general tab is "User Password Reset".
- **Fix:** `Update-TenantCombo` crashed on startup due to `BtnRemoveTenant` key not existing in the `$Script:MainUI` hashtable. Window would open briefly then close with no console output.
- **Debug logging:** Added `Write-Log` function (defined in `Auth.ps1`, available to all dot-sourced files). Every WPF event handler is wrapped in `try/catch` so silent crashes are surfaced immediately.
- **Startup error handling:** `Show-MainWindow` in `Start.ps1` is now wrapped in `try/catch`; a fatal crash prints the full stack trace and pauses before exit.

### v0.1.0
- Initial release
- Password Reset tab: year group detection, memorable password generation, dry/live run, CSV export
- Last Device tab: searchable user list, async Intune device lookup, clipboard copy
- Centralised MSAL auth with tenant profiles saved to `config\tenants.json`
- Tenant display name fetched from `/v1.0/organization` and shown in header
