# Code review — 6 September 2026

Reviewed the application source, startup/dependency loading, shared authentication and Graph helpers, all tool implementations, demo data, embedded XAML, and existing documentation. The starting point was v0.19.0 (`1942bc5`). Changes are on `improvement/code-review`, through v0.20.1.

The PowerShell/WPF architecture and existing tools are retained. Classroom passwords remain the default, as requested. This is a source review and an offline validation pass, not a certification of live tenant behavior.

## Findings addressed

| Priority | Finding | Change |
|---|---|---|
| High | Stopping a dispatcher timer did not stop its pipeline or release its runspace. Tenant switches could leave operations running. | A worker registry cancels stopped/superseded jobs asynchronously, disposes completed resources, and cancels session work on switch, disconnect, and shutdown. Cancellation cannot undo a request already accepted by Graph. |
| High | An old authentication or token-refresh completion could write into the current tenant's state. | Session generations reject stale completions, including token refresh. Closing an active sign-in dialog cancels its work. |
| High | Pagination and Teams operation URLs were followed with bearer credentials without destination validation. | Authenticated HTTP requests require HTTPS on `graph.microsoft.com`, port 443, without URI credentials. Redirects are disabled. |
| High | Transient-error retry policy replayed writes as well as reads. A server can complete a write before a gateway returns an error. | Reads retry transient 502/503/504 responses; writes only retry explicit throttling. Retry-After supports both durations and HTTP dates without shortening the server's delay. |
| High | Dry-run logs included generated passwords; CSV quoting did not neutralize spreadsheet formulas in directory values. | Passwords are omitted from activity logs. CSV text with formula prefixes is escaped; ordinary passwords and numeric fields are preserved. Explicit password exports still contain plaintext passwords. |
| Medium | Single-user password resets performed synchronous HTTP on the WPF thread. Dry runs then displayed a successful reset and changed the displayed prompt state. | Resets run in a background worker with a captured account/password/force-change setting. Dry/demo actions explicitly report no changes and leave the actual prompt status alone. The worker receives the PasswordBox's SecurePassword value. |
| Medium | Late detail responses could overwrite a newly selected or deselected user/device. | Detail results carry their requested ID and are ignored if the selection changed. Clearing a Group Copy selection clears its stored source/target as well. |
| Medium | Worker cmdlet errors could be nonterminating and leave a success-looking result. | Background pipelines use terminating errors so the existing error path receives failures. Invalid conditional command arguments in progress logging were also corrected. |
| Medium | Device sync requested the wrong permission; password-profile updates lacked their dedicated scope. | Request the documented password-profile and Intune privileged-operation scopes. Replace unnecessary managed-device ReadWrite permission with Read permission. This changes the consent request; no tenant consent was granted during this review. |
| Medium | Licence details, subscribed SKUs, and compliance policies used only the first response page. | A shared collection reader follows every page and detects repeated pagination links. |
| Medium | Last Device downloaded the entire Intune inventory for every selected user, alongside another download for the device browser. | User lookups filter the existing per-connection inventory on a worker. The device browser and user lookup share the download. |
| Medium | Directory lists created a ListBoxItem for every account, defeating UI virtualization. | Eight user/device lists bind plain data rows. The shared template enables content scrolling, pixel scrolling, and container recycling. Existing Tag/Content selection behavior is preserved. |
| Medium | Demo licence/leaver/sync actions could reach the network; a demo SKU loader reference did not exist. | Those actions stay offline, the missing loader call is removed, and the HTTP gateway rejects the demo bearer token. |
| Medium | Group Copy attempted dynamic and role-assignable memberships; partial failures could have a success-colored summary. | Managed/privileged memberships are skipped. Group Copy and Leaver Workflow use warning summaries for partial failures. Licence operations log the original target and reject zero-seat assignments. |
| Medium | Runtime bootstrap accepted a module directory even if installation was incomplete and could download a different dependency version. | Pin the existing MSAL.PS 4.37.0.0 dependency, check its manifest, and use that version in authentication workers. |

## Interface changes

Navigation now uses compact, focusable buttons with arrow/Home/End navigation and Enter/Space activation. Descriptions move into tooltips and a clear heading above the active tool. The tenant toolbar wraps rather than clipping at smaller widths, and the status bar always identifies disconnected, live, dry-run, or offline demo state.

New installations use Segoe UI; existing font choices and theme choices remain supported. Secondary text has better contrast, and accent-filled buttons select black or white text using luminance. Saved font names are XML-escaped. The navigation transition is a short, subtle fade that respects the Windows animation setting and releases its animation afterward. Search restores focus when dismissed and works with demo data.

