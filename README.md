# Entra Toolbox

A Windows app for managing school Entra ID tenants.

## Download, install and run

1. Install [PowerShell 7](https://aka.ms/powershell).
2. [Download Entra Toolbox](https://github.com/ydap1/EntraToolbox/archive/refs/heads/main.zip) and extract the ZIP to a folder.
3. Open the extracted folder and double-click **Launch.cmd**. The first launch downloads the required sign-in module, so you’ll need an internet connection.
4. Click **+** in the tenant bar, enter your tenant ID, verified domain or admin email, and sign in.

There’s no separate app installer or Azure app registration. Use **Demo** to explore with sample data before connecting a tenant.

> Built for my own school IT workflow. Published for reference; it may not suit yours.

## Tools

- **Users:** account overview, individual and year-group password resets, leaver workflow and group membership restore.
- **Bulk changes:** licence assignment, UPN changes and immutable IDs.
- **Groups & Teams:** copy or reconcile memberships, create security groups with users or devices, and provision Class or Standard Teams.
- **Devices:** Intune device lookup, stale devices, sign-in time reports and compliance details.
- **Reports:** sign-in logs, local change history, bulk results and Microsoft Secure Score.

Multiple tenants, CSV imports and exports, and theme customisation are supported.

## Using the app

Choose a tool from the sidebar. **Ctrl+K** searches users; **F1** opens the shortcut guide. Use **Dry Run** to preview supported changes, and **Bulk Results** to track runs or export failures. Tenant profiles and audit records are saved locally in `config`.

The app checks for updates at launch. ZIP downloads must be updated manually. For automatic updates, install Git and clone the repository instead:

```powershell
git clone https://github.com/ydap1/EntraToolbox.git
cd EntraToolbox
.\Launch.cmd
```

Accept the launch prompt to update a clean clone on `main`.

## Screenshots

<details>
<summary>View screenshots</summary>

![Year Group Passwords](assets/screenshot1.png)
![User Password Reset](assets/screenshot2.png)
![Sign-In Logs](assets/screenshot3.png)
![Last Device](assets/screenshot4.png)

</details>

## License

MIT
