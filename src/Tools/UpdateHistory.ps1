<#
    UpdateHistory.ps1 — in-app version changelog panel.
    Dot-sourced by Start.ps1.
    Exposes: Initialize-UpdateHistoryTool

    No Graph calls. Purely code-behind WPF built from $Script:IH_History.
    Add a new entry at the top of IH_History each time a version ships.
#>

# ── Version history ────────────────────────────────────────────────────────────
$Script:IH_History = @(
    @{
        Version = '0.14.0'
        Date    = '2026-07-02'
        Changes = @(
            'Reliability: every Graph call now retries automatically on throttling (429, honouring Retry-After) and transient server errors (502/503/504) with exponential backoff'
            'Reliability: the access token is refreshed silently in the background before it expires — long sessions no longer fail with "session expired"'
            'UI: tool panels fade in when switching; text rendering is crisper (display-mode formatting and layout rounding)'
            'UI: connecting no longer freezes the window while the tenant name loads'
            'UI: tenant badge tooltip shows the tenant ID and signed-in account'
            'UI: Add Tenant dialog — Enter connects, Esc cancels'
            'UI: Ctrl+L toggles the activity log pane; window title now shows the version'
        )
    }
    @{
        Version = '0.13.0'
        Date    = '2026-06-30'
        Changes = @(
            'Last Device (By User): compliance dot (green/red/grey) on each device in the list'
            'Last Device (By User): detail bar now shows serial number, OS version, and last Intune sync alongside model'
            'Last Device (By User): Sync Device button requests an immediate Intune sync for the selected device'
            'Last Device (Stale Devices): Model column added to the grid'
            'Last Device (Stale Devices): Export Report (CSV) button added'
            'Auth: upgraded to DeviceManagementManagedDevices.ReadWrite.All scope (re-auth required)'
        )
    }
    @{
        Version = '0.12.3'
        Date    = '2026-06-30'
        Changes = @(
            'Last Device (By User): device detail bar now shows the model alongside the last sign-in timestamp'
        )
    }
    @{
        Version = '0.12.2'
        Date    = '2026-06-23'
        Changes = @(
            'Last Device reports: de-duplicate users per device so each user is listed once (most recent sign-in)'
        )
    }
    @{
        Version = '0.12.1'
        Date    = '2026-06-23'
        Changes = @(
            'Last Device (By Device) report: added Model and Serial Number columns'
            'Users are now listed one-per-line within the cell so devices with many users stay readable'
        )
    }
    @{
        Version = '0.12.0'
        Date    = '2026-06-23'
        Changes = @(
            'Last Device (By Device): new "Export Report (CSV)" button — one row per Intune device listing the users that signed into it (with user count, last sign-in, and last check-in) over the past 3 months'
            'Last Device (By User): report window extended from 1 month to 3 months'
        )
    }
    @{
        Version = '0.11.0'
        Date    = '2026-06-23'
        Changes = @(
            'Last Device (By User): new "Export Report (CSV)" button — exports every device and the users that signed into it within the past month'
        )
    }
    @{
        Version = '0.10.0'
        Date    = '2026-06-15'
        Changes = @(
            'New tool: Leaver Workflow — disable account, revoke sign-in sessions, and remove from all groups in one click'
            'New tool: Device Compliance — overview of all Intune device compliance states with per-device failing policy breakdown'
            'New tool: Licence Assignment — view, assign, and remove Microsoft 365 licence SKUs per user'
            'New Graph scopes: User.RevokeSessions.All, DeviceManagementConfiguration.Read.All, LicenseAssignment.ReadWrite.All'
        )
    }
    @{
        Version = '0.9.4'
        Date    = '2026-06-11'
        Changes = @(
            'New tool: Secure Score — tenant Microsoft Secure Score with percentage headline, threshold guide, and per-control breakdown table'
            'New Graph scope added: SecurityEvents.Read.All'
        )
    }
    @{
        Version = '0.9.3'
        Date    = '2026-06-09'
        Changes = @(
            'Password is now hidden behind asterisks by default in User Password Reset — use the Show/Hide toggle to reveal it'
            'Clicking Regenerate always re-masks the password'
        )
    }
    @{
        Version = '0.9.2'
        Date    = '2026-06-09'
        Changes = @(
            'Password stays visible after resetting so you can copy it — click Regenerate to get a new one'
        )
    }
    @{
        Version = '0.9.1'
        Date    = '2026-06-05'
        Changes = @(
            'App starts faster — tools are now loaded only when you first open them rather than all at once on startup'
            'Password reset runs in the background during live runs, so the window stays responsive while changes are applied'
            'Searching for users in Bulk UPN Change no longer lags on large tenants'
            'Activity log no longer grows without limit during long sessions'
        )
    }
    @{
        Version = '0.9.0'
        Date    = '2026-06-05'
        Changes = @(
            'Added this Update History screen so you can see what changed in each version'
            'Version number now shown at the bottom of the sidebar'
        )
    }
    @{
        Version = '0.8.0'
        Date    = '2026-06-05'
        Changes = @(
            'Immutable ID: you can now remove an existing Immutable ID from a user — useful when correcting a bad sync anchor'
            'Immutable ID: removal requires typing YES in a confirmation box to prevent accidents'
        )
    }
    @{
        Version = '0.7.0'
        Date    = '2026-06-05'
        Changes = @(
            'Bulk UPN Change: pick a department from the dropdown and add everyone in it to the change list in one click'
            'Bulk UPN Change: same quick-add by office location'
        )
    }
    @{
        Version = '0.6.0'
        Date    = '2026-06-05'
        Changes = @(
            'Activity log pane at the bottom of the window — shows exactly what the app is doing in real time'
            'Dry Run toggle in the toolbar — see what would change before committing to any action'
        )
    }
    @{
        Version = '0.5.0'
        Date    = '2026-06-05'
        Changes = @(
            'Navigation redesigned as a sidebar with tools grouped into categories'
            'Bulk UPN Change — rename users to a different email domain in bulk'
            'Immutable ID — assign an AD Connect sync anchor to cloud-only accounts, with per-row selection'
        )
    }
    @{
        Version = '0.4.0'
        Date    = '2026-06-02'
        Changes = @(
            'Teams Provisioning — create a Class or Staff team, add members by year group or by searching for users, and promote specific people to Owner'
        )
    }
    @{
        Version = '0.3.0'
        Date    = '2026-06-01'
        Changes = @(
            'Group Copy — copy every group membership from one user to another with a single click'
            'The app now stays signed in between restarts — no need to sign in again unless your session has expired'
        )
    }
    @{
        Version = '0.2.0'
        Date    = '2026-05-13'
        Changes = @(
            'Sign-In Logs — view the last 50 sign-ins for any user, including app name, result, IP address and location'
            'User Password Reset — reset a single user''s password and view their current group memberships'
            'Year Group Passwords — rows are now sortable and you can select multiple at once with Select All / None'
            'Demo mode — try the app with sample Contoso Academy data without connecting to a real tenant'
        )
    }
    @{
        Version = '0.1.0'
        Date    = '2026-05-12'
        Changes = @(
            'Initial release'
            'Year Group Passwords — bulk-reset passwords for an entire year group, with dry-run preview and CSV export'
            'Last Device — find the last Intune-enrolled device for any user or search by device name; filter for stale devices'
            'Connect multiple school tenants and switch between them — sign-in credentials are saved between sessions'
        )
    }
)

