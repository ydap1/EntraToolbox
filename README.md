# Entra Toolbox

A lightweight WPF PowerShell GUI for managing Entra ID (Azure AD) tenants. No Azure app registration, no SDK, no admin rights to install.

Built for school IT teams, but works for any organisation using Entra ID and Microsoft Intune.

---

## Features

| Tab | What it does |
|-----|-------------|
| **Year Group Passwords** | Bulk-reset passwords for a group of students. Generates memorable passwords (`Tiger.flame.desk47!`). Select all or individual students, dry-run before committing, export results to CSV. |
| **User Password Reset** | Reset any individual user's password. See their current "must change on next sign-in" status before you reset, control it after, and browse their group memberships. |
| **Last Device** | Find which Intune-managed devices a user has signed into — or reverse it and find which users have signed into a given device. Includes a stale-device filter (7 / 30 / 60 / 90 days). |
| **Sign-In Logs** | View the last 50 sign-ins for any user — timestamp, app, success/failure (colour-coded), IP, location, and device. |

Multi-tenant: add as many tenants as you need, switch between them from the toolbar. Tenant profiles are saved locally and reconnect silently on next launch.

---

## Requirements

- **Windows** (WPF)
- **PowerShell 7** (`pwsh.exe`) — [download here](https://aka.ms/powershell)
- An Entra ID account with sufficient permissions (see [Permissions](#permissions) below)

---

## Setup

**One-time, run once per machine:**

```batch
powershell.exe -ExecutionPolicy Bypass -File ".\Bootstrap.ps1"
```

This downloads the `MSAL.PS` module into a local `Modules\` folder. No admin rights needed, nothing is installed system-wide.

**Then to launch:**

```batch
Launch.cmd
```

---

## Adding a Tenant

1. Click **+** in the toolbar
2. Enter your **Tenant ID** (find it in Entra ID > Overview)
3. Optionally enter a friendly display name
4. Click **Connect** — a browser window opens for interactive sign-in
5. The tenant is saved and remembered on next launch

Switch tenants from the dropdown. Remove with the **−** button.

---

## Permissions

The app uses the well-known **Microsoft Intune PowerShell** public client ID — no app registration in your tenant is required. On first sign-in you'll be prompted to consent to:

| Scope | Used by |
|-------|---------|
| `User.ReadWrite.All` | Read users, reset passwords |
| `DeviceManagementManagedDevices.Read.All` | Last Device tab |
| `AuditLog.Read.All` | Sign-In Logs tab |
| `GroupMember.Read.All` | User group membership tab |

Consent is per-user. A Global Administrator or Privileged Role Administrator may need to grant consent on behalf of the organisation if user consent is restricted by policy.

---

## How it works

- Auth is handled by [`MSAL.PS`](https://github.com/AzureAD/MSAL.PS) — interactive on first use, silent token refresh after that.
- All Graph calls use `Invoke-RestMethod` directly — no Microsoft.Graph SDK dependency.
- The UI is WPF rendered from XAML embedded in the PowerShell source — no compiled binaries.
- Background Graph fetches run in separate runspaces so the UI stays responsive.

---

## License

MIT
