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
        Version = '0.9.0'
        Date    = '2026-06-05'
        Changes = @(
            'Added in-app Update History tab (this panel)'
            'Updated CLAUDE.md with comprehensive architecture and workflow documentation'
            'README updated to include all current tools'
            'Version number now tracked in version.txt and displayed in the nav sidebar'
            'Added rule: version must be bumped and README updated with every change'
        )
    }
    @{
        Version = '0.8.0'
        Date    = '2026-06-05'
        Changes = @(
            'ImmutableId: added Remove ImmutableId from selected button'
            'ImmutableId: removal requires typing YES to confirm, skipped in dry-run mode'
            'ImmutableId: Removed status shown in slate colour in the grid'
            'ImmutableId: updated nav description to "Assign immutable ID to user"'
        )
    }
    @{
        Version = '0.7.0'
        Date    = '2026-06-05'
        Changes = @(
            'Bulk UPN Change: import by department — Add All button adds every user in that department'
            'Bulk UPN Change: import by office location — same pattern'
            'Fetches department and officeLocation from Graph alongside existing user fields'
            'Sidebar mirrors Year Group Passwords group-import design'
        )
    }
    @{
        Version = '0.6.0'
        Date    = '2026-06-05'
        Changes = @(
            'Global activity log pane — collapsible slide-up panel shared across all tools'
            'Dry-run toggle in tenant bar — logs planned actions without executing them'
            'All per-tool log boxes removed; Write-AppLog routes to the single global pane'
            'BtnLog and BtnClearLog added to tenant bar'
        )
    }
    @{
        Version = '0.5.0'
        Date    = '2026-06-05'
        Changes = @(
            'Vertical navigation sidebar replaces the flat tab bar'
            'Nav items grouped into categories: USERS, DEVICES, AUDIT, GROUPS & TEAMS'
            'Bulk UPN Change tool: move cloud-only users to a different verified domain'
            'Immutable ID tool: assign onPremisesImmutableId with per-row checkboxes'
        )
    }
    @{
        Version = '0.4.0'
        Date    = '2026-06-02'
        Changes = @(
            'Shared async helper Start-AsyncWork used across all tools'
            'Write-RichLog / Write-AppLog consistent log output'
            'Teams Provisioning: create Class or Standard teams and assign members by year group or search'
            'Token cache compiled C# helper fixes interactive auth on PS7'
        )
    }
    @{
        Version = '0.3.0'
        Date    = '2026-06-01'
        Changes = @(
            'Group Copy: copy all group memberships from one user to another in one click'
            'Persistent MSAL token cache — no re-authentication across application restarts'
            'Silent re-auth on startup; MFA claims challenge forwarded to interactive flow'
            'Multi-tenant: account hint saved per tenant for seamless switching'
        )
    }
    @{
        Version = '0.2.0'
        Date    = '2026-05-13'
        Changes = @(
            'Sign-In Logs: last 50 sign-ins per user — app, result, IP, location, device'
            'User Password Reset: single-account reset with live group membership view'
            'Year Group Passwords: Select All / None, sortable columns, multi-select'
            'Demo mode with fake Contoso Academy tenant — no live credentials needed'
            'MSAL.PS auto-installed on first run'
        )
    }
    @{
        Version = '0.1.0'
        Date    = '2026-05-12'
        Changes = @(
            'Initial release'
            'Year Group Passwords: bulk password reset by department with CSV export'
            'Last Device: Intune lookup by user or device, stale device filter, Time Logs sub-tab'
            'MSAL auth using the Microsoft Intune public client ID — no app registration needed'
            'Multi-tenant support with profiles saved to config\tenants.json'
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
