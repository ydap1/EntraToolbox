# Entra Toolbox

WPF PowerShell GUI for Entra ID (Azure AD) tenant management. Requires Windows and [PowerShell 7](https://aka.ms/powershell).

## Tools

| Tool | Category | Description |
|------|----------|-------------|
| **Year Group Passwords** | Users | Bulk password reset by department. Memorable password generation, dry-run preview, CSV export. |
| **User Password Reset** | Users | Single-account password reset with live `forceChangePasswordNextSignIn` toggle and group membership view. |
| **Bulk UPN Change** | Users | Move cloud-only users to a different verified domain. Import by department, office location, or individual search. |
| **Immutable ID** | Users | Assign or remove `onPremisesImmutableId` on cloud-only accounts. Per-row checkboxes, confirm-by-typing-YES safety gate. |
| **Last Device** | Devices | Intune device lookup by user or by device name. Stale device filter (7 / 30 / 60 / 90 days). Time Logs sub-tab. |
| **Sign-In Logs** | Audit | Last 50 sign-ins for any user — app, result, IP, location, device. |
| **Group Copy** | Groups & Teams | Copy all group memberships from one user to another. Skips groups the target already belongs to. |
| **Teams Provisioning** | Groups & Teams | Create a Class or Standard team, populate members from a year group or direct user search, assign per-person Owner roles. |

Multi-tenant. Profiles saved locally, token cache persisted across sessions — no re-authentication unless the refresh token expires.

## Usage

```batch
Launch.cmd
```

Downloads `MSAL.PS` automatically on first run. No admin rights required.

Add a tenant with the **+** button — enter your Tenant ID, sign in interactively, done. Subsequent launches connect silently.

Use **Dry Run** in the tenant bar to preview destructive actions (password resets, UPN changes, ID assignments) without executing them.

## Permissions

Uses the Microsoft Intune PowerShell public client ID — no app registration required.

| Scope | Purpose |
|-------|---------|
| `User.ReadWrite.All` | Read users, reset passwords, change UPNs, set ImmutableId |
| `DeviceManagementManagedDevices.Read.All` | Last Device tab |
| `AuditLog.Read.All` | Sign-In Logs tab |
| `GroupMember.ReadWrite.All` | Group membership view and Group Copy tab |
| `Team.Create` | Create new Teams |
| `TeamMember.ReadWrite.All` | Add members and owners to Teams |

## License

MIT
