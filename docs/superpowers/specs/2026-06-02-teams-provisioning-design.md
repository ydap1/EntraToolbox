# Teams Provisioning Tab — Design Spec

**Date:** 2026-06-02  
**Status:** Approved

---

## Overview

A new "Teams Provisioning" tab in Art's Entra Toolbox that lets school IT staff create a Microsoft Teams class team or standard team, populate it with members from a year group or via direct user search, assign per-person Owner roles, and track progress in a log.

---

## Architecture & File Structure

### New file
`src/Tools/TeamsProvisioning.ps1` — exposes `Initialize-TeamsProvisioningTool`.

### Changes to existing files

**`src/Auth.ps1`** — add two scopes to `$Script:GraphScopes`:
- `https://graph.microsoft.com/Team.Create`
- `https://graph.microsoft.com/TeamMember.ReadWrite.All`

Users will be re-prompted for consent on next interactive sign-in.

**`src/MainWindow.ps1`**:
- Add `<TabItem x:Name="TabTeams" Header="Teams Provisioning"/>` to the MainWindow XAML TabControl.
- Add `$Script:MainUI.TabTeams = $window.FindName('TabTeams')` to the `$Script:MainUI` hashtable.
- Add `$Script:MainUI.TabTeams.Content = Initialize-TeamsProvisioningTool` in `Show-MainWindow` alongside the other tool initialisations.

**`Start.ps1`** — dot-source `TeamsProvisioning.ps1` after `GroupCopy.ps1`.

---

## UI Layout

### Sidebar (260 px, scrollable, `#1C1C2A` background)

Four labelled sections using the existing `SectionLbl` style:

**TEAM DETAILS**
- `TextBox` — team name (manual, required)
- Radio buttons: `Class Team` / `Standard Team` (GroupName `tptype`)

**POPULATION**
- Radio buttons: `Year Group` / `Direct Users` (GroupName `tppop`)
- *When Year Group selected:* `ComboBox` of year groups (same `Get-DeptGroup` logic as PasswordReset) + "Load Students" button
- *When Direct Users selected:* search `TextBox` + `ListBox` of filtered results; clicking a result adds the user to the Members grid (duplicates silently skipped)

**SELECTION**
- "X of Y members" label
- "All" / "None" buttons

**ACTIONS**
- "Create Team" button (accent `#6366F1`), disabled until name is non-empty and at least one member is in the grid
- Stats panel (post-creation): `Team Created`, `Members Added`, `Members Failed`

### Right panel — two sub-tabs

**Members tab** — `DataGrid` columns:
| Column | Binding | Notes |
|---|---|---|
| Display Name | `DisplayName` | `DataGridTextColumn` with `IsReadOnly="True"`, sortable |
| UPN | `UPN` | `DataGridTextColumn` with `IsReadOnly="True"`, sortable |
| Department | `Department` | `DataGridTextColumn` with `IsReadOnly="True"`, sortable |
| Owner | `IsOwner` | `DataGridTemplateColumn` with an interactive `CheckBox`; unchecked = Member, checked = Owner |

The `DataGrid` element itself uses `IsReadOnly="False"` (unlike other tools) so the Owner checkbox is interactive. Text columns are individually `IsReadOnly="True"` to prevent editing.

Multi-row selection enabled (same as PasswordReset grid).

**Log tab** — `RichTextBox` (Consolas, timestamped lines, same pattern as all other tools).

---

## Data Flow & Async Pattern

All background work uses the established runspace + `DispatcherTimer` polling pattern.

### On connect (`$Script:ConnectCallbacks`)
`Start-TpUserLoad` fires. Background runspace fetches all enabled users:
```
GET /v1.0/users?$select=id,displayName,userPrincipalName,department&$filter=accountEnabled eq true&$top=999
```
On completion: populates `$Script:TP_AllUsers`, builds year group dropdown entries.

### Year group mode — Load Students
Synchronous (data already in memory). Filters `$Script:TP_AllUsers` by `Get-DeptGroup`, clears the Members grid, then populates it with `IsOwner = $false` for all rows.

### Direct user mode — search
Client-side filter of `$Script:TP_AllUsers` on `displayName` or `userPrincipalName` as the user types. Clicking a result appends a row to the grid (duplicate check by user ID). Switching from Year Group mode to Direct Users mode (or vice versa) clears the Members grid.

### Team creation (Create Team button)
Background runspace, steps logged to the Log tab:

1. **POST** `/v1.0/teams` with body:
   ```json
   {
     "template@odata.bind": "https://graph.microsoft.com/v1.0/teamsTemplates('educationClass')",
     "displayName": "<team name>",
     "members": [{ "@odata.type": "#microsoft.graph.aadUserConversationMember", "roles": ["owner"], "user@odata.bind": "https://graph.microsoft.com/v1.0/users('<admin-id>')" }]
   }
   ```
   For a standard team, `teamsTemplates('standard')` is used instead.  
   Graph returns `202 Accepted` with a `Location` header.

2. **Poll** the `Location` URL every 3 seconds until the response contains a `teamsAsyncOperation` with `status: succeeded` (or up to 30 polls / 90 seconds). Extract the `targetResourceId` (team ID) from the operation response.

3. **Add members** in sequential `POST /v1.0/teams/{teamId}/members` calls. Each user gets:
   - `roles: ["owner"]` if `IsOwner = $true`
   - `roles: []` (member) otherwise
   Failures are caught per-user and logged.

4. **Update UI** on the dispatcher thread: show stats panel, re-enable controls.

---

## Error Handling

| Scenario | Behaviour |
|---|---|
| Provisioning timeout (>90s) | Log warning with team ID; admin checks Teams admin centre manually |
| Individual member add failure | Logged as error; counted in "Members Failed" stat; team not rolled back |
| 401 Unauthorized | Log error with message to re-authenticate; no retry |
| Duplicate user added in Direct mode | Silently skipped (checked by user ID before adding to grid) |
| Create pressed with empty name | Button remains disabled — never reaches this state |

---

## Demo Mode

`Start-TpUserLoad` calls `Start-TpUserLoadDemo`, which injects ~30 fake Contoso Academy users with departments into `$Script:TP_AllUsers`.

The Create Team button in demo mode skips all Graph calls, simulates a 3-second delay via a timer, and logs success for all members.

---

## Scopes Required

| Scope | Purpose |
|---|---|
| `Team.Create` | Create new teams |
| `TeamMember.ReadWrite.All` | Add members and owners to teams |
| `User.ReadWrite.All` | Already present — user lookup |
| `GroupMember.ReadWrite.All` | Already present — underlying M365 group membership |

---

## Out of Scope

- Editing or deleting existing teams
- Archiving teams
- Channels management
- Adding guests or external users
