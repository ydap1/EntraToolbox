# Entra Toolbox

> **Note:** This tool was built for my own specific IT workflow managing school Entra ID tenants. It is published publicly for reference but may be completely useless for your use case.

WPF PowerShell GUI for Entra ID (Azure AD) tenant management. Requires Windows and [PowerShell 7](https://aka.ms/powershell).

## Tools

| Tool | Category | Description |
|------|----------|-------------|
| **User Overview** | Users | Account status, department, groups, licences, Intune devices and ten recent sign-ins in one screen. Refresh reads current details; section errors remain separate. Ctrl+K opens Overview by default, with shortcuts to existing user tools. |
| **Year Group Passwords** | Users | Bulk password reset with separate year-group and department dropdowns. Memorable password generation (`cat.dog.pat11!`), optional forced sign-in prompt, dry-run preview, CSV export, printable slips, and a Stop button for live runs. Narrow the selection to a pasted list or CSV. |
| **User Password Reset** | Users | Single-account password reset without blocking the UI, with live `forceChangePasswordNextSignIn` toggle and group membership view. |
| **Leaver Workflow** | Users | Disable account, revoke sign-in sessions, and remove from all groups in one click. Each step is individually togglable. Dry-run aware. Removed memberships are saved to disk and can be put back with Restore Groups. |
| **Licence Assignment** | Users | View a user's assigned Microsoft 365 licences. Assign or remove individual SKUs. Shows available seats remaining per SKU. |
| **Bulk Licences** | Users | Select users by year, department, search or CSV. Preview seat requirements, direct/group assignments, assignment errors and missing usage locations. Assign a SKU or remove direct assignments, with dry run, per-user results, Stop through Bulk Results and CSV export. Re-preview checks current assignments before another run. |
| **Bulk UPN Change** | Users | Move cloud-only users to a different verified domain. Add users by year group, department, office location, individual search, or a pasted list / CSV. Overlapping selections are deduplicated. |
| **Immutable ID** | Users | Assign or remove `onPremisesImmutableId` on cloud-only accounts. Per-row checkboxes, confirm-by-typing-YES safety gate. |
| **Last Device** | Devices | Intune device lookup by user or by device name, sharing one inventory download per connection. Stale device filter (7 / 30 / 60 / 90 days). Time Logs sub-tab. Export CSV reports (per device/user sign-in, or one row per device) of the latest recorded user/device sign-ins within the past 3 months; this is not a complete sign-in audit trail. |
| **Device Compliance** | Devices | Overview of all Intune-managed device compliance states, filterable by state and by name. Selecting a non-compliant device shows which policies are failing and how many settings are out of compliance. |
| **Change History** | Audit | Browse this installation’s audit CSVs for the connected tenant. Filter by date, operator, tool or user/action text, refresh and export the shown records. Reports unreadable files and keeps demo history separate from real records. |
| **Bulk Results** | Audit | Track live bulk writes, stop between requests, export results/failures and recover supported confirmed failures. Uncertain outcomes are kept separate. |
| **Sign-In Logs** | Audit | Date-range search with 50-record pages and Load more, including disabled users. Filter loaded records by failure, app, IP or reason; inspect failure details and correlation IDs, then export the shown records. Availability depends on tenant retention and licensing. |
| **Group Manager** | Groups & Teams | Compare cloud-managed, assigned security or Microsoft 365 groups with a year group, department or imported user roster. Add missing users or match user membership, preserving owners and non-user members. Preview additions/removals, recheck for changed membership before applying, dry run, Stop, per-user results and CSV export. |
| **Group Copy** | Groups & Teams | Copy all group memberships from one user to another. Skips existing memberships, dynamic groups, and role-assignable groups. |
| **Security Group Creator** | Groups & Teams | Create an assigned-membership security group. Choose year groups (using the same grouping as Teams Provisioning) or exact departments from separate dropdowns with user counts. Combine these with manual user searches, pasted usernames and CSV imports. Search Entra devices by name or ID and add selected devices for device-only or mixed groups. Review member types and remove members before creation. Supports empty groups, dry-run previews, offline demo, per-member results and audit records. |
| **Teams Provisioning** | Groups & Teams | Create a Class or Standard team. Load members using separate year-group and department dropdowns, or direct user search. Team Type and Population choices show a contrasting selection dot; per-person Owner roles use single-click checkboxes. |
| **Secure Score** | Security | Microsoft Secure Score percentage headline with per-control breakdown table. |
| **Appearance** | App | Theme presets (Slate & Amber, Indigo Night, Ocean, Forest, Rose) and UI font picker with per-font preview. |

### Bulk results

**Bulk Results** lists live password, UPN, immutable-ID, group-copy, security-group and Teams runs. It shows per-request outcomes and progress, with cooperative **Stop**, result CSVs and failure-only exports. Confirmed failed UPN/immutable-ID changes and group membership requests can be retried explicitly. Uncertain readable changes can be checked against current state; an absent change remains uncertain. Passwords and object creation are never replayed there. Refresh the original tool after recovery. Session results clear on tenant switch; directory change records remain on disk.

### Record of changes

Operations that alter the directory — password resets, UPN changes, immutable IDs, leaver steps, group copies, licence changes, team creation, device syncs — append a row to `config\audit\<tenant>-<month>.csv` naming the operator, target, result and time. Dry runs and demo mode change nothing and so are not recorded, and passwords never appear there; use the tool's own CSV export for those.

The Leaver Workflow additionally writes the group memberships it removes to `config\leavers\`, because that is the one step whose effect cannot be reconstructed afterwards. **Restore Groups** reads one of those snapshots back.

Multi-tenant. Profiles saved locally, token cache persisted across sessions — no re-authentication unless the refresh token expires. Access tokens are refreshed silently in the background during long sessions, and Graph requests honor throttling delays. Read requests retry transient server errors; writes are not replayed after ambiguous server failures. Switching tenants cancels outstanding work and discards stale results.

## Usage

Tools in the navigation sidebar have individual bordered cards; the selected tool has an accent outline.

Teams Provisioning, Year Group Passwords, Bulk UPN Change and Security Group Creator share year-group and department dropdowns with user counts. Year groups combine class codes such as `7A` and `7B`; department selection preserves the full department name. Names such as `Year 7` are also recognised. Teams and password-reset load buttons replace the current list; Bulk UPN Change and Security Group Creator add to it without duplicating users. Counts reflect each tool's eligible users, including the cloud-only restriction in Bulk UPN Change.

Use **Clear all** in these tools to empty the loaded-user list and start over while keeping names, settings and dropdown choices. In Year Group Passwords this also clears generated results from the table; it does not undo completed tenant changes. Security Group Creator's separate **New group** button resets the entire form.

```batch
Launch.cmd
```

Downloads the pinned `MSAL.PS` version `4.37.0.0` automatically on first run. No admin rights required.

On launch, the console checks GitHub for a newer version and prints its latest **Update History** description before asking **Update now? Yes/No [No]**. Enter **Yes** to update and open the new version; **No** or Enter opens the installed version. If the check is unavailable or offline, the app still opens. Checks use bounded network timeouts, so an offline launch may take a few seconds longer.

Automatic installation requires Git and a clean clone on `main` with `origin` pointing to this repository. It uses a [fast-forward-only update](https://git-scm.com/docs/git-merge), preserves ignored settings in `config/` and cached modules, and refuses local edits, untracked files or divergent history. No branches are switched and no files are forcibly reset. If an accepted update fails, startup stops and explains the error; resolve it and relaunch, or choose No to open the installed copy. ZIP downloads need to be updated manually. The first installation of this startup updater still requires your usual `git pull`.

Add a tenant with the **+** button — enter a Tenant ID, a verified domain, or a global admin UPN (domains and UPNs are resolved to the tenant automatically), sign in interactively, done. Subsequent launches connect silently.

Use **Dry Run** in the tenant bar to preview destructive actions (password resets, UPN changes, ID assignments) without executing them. It applies to new actions; a request already submitted to Graph cannot be undone. Passwords remain visible in the results and explicit CSV exports, but are excluded from the activity log. CSV exports neutralize spreadsheet formula prefixes.

A live year-group run can be stopped with **Stop**: the account in progress finishes, the run ends, and the summary says how far it got. Batches that outlive their access token keep going — the silent refresh reaches work already running. The app reopens on the tool you used last, and Year Group Passwords reopens on that tenant's last year group.

Press **Ctrl+K** (or the **Search** button in the tenant bar) for global user search — type a name or UPN and jump straight to Password Reset, Devices, Sign-Ins, Licences, or Leaver for that user. Press **F1** for the keyboard shortcut guide. All tools share one cached user list per tenant, so switching tools is instant. The sidebar shows a notice when a newer version is available on GitHub. Navigate tools with Tab, arrow keys, and Enter/Space. The status bar always identifies live, dry-run, or offline demo mode; the tenant toolbar wraps on narrower windows. New installations use Segoe UI, and saved font preferences are preserved. Panel transitions respect Windows animation preferences.

## Permissions

Uses the Microsoft Intune PowerShell public client ID — no app registration required.

| Scope | Purpose |
|-------|---------|
| `User.ReadWrite.All` | Read/update users, change UPNs, set ImmutableId |
| `User-PasswordProfile.ReadWrite.All` | Reset passwords and update sign-in prompt settings |
| `DeviceManagementManagedDevices.Read.All` | Last Device and compliance inventory |
| `DeviceManagementManagedDevices.PrivilegedOperations.All` | Request Intune device sync |
| `AuditLog.Read.All` | Sign-In Logs tab |
| `GroupMember.ReadWrite.All` | Group membership view and Group Copy tab |
| `Group.ReadWrite.All` | Create security groups and add their members |
| `Team.Create` | Create new Teams |
| `TeamMember.ReadWrite.All` | Add members and owners to Teams |
| `SecurityEvents.Read.All` | Secure Score tab |
| `User.RevokeSessions.All` | Leaver Workflow — invalidate active sessions |
| `DeviceManagementConfiguration.Read.All` | Device Compliance — fetch failing policy details |
| `LicenseAssignment.ReadWrite.All` | Licence Assignment — read tenant SKUs, assign/remove licences |

The corrected password-profile and device-sync scopes may require renewed admin consent after upgrading. The signed-in account also needs the appropriate Entra/Intune role.

Security Group Creator also requests admin consent for [`Group.ReadWrite.All`](https://learn.microsoft.com/en-us/graph/api/group-post-groups?view=graph-rest-1.0). It creates standard security groups without email or dynamic membership. CSV files must contain user principal names (for example, `pupil@school.example`); unmatched usernames appear in the activity log. Member additions that fail are reported individually; the created group is kept, with its ID shown, so you can resolve any failures in Entra.

To add devices, use **Find Entra devices**, select one or more results (Ctrl/Shift for multiple), then **Add selected devices**. Devices load in the background; search by name, device ID or Entra object ID, with up to 50 matches shown. The picker shows the OS and object ID to distinguish similarly named devices. **Reload devices** refreshes the list without clearing selected members. Device-only and mixed user/device groups share duplicate prevention, **Clear all**, dry-run and per-member audit results. Device discovery uses Entra directory devices, not Intune managed-device records; CSV import remains user-only. Reconnect after updating and grant admin consent for the additional [`Device.Read.All` permission](https://learn.microsoft.com/en-us/graph/api/group-post-members?view=graph-rest-1.0). If device loading fails, user selection remains available.

## Screenshots

**Year Group Passwords** — bulk password reset for an entire year group with dry-run preview, CSV export, and an optional forced password change on next sign-in.

![Year Group Passwords](assets/screenshot1.png)

**User Password Reset** — reset a single account, regenerate passwords, and toggle forced sign-in prompt.

![User Password Reset](assets/screenshot2.png)

**Sign-In Logs** — browse the last 50 sign-in events for any user with app, result, IP, and location detail.

![Sign-In Logs](assets/screenshot3.png)

**Last Device (By Device)** — look up which users have signed into a specific device, with full sidebar navigation visible.

![Last Device](assets/screenshot4.png)

## License

MIT

## Development checks

Run `pwsh -NoProfile -File tests/Review.Tests.ps1` for offline parser, worker lifecycle and HTTP regression checks. Run `pwsh -NoProfile -File tests/Update.Tests.ps1` for startup prompt, release-note parsing and safe-update checks using temporary Git repositories (requires Git). These run on Windows or Linux without tenant credentials. On Windows, run `pwsh -NoProfile -STA -File tests/Windows.Smoke.ps1` to construct all themed XAML and initialize every tool with demo data. Interactive testing of resizing, scrolling, focus and live Graph operations is still required.

See [REVIEW.md](REVIEW.md) for the code review, validation results and remaining limitations.
