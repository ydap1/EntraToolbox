# Entra Toolbox

WPF PowerShell GUI for Entra ID (Azure AD) tenant management. Requires Windows and [PowerShell 7](https://aka.ms/powershell).

## Tools

| Tab | Description |
|-----|-------------|
| **Year Group Passwords** | Bulk password reset by department group. Memorable password generation, dry-run mode, CSV export. |
| **User Password Reset** | Single-user password reset with live `forceChangePasswordNextSignIn` status and group membership view. |
| **Last Device** | Intune device lookup by user or by device. Includes stale-device filter (7 / 30 / 60 / 90 days). |
| **Sign-In Logs** | Last 50 sign-ins for any user — app, result, IP, location, device. |

Multi-tenant. Profiles saved locally, silent token refresh on subsequent launches. Five colour themes with live switching.

## Usage

```batch
Launch.cmd
```

Downloads `MSAL.PS` automatically on first run. No admin rights required.

Add a tenant with the **+** button — enter your Tenant ID, sign in interactively, done.

## Permissions

Uses the Microsoft Intune PowerShell public client ID — no app registration required.

| Scope | Purpose |
|-------|---------|
| `User.ReadWrite.All` | Read users, reset passwords |
| `DeviceManagementManagedDevices.Read.All` | Last Device tab |
| `AuditLog.Read.All` | Sign-In Logs tab |
| `GroupMember.Read.All` | Group membership tab |

## License

MIT