# ── Build WPF panel ────────────────────────────────────────────────────────────
function Initialize-UpdateHistoryTool {
    $bc = [System.Windows.Media.BrushConverter]::new()
    function IH-Brush([string]$h) { $bc.ConvertFromString($h) }
    function IH-Thick([double]$l, [double]$t, [double]$r, [double]$b) {
        [System.Windows.Thickness]::new($l, $t, $r, $b)
    }

    $root = [System.Windows.Controls.Grid]::new()
    $root.Background = IH-Brush '#12121C'

    $scroll = [System.Windows.Controls.ScrollViewer]::new()
    $scroll.VerticalScrollBarVisibility   = 'Auto'
    $scroll.HorizontalScrollBarVisibility = 'Disabled'
    [void]$root.Children.Add($scroll)

    $outer = [System.Windows.Controls.StackPanel]::new()
    $outer.Margin = IH-Thick 28 20 28 28
    $scroll.Content = $outer

    # ── Title ──────────────────────────────────────────────────────────────────
    $h1           = [System.Windows.Controls.TextBlock]::new()
    $h1.Text      = 'Update History'
    $h1.Foreground = IH-Brush '#E2E2F0'
    $h1.FontSize  = 22
    $h1.FontWeight = [System.Windows.FontWeights]::Bold
    $h1.Margin    = IH-Thick 0 0 0 4
    [void]$outer.Children.Add($h1)

    $sub           = [System.Windows.Controls.TextBlock]::new()
    $sub.Text      = "Art's Entra Toolbox — version changelog"
    $sub.Foreground = IH-Brush '#50507A'
    $sub.FontSize  = 12
    $sub.Margin    = IH-Thick 0 0 0 24
    [void]$outer.Children.Add($sub)

    # ── One card per version ───────────────────────────────────────────────────
    foreach ($entry in $Script:IH_History) {
        $card                  = [System.Windows.Controls.Border]::new()
        $card.Background       = IH-Brush '#1C1C2A'
        $card.CornerRadius     = [System.Windows.CornerRadius]::new(8)
        $card.BorderBrush      = IH-Brush '#2E2E4A'
        $card.BorderThickness  = [System.Windows.Thickness]::new(1)
        $card.Padding          = IH-Thick 18 14 18 14
        $card.Margin           = IH-Thick 0 0 0 12

        $cs = [System.Windows.Controls.StackPanel]::new()

        # Header row: badge + date
        $hg = [System.Windows.Controls.Grid]::new()
        $c0 = [System.Windows.Controls.ColumnDefinition]::new()
        $c0.Width = [System.Windows.GridLength]::Auto
        $c1 = [System.Windows.Controls.ColumnDefinition]::new()
        $c1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        $c2 = [System.Windows.Controls.ColumnDefinition]::new()
        $c2.Width = [System.Windows.GridLength]::Auto
        [void]$hg.ColumnDefinitions.Add($c0)
        [void]$hg.ColumnDefinitions.Add($c1)
        [void]$hg.ColumnDefinitions.Add($c2)

        # Version badge
        $badge                = [System.Windows.Controls.Border]::new()
        $badge.Background     = IH-Brush '#6366F1'
        $badge.CornerRadius   = [System.Windows.CornerRadius]::new(4)
        $badge.Padding        = IH-Thick 8 3 8 3
        $badge.VerticalAlignment = 'Center'
        $vt                   = [System.Windows.Controls.TextBlock]::new()
        $vt.Text              = "v$($entry.Version)"
        $vt.Foreground        = [System.Windows.Media.Brushes]::White
        $vt.FontWeight        = [System.Windows.FontWeights]::Bold
        $vt.FontSize          = 13
        $badge.Child          = $vt
        [System.Windows.Controls.Grid]::SetColumn($badge, 0)
        [void]$hg.Children.Add($badge)

        # Date
        $dt                    = [System.Windows.Controls.TextBlock]::new()
        $dt.Text               = $entry.Date
        $dt.Foreground         = IH-Brush '#50507A'
        $dt.FontSize           = 11
        $dt.VerticalAlignment  = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($dt, 2)
        [void]$hg.Children.Add($dt)

        [void]$cs.Children.Add($hg)

        # Separator
        $sep = [System.Windows.Controls.Border]::new()
        $sep.Height     = 1
        $sep.Background = IH-Brush '#2E2E4A'
        $sep.Margin     = IH-Thick 0 10 0 10
        [void]$cs.Children.Add($sep)

        # Bullet items
        foreach ($change in $entry.Changes) {
            $bt               = [System.Windows.Controls.TextBlock]::new()
            $bt.Text          = [char]0x2022 + "  $change"
            $bt.Foreground    = IH-Brush '#C2C2E0'
            $bt.FontSize      = 12
            $bt.TextWrapping  = 'Wrap'
            $bt.Margin        = IH-Thick 0 2 0 2
            [void]$cs.Children.Add($bt)
        }

        $card.Child = $cs
        [void]$outer.Children.Add($card)
    }

    return $root
}
