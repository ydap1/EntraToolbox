# Entra Toolbox

## Download, install and run

On Windows, install Git and [PowerShell 7](https://aka.ms/powershell), then run:

```powershell
git clone https://github.com/ydap1/EntraToolbox.git
cd EntraToolbox
.\Launch.cmd
```

The first launch downloads the required sign-in module, so you’ll need an internet connection. Click **+** in the tenant bar, enter your tenant ID, verified domain or admin email, and sign in. For later launches, double-click **Launch.cmd** in the cloned folder.

There’s no separate app installer or Azure app registration. Use **Demo** to explore with sample data before connecting a tenant.

> Built for my own school IT workflow. Published for reference; it may not suit yours.

## Tools

- **Users:** account overview, individual password resets and bulk resets by year group, department or office location, leaver workflow and group membership restore.
- **Bulk changes:** licence assignment, UPN changes and immutable IDs.
- **Groups & Teams:** copy or reconcile memberships, create security groups with users or devices, and provision Class or Standard Teams. Creation errors show Graph’s explanation.
- **Devices:** Intune device lookup, stale devices, sign-in time reports and compliance details.
- **Reports:** sign-in logs, local change history, bulk results and Microsoft Secure Score.

Multiple tenants, CSV imports and exports, and theme customisation are supported.

## Using the app

Choose a tool from the sidebar. **Ctrl+K** searches users; **F1** opens the shortcut guide. Use **Dry Run** to preview supported changes, and **Bulk Results** to track runs or export failures. Tenant profiles and audit records are saved locally in `config`.

The app checks for updates at launch. Accept the prompt to update a clean clone on `main`.

If Git history has diverged, the updater stops without changing app files. Back up local work before realigning your checkout, or clone into a new folder and copy your `config` folder across.

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
