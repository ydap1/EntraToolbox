# Entra Toolbox

WPF PowerShell GUI for Entra ID (Azure AD) tenant management. Requires Windows and [PowerShell 7](https://aka.ms/powershell).

## Tools

| Tab | Description |
|-----|-------------|
| **Year Group Passwords** | Bulk password reset by department group. Memorable password generation, dry-run mode, CSV export. |
| **User Password Reset** | Single-user password reset with live `forceChangePasswordNextSignIn` status and group membership view. |
| **Last Device** | Intune device lookup by user or by device. Includes stale-device filter (7 / 30 / 60 / 90 days). |
| **Sign-In Logs** | Last 50 sign-ins for any user — app, result, IP, location, device. |
| **Group Copy** | Copy all group memberships from one user to another. Skips groups the target already belongs to. |
| **Teams Provisioning** | Create a Class or Standard team, populate members from a year group or direct user search, assign per-person Owner roles. |

Multi-tenant. Profiles saved locally, token cache persisted across sessions — no re-authentication unless the refresh token expires.

## Usage

```batch
Launch.cmd
```

Downloads `MSAL.PS` automatically on first run. No admin rights required.

Add a tenant with the **+** button — enter your Tenant ID, sign in interactively, done. Subsequent launches connect silently.

## Permissions

Uses the Microsoft Intune PowerShell public client ID — no app registration required.

| Scope | Purpose |
|-------|---------|
| `User.ReadWrite.All` | Read users, reset passwords |
| `DeviceManagementManagedDevices.Read.All` | Last Device tab |
| `AuditLog.Read.All` | Sign-In Logs tab |
| `GroupMember.ReadWrite.All` | Group membership view and Group Copy tab |
| `Team.Create` | Create new Teams |
| `TeamMember.ReadWrite.All` | Add members and owners to Teams |

## License

MIT