The Windows launch/restart commands explicitly use an STA thread. Linux startup exits before attempting to download GUI dependencies.

## Validation

`pwsh -NoProfile -File tests/Review.Tests.ps1` passes on PowerShell 7.6.5 under Linux. It exercises real PowerShell runspaces and a loopback HTTP server; the dispatcher is substituted for the lifecycle tests. No tenant credentials or live directory operations are used.

Checks cover source parsing, all 15 XAML documents after theme substitution, demo loader references, classroom password format, CSV escaping, dry-run reporting, stale selection/session results, worker disposal/error propagation, captured dry-run policy, credential destination restrictions, Retry-After handling, response-header propagation, ambiguous writes, and collection pagination. XAML XML parsing does **not** prove that WPF can instantiate or render every control.

PSScriptAnalyzer was run across the source. Its error-level findings introduced during the changes were corrected. Remaining warnings largely concern the intentional GUI architecture: shared script/global state, a wrapper named Invoke-RestMethod, GUI actions without ShouldProcess, existing empty catch blocks, unused event arguments, naming conventions, and UTF-8 files without a BOM. PowerShell 7 is required; warnings were not hidden with blanket suppressions.

`tests/Windows.Smoke.ps1` was added and syntax-checked, but **has not been executed here**. Run it on Windows:

```powershell
pwsh -NoProfile -STA -File tests/Windows.Smoke.ps1
```

It constructs the embedded XAML for each theme, initializes all tools with demo data, and exercises layout at three widths without authenticating. Then test `Launch.cmd` interactively: resize at 900/1280/1600 px and high DPI; navigate by keyboard; scroll a large directory; switch tenants during reads; close during a worker operation; cancel a sign-in; compare dry-run and live behavior using disposable test accounts; and check consent, password reset, licences, sync, and Teams provisioning. Confirm that switching tenants prevents subsequent requests from the canceled job while recognizing that a request already submitted may still finish server-side.

No Windows rendering screenshots, live Graph tests, or real-tenant performance measurements were produced in this environment. The README screenshots predate these UI changes.

## Remaining limitations and follow-up

- **Classroom password strength is an accepted tradeoff.** The unchanged word lists and two-digit suffix provide 26³ × 90 = 1,581,840 combinations, about 20.6 bits. Unbiased cryptographic random selection improves the generator but does not increase that space. The requested classroom format remains the default; use an appropriate tenant policy and account context for it.
- **Consent and tenant roles need a live check.** The application still uses the existing Microsoft public client and requests a combined set of tool permissions at sign-in. Per-tool incremental consent or an organization-owned app registration would be a separate authentication design change. No privileged consent was performed here.
- **Long batches capture a token when they start.** The application refreshes the foreground session, but a single batch running past its captured token's expiry can still fail with 401. This needs a per-session token provider if hour-long batches are required.
- **Inventory and directory data are snapshots.** Reconnect to refresh the shared inventory. Some mutations do not refresh every already-open tool's cached view. Intune usersLoggedOn exports contain the latest recorded user/device sign-ins, not a complete 90-day audit trail.
- **Token-cache writes are not coordinated across multiple app instances.** The cache is DPAPI-encrypted, but concurrent writes or interruption can lose the cache and require another sign-in. Cross-process locking and atomic replacement remain follow-up work.
- **The dependency was pinned, not upgraded.** MSAL.PS and its bundled identity library still need a dedicated maintenance/compatibility review before changing the authentication stack.
- **WPF styling is still duplicated across tools.** This pass fixes shared behavior and the shell without replacing every tool template. Large action panels, high-DPI layouts, screen-reader behavior, and the remaining custom detail lists need Windows validation before a release.

README.md and this review describe the current work. Older local HANDOVER.md/NOTES.md content describes earlier versions and should not override the current source or test results.

## References checked

- [Microsoft Graph throttling guidance](https://learn.microsoft.com/en-us/graph/throttling): follow the server's Retry-After delay.
- [WPF control performance](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/optimizing-performance-controls): explicit item containers and disabled content scrolling prevent virtualization.
- [Intune syncDevice permissions](https://learn.microsoft.com/en-us/graph/api/intune-devices-manageddevice-syncdevice?view=graph-rest-1.0): DeviceManagementManagedDevices.PrivilegedOperations.All.
- [Update user permissions](https://learn.microsoft.com/en-us/graph/api/user-update?view=graph-rest-1.0): password-profile permission and role requirements.
- [Assign licences](https://learn.microsoft.com/en-us/graph/api/user-assignlicense?view=graph-rest-1.0): licence assignment permission and supported administrator roles.
