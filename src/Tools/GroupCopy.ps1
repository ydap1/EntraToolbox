<#
    Group Copy tab for Art's Entra Toolbox.
    Dot-sourced by Start.ps1.
    Exposes Initialize-GroupCopyTool.

    Copies direct security/M365 group memberships from a source user to a target
    user. Groups the target already belongs to are silently skipped.
    The source user's memberships are never modified.
#>

$Script:GC_UI           = $null
$Script:GC_AllUsers     = @()
$Script:GC_SourceUser   = $null
$Script:GC_TargetUser   = $null
$Script:GC_SourceGroups = @()

$Script:GC_UserTimer    = $null
$Script:GC_SrcGrpTimer  = $null
$Script:GC_CopyTimer    = $null

# ── Log helper ─────────────────────────────────────────────────────────────────
function Write-GcLog {
    param([string]$Msg, [string]$Color = 'TextDim')
    Write-AppLog $Msg $Color
}

# ── Async user load ────────────────────────────────────────────────────────────
function Start-GcUserLoad {
    if ($Script:DemoMode) { Start-GcUserLoadDemo; return }

    $Script:GC_UI.SrcSearch.IsEnabled = $false
    $Script:GC_UI.SrcList.IsEnabled   = $false
    $Script:GC_UI.TgtSearch.IsEnabled = $false
    $Script:GC_UI.TgtList.IsEnabled   = $false
    Write-GcLog 'Fetching users from Entra ID...' 'TextDim'

    if ($Script:GC_UserTimer) { $Script:GC_UserTimer.Stop() }
    $Script:GC_UserTimer = Start-AsyncWork -RefSeed @{ Users = $null } -Script {
        $users = [System.Collections.Generic.List[object]]::new()
        $url   = 'https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName&$top=999&$filter=accountEnabled eq true'
        do {
            $resp = Invoke-RestMethod -Uri $url `
                -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
            foreach ($u in $resp.value) { $users.Add($u) }
            $url = $resp.'@odata.nextLink'
        } while ($url)
        $Ref['Users'] = $users.ToArray()
    } -OnComplete {
        param($ref)
        try {
            if ($ref['Error'] -eq '401') {
                Write-GcLog 'Session expired - reconnect via the tenant selector.' 'Danger'
                Set-MainStatus 'Session expired.' 'Danger'
                return
            }
            if ($ref['Error']) {
                Write-GcLog "Error loading users: $($ref['Error'])" 'Danger'
                Set-MainStatus 'Failed to load users.' 'Danger'
                return
            }

            $Script:GC_AllUsers = @($ref['Users'] | Sort-Object { $_.displayName })
            Update-GcSrcFilter
            Update-GcTgtFilter
            $Script:GC_UI.SrcSearch.IsEnabled = $true
            $Script:GC_UI.SrcList.IsEnabled   = $true
            $Script:GC_UI.TgtSearch.IsEnabled = $true
            $Script:GC_UI.TgtList.IsEnabled   = $true
            $n = $Script:GC_AllUsers.Count
            Write-Log "GC: loaded $n users" 'INFO'
            Write-GcLog "Loaded $n users." 'Success'
            Set-MainStatus "Loaded $n users." 'Success'
        } catch {
            Write-Log "GC user-load timer error: $_" 'ERROR'
        }
    }
}

function Update-GcSrcFilter {
    $filter = $Script:GC_UI.SrcSearch.Text.Trim()
    $Script:GC_UI.SrcList.Items.Clear()
    $list = if ([string]::IsNullOrWhiteSpace($filter)) { $Script:GC_AllUsers } else {
        $Script:GC_AllUsers | Where-Object {
            $_.displayName -like "*$filter*" -or $_.userPrincipalName -like "*$filter*"
        }
    }
    foreach ($u in $list) {
        $lbi         = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Content = $u.displayName
        $lbi.Tag     = $u
        $lbi.ToolTip = $u.userPrincipalName
        [void]$Script:GC_UI.SrcList.Items.Add($lbi)
    }
}

function Update-GcTgtFilter {
    $filter = $Script:GC_UI.TgtSearch.Text.Trim()
    $Script:GC_UI.TgtList.Items.Clear()
    $list = if ([string]::IsNullOrWhiteSpace($filter)) { $Script:GC_AllUsers } else {
        $Script:GC_AllUsers | Where-Object {
            $_.displayName -like "*$filter*" -or $_.userPrincipalName -like "*$filter*"
        }
    }
    foreach ($u in $list) {
        $lbi         = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Content = $u.displayName
        $lbi.Tag     = $u
        $lbi.ToolTip = $u.userPrincipalName
        [void]$Script:GC_UI.TgtList.Items.Add($lbi)
    }
}

# ── Load source user's direct group memberships ────────────────────────────────
function Start-GcSourceGroupLoad {
    param([string]$UserId)
    if ($Script:DemoMode) { Start-GcSourceGroupLoadDemo -UserId $UserId; return }

    $Script:GC_SourceGroups = @()
    $Script:GC_UI.GrpList.Items.Clear()
    $Script:GC_UI.GrpList.Visibility        = 'Collapsed'
    $Script:GC_UI.GrpPlaceholder.Text       = 'Loading groups...'
    $Script:GC_UI.GrpPlaceholder.Visibility = 'Visible'
    $Script:GC_UI.GrpHeader.Text            = 'Loading source user groups...'
    $Script:GC_UI.BtnCopy.IsEnabled         = $false

    if ($Script:GC_SrcGrpTimer) { $Script:GC_SrcGrpTimer.Stop() }
    $Script:GC_SrcGrpTimer = Start-AsyncWork `
        -Vars    @{ UserId = $UserId } `
        -RefSeed @{ Groups = $null } `
        -Script {
            $groups = [System.Collections.Generic.List[object]]::new()
            $url = "https://graph.microsoft.com/v1.0/users/$UserId/memberOf?`$select=id,displayName,groupTypes&`$top=999"
            do {
                $resp = Invoke-RestMethod -Uri $url `
                    -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
                foreach ($g in $resp.value) {
                    if ($g.'@odata.type' -eq '#microsoft.graph.group') { $groups.Add($g) }
                }
                $url = $resp.'@odata.nextLink'
            } while ($url)
            $Ref['Groups'] = $groups.ToArray()
        } -OnComplete {
            param($ref)
            try {
                if ($ref['Error'] -eq '401') {
                    $Script:GC_UI.GrpPlaceholder.Text = 'Session expired - reconnect.'
                    return
                }
                if ($ref['Error']) {
                    Write-Log "GC: source group load failed - $($ref['Error'])" 'ERROR'
                    $Script:GC_UI.GrpPlaceholder.Text = "Error: $($ref['Error'])"
                    return
                }

                $Script:GC_SourceGroups = @($ref['Groups'] | Sort-Object { $_.displayName })
                $n = $Script:GC_SourceGroups.Count
                Write-Log "GC: loaded $n source groups" 'INFO'

                if ($n -eq 0) {
                    $Script:GC_UI.GrpHeader.Text      = 'Source user has no group memberships'
                    $Script:GC_UI.GrpPlaceholder.Text = 'No groups to copy.'
                    return
                }

                $Script:GC_UI.GrpHeader.Text            = "$n group$(if ($n -ne 1) { 's' }) on source user"
                $Script:GC_UI.GrpPlaceholder.Visibility = 'Collapsed'
                $Script:GC_UI.GrpList.Items.Clear()
                foreach ($g in $Script:GC_SourceGroups) {
                    $lbi         = [System.Windows.Controls.ListBoxItem]::new()
                    $lbi.Content = $g.displayName
                    $lbi.Tag     = $g
                    [void]$Script:GC_UI.GrpList.Items.Add($lbi)
                }
                $Script:GC_UI.GrpList.Visibility = 'Visible'
                Update-GcCopyButton
            } catch {
                Write-Log "GC src-grp timer error: $_" 'ERROR'
            }
        }
}

function Update-GcCopyButton {
    $Script:GC_UI.BtnCopy.IsEnabled = (
        $null -ne $Script:GC_SourceUser -and
        $null -ne $Script:GC_TargetUser -and
        $Script:GC_SourceGroups.Count -gt 0
    )
}

# ── Async group copy ───────────────────────────────────────────────────────────
function Start-GcCopy {
    if ($Script:DemoMode) { Start-GcCopyDemo; return }

    if ($Script:DryMode) {
        $srcUser = $Script:GC_SourceUser
        $tgtUser = $Script:GC_TargetUser
        Write-GcLog "[DRY] Would copy group memberships: $($srcUser.displayName) → $($tgtUser.displayName)" 'Warning'
        Write-GcLog "[DRY] Source has $($Script:GC_SourceGroups.Count) group(s)" 'Warning'
        Write-Log 'GC: dry run - would copy groups' 'INFO'
        return
    }

    $srcUser   = $Script:GC_SourceUser
    $tgtUser   = $Script:GC_TargetUser
    $srcGroups = $Script:GC_SourceGroups

    $Script:GC_UI.BtnCopy.IsEnabled = $false
    Set-MainStatus "Copying groups to $($tgtUser.displayName)..." 'TextDim'
    Write-GcLog "Starting: '$($srcUser.displayName)' -> '$($tgtUser.displayName)'" 'TextDim'

    if ($Script:GC_CopyTimer) { $Script:GC_CopyTimer.Stop() }
    $Script:GC_CopyTimer = Start-AsyncWork `
        -IntervalMs 500 `
        -Vars    @{ SrcGroups = $srcGroups; TgtUserId = $tgtUser.id } `
        -RefSeed @{
            Added   = [System.Collections.Generic.List[string]]::new()
            Skipped = [System.Collections.Generic.List[string]]::new()
            Failed  = [System.Collections.Generic.List[string]]::new()
        } `
        -Script {
            $tgtGroupIds = [System.Collections.Generic.HashSet[string]]::new()
            $url = "https://graph.microsoft.com/v1.0/users/$TgtUserId/memberOf?`$select=id&`$top=999"
            do {
                $resp = Invoke-RestMethod -Uri $url `
                    -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
                foreach ($g in $resp.value) { [void]$tgtGroupIds.Add($g.id) }
                $url = $resp.'@odata.nextLink'
            } while ($url)

            foreach ($grp in $SrcGroups) {
                if ($tgtGroupIds.Contains($grp.id)) {
                    $Ref['Skipped'].Add($grp.displayName)
                    continue
                }
                try {
                    $body = '{"@odata.id":"https://graph.microsoft.com/v1.0/directoryObjects/' + $TgtUserId + '"}'
                    Invoke-RestMethod `
                        -Uri "https://graph.microsoft.com/v1.0/groups/$($grp.id)/members/`$ref" `
                        -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } `
                        -Method POST -Body $body -ErrorAction Stop
                    $Ref['Added'].Add($grp.displayName)
                } catch {
                    $Ref['Failed'].Add("$($grp.displayName): $($_.Exception.Message)")
                }
            }
        } -OnComplete {
            param($ref)
            try {
                if ($ref['Error']) {
                    Write-Log "GC: copy error - $($ref['Error'])" 'ERROR'
                    Write-GcLog "Error: $($ref['Error'])" 'Danger'
                    Set-MainStatus 'Group copy failed.' 'Danger'
                } else {
                    $added   = $ref['Added']
                    $skipped = $ref['Skipped']
                    $failed  = $ref['Failed']

                    foreach ($g in $added)   { Write-GcLog "Added:   $g" 'Success' }
                    foreach ($g in $skipped) { Write-GcLog "Skipped: $g (already a member)" 'TextDim' }
                    foreach ($g in $failed)  { Write-GcLog "Failed:  $g" 'Danger' }

                    $summary = "Done — added: $($added.Count)  skipped: $($skipped.Count)  failed: $($failed.Count)"
                    Write-GcLog $summary 'Text'
                    Set-MainStatus $summary 'Success'
                    Write-Log "GC: $summary" 'INFO'
                }

                Update-GcCopyButton
            } catch {
                Write-Log "GC copy-timer error: $_" 'ERROR'
            }
        }
}

# ── XAML ───────────────────────────────────────────────────────────────────────
$Script:GcXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
      Background="#12121C">
  <Grid.Resources>

    <SolidColorBrush x:Key="Bg"      Color="#12121C"/>
    <SolidColorBrush x:Key="Surface" Color="#1C1C2A"/>
    <SolidColorBrush x:Key="Card"    Color="#242436"/>
    <SolidColorBrush x:Key="Border"  Color="#3C3C5A"/>
    <SolidColorBrush x:Key="Accent"  Color="#6366F1"/>
    <SolidColorBrush x:Key="Text"    Color="#E2E2F0"/>
    <SolidColorBrush x:Key="TextDim" Color="#7878A0"/>
    <SolidColorBrush x:Key="Muted"   Color="#50507A"/>

    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Foreground"      Value="White"/>
      <Setter Property="FontWeight"      Value="SemiBold"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor"          Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.85"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="#242436"/>
                <Setter Property="Foreground" Value="#3C3C5A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background"               Value="#242436"/>
      <Setter Property="Foreground"               Value="#E2E2F0"/>
      <Setter Property="BorderBrush"              Value="#3C3C5A"/>
      <Setter Property="BorderThickness"          Value="1"/>
      <Setter Property="Padding"                  Value="8,4"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="CaretBrush"               Value="#E2E2F0"/>
      <Setter Property="FocusVisualStyle"         Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="4">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                            Background="{TemplateBinding Background}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="#1C1C2A"/>
                <Setter Property="Foreground" Value="#3C3C5A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ListBox">
      <Setter Property="Background"      Value="#12121C"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding"         Value="0"/>
    </Style>

    <Style TargetType="ListBoxItem">
      <Setter Property="Foreground"                 Value="#E2E2F0"/>
      <Setter Property="Background"                 Value="Transparent"/>
      <Setter Property="Padding"                    Value="12,7"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Cursor"                     Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1E1E38"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#2A2A50"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TabControl">
      <Setter Property="Background"      Value="#12121C"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>

    <Style TargetType="TabItem">
      <Setter Property="Foreground"      Value="#7878A0"/>
      <Setter Property="Background"      Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding"         Value="14,8"/>
      <Setter Property="FontWeight"      Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border Padding="{TemplateBinding Padding}" Cursor="Hand">
              <Border x:Name="ind" BorderThickness="0,0,0,2" BorderBrush="Transparent" Padding="0,0,0,3">
                <ContentPresenter ContentSource="Header"/>
              </Border>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter Property="Foreground" Value="#E2E2F0"/>
                <Setter TargetName="ind" Property="BorderBrush" Value="#6366F1"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

  </Grid.Resources>

  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="260" MinWidth="200"/>
    <ColumnDefinition Width="5"/>
    <ColumnDefinition Width="*"/>
  </Grid.ColumnDefinitions>

  <GridSplitter Grid.Column="1" Width="5" HorizontalAlignment="Stretch"
                Background="#3C3C5A" Cursor="SizeWE" ResizeBehavior="PreviousAndNext"/>

  <!-- Left sidebar: source and target user pickers stacked -->
  <Border Grid.Column="0" Background="#1C1C2A">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="*"/>
        <RowDefinition Height="5"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <!-- Source user picker -->
      <Grid Grid.Row="0">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Border Grid.Row="0" Padding="12,10" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
          <StackPanel>
            <TextBlock Text="SOURCE — COPY FROM" Foreground="#50507A" FontSize="10"
                       FontWeight="Bold" Margin="0,0,0,8"/>
            <TextBox x:Name="GcSrcSearch" IsEnabled="False" Height="34"/>
          </StackPanel>
        </Border>
        <ListBox x:Name="GcSrcList" Grid.Row="1" IsEnabled="False"
                 ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                 VirtualizingPanel.IsVirtualizing="True"
                 VirtualizingPanel.VirtualizationMode="Recycling"
                 Margin="0,2,0,2"/>
      </Grid>

      <GridSplitter Grid.Row="1" Height="5" HorizontalAlignment="Stretch"
                    Background="#3C3C5A" Cursor="SizeNS" ResizeBehavior="PreviousAndNext"/>

      <!-- Target user picker -->
      <Grid Grid.Row="2">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Border Grid.Row="0" Padding="12,10" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
          <StackPanel>
            <TextBlock Text="TARGET — COPY TO" Foreground="#50507A" FontSize="10"
                       FontWeight="Bold" Margin="0,0,0,8"/>
            <TextBox x:Name="GcTgtSearch" IsEnabled="False" Height="34"/>
          </StackPanel>
        </Border>
        <ListBox x:Name="GcTgtList" Grid.Row="1" IsEnabled="False"
                 ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                 VirtualizingPanel.IsVirtualizing="True"
                 VirtualizingPanel.VirtualizationMode="Recycling"
                 Margin="0,2,0,2"/>
      </Grid>
    </Grid>
  </Border>

  <!-- Right panel: action bar + groups/log tabs -->
  <Grid Grid.Column="2">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- Action bar: group summary + Copy button -->
    <Border Grid.Row="0" Background="#1C1C2A" BorderBrush="#3C3C5A"
            BorderThickness="0,0,0,1" Padding="18,14">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" VerticalAlignment="Center">
          <TextBlock x:Name="GcGrpHeader"
                     Text="Select a source user to view their groups"
                     Foreground="#7878A0" FontStyle="Italic" FontSize="12"/>
          <TextBlock x:Name="GcSrcLabel" Foreground="#6366F1" FontSize="11"
                     FontWeight="SemiBold" Margin="0,6,0,0" Visibility="Collapsed"/>
          <TextBlock x:Name="GcTgtLabel" Foreground="#50507A" FontSize="11"
                     Margin="0,2,0,0" Visibility="Collapsed"/>
        </StackPanel>
        <Button x:Name="GcBtnCopy" Grid.Column="1"
                Content="Copy Groups" IsEnabled="False"
                Style="{StaticResource PrimaryBtn}" Background="#6366F1"
                Padding="18,10" FontSize="13" VerticalAlignment="Center"/>
      </Grid>
    </Border>

    <!-- Groups / Log tab control -->
    <TabControl Grid.Row="1">
      <TabControl.Template>
        <ControlTemplate TargetType="TabControl">
          <Grid Background="#12121C">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
              <TabPanel IsItemsHost="True" Margin="8,0"/>
            </Border>
            <ContentPresenter Grid.Row="1" ContentSource="SelectedContent"/>
          </Grid>
        </ControlTemplate>
      </TabControl.Template>

      <!-- Groups tab: source user's group list -->
      <TabItem Header="Groups">
        <Grid Background="#12121C">
          <TextBlock x:Name="GcGrpPlaceholder"
                     Text="Select a source user to see their groups"
                     Foreground="#50507A" FontStyle="Italic" FontSize="13"
                     HorizontalAlignment="Center" VerticalAlignment="Center"/>
          <ListBox x:Name="GcGrpList"
                   ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                   VirtualizingPanel.IsVirtualizing="True"
                   VirtualizingPanel.VirtualizationMode="Recycling"
                   Margin="0,2,0,2" Visibility="Collapsed"/>
        </Grid>
      </TabItem>

    <!-- Log tab removed — use the global Log pane -->

    </TabControl>
  </Grid>

</Grid>
'@

# ── Initialize ─────────────────────────────────────────────────────────────────
function Initialize-GroupCopyTool {
    $reader  = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new((Invoke-ThemeXaml $Script:GcXaml)))
    $content = [System.Windows.Markup.XamlReader]::Load($reader)

    $Script:GC_UI = @{
        SrcSearch      = $content.FindName('GcSrcSearch')
        SrcList        = $content.FindName('GcSrcList')
        TgtSearch      = $content.FindName('GcTgtSearch')
        TgtList        = $content.FindName('GcTgtList')
        GrpHeader      = $content.FindName('GcGrpHeader')
        SrcLabel       = $content.FindName('GcSrcLabel')
        TgtLabel       = $content.FindName('GcTgtLabel')
        BtnCopy        = $content.FindName('GcBtnCopy')
        GrpList        = $content.FindName('GcGrpList')
        GrpPlaceholder = $content.FindName('GcGrpPlaceholder')
        # LogBox removed — use Write-AppLog to the global Log pane
    }

    $Script:GC_UI.SrcSearch.Add_TextChanged({
        try { Update-GcSrcFilter }
        catch { Write-Log "GC SrcSearch TextChanged error: $_" 'ERROR' }
    })

    $Script:GC_UI.TgtSearch.Add_TextChanged({
        try { Update-GcTgtFilter }
        catch { Write-Log "GC TgtSearch TextChanged error: $_" 'ERROR' }
    })

    $Script:GC_UI.SrcList.Add_SelectionChanged({
        try {
            $sel = $Script:GC_UI.SrcList.SelectedItem
            if (-not $sel) { return }
            $Script:GC_SourceUser = $sel.Tag
            Write-Log "GC: source user '$($Script:GC_SourceUser.displayName)'" 'DEBUG'
            $Script:GC_UI.SrcLabel.Text       = "Source: $($Script:GC_SourceUser.displayName)  ($($Script:GC_SourceUser.userPrincipalName))"
            $Script:GC_UI.SrcLabel.Visibility = 'Visible'
            Start-GcSourceGroupLoad -UserId $Script:GC_SourceUser.id
        } catch {
            Write-Log "GC SrcList SelectionChanged error: $_" 'ERROR'
        }
    })

    $Script:GC_UI.TgtList.Add_SelectionChanged({
        try {
            $sel = $Script:GC_UI.TgtList.SelectedItem
            if (-not $sel) { return }
            $Script:GC_TargetUser = $sel.Tag
            Write-Log "GC: target user '$($Script:GC_TargetUser.displayName)'" 'DEBUG'
            $Script:GC_UI.TgtLabel.Text       = "Target: $($Script:GC_TargetUser.displayName)  ($($Script:GC_TargetUser.userPrincipalName))"
            $Script:GC_UI.TgtLabel.Visibility = 'Visible'
            Update-GcCopyButton
        } catch {
            Write-Log "GC TgtList SelectionChanged error: $_" 'ERROR'
        }
    })

    $Script:GC_UI.BtnCopy.Add_Click({
        try {
            if (-not $Script:GC_SourceUser -or -not $Script:GC_TargetUser) { return }
            if ($Script:GC_SourceUser.id -eq $Script:GC_TargetUser.id) {
                Write-GcLog 'Source and target are the same user — nothing to do.' 'Warning'
                return
            }
            Start-GcCopy
        } catch {
            Write-Log "GC BtnCopy click error: $_" 'ERROR'
        }
    })

    Register-ConnectCallback 'Start-GcUserLoad'
    $Script:ResetCallbacks.Add({
        $Script:GC_AllUsers     = @()
        $Script:GC_SourceUser   = $null
        $Script:GC_TargetUser   = $null
        $Script:GC_SourceGroups = @()

        $Script:GC_UI.SrcList.Items.Clear()
        $Script:GC_UI.TgtList.Items.Clear()
        $Script:GC_UI.SrcSearch.Text      = ''
        $Script:GC_UI.TgtSearch.Text      = ''
        $Script:GC_UI.SrcSearch.IsEnabled = $false
        $Script:GC_UI.TgtSearch.IsEnabled = $false
        $Script:GC_UI.SrcList.IsEnabled   = $false
        $Script:GC_UI.TgtList.IsEnabled   = $false
        $Script:GC_UI.SrcLabel.Visibility = 'Collapsed'
        $Script:GC_UI.TgtLabel.Visibility = 'Collapsed'
        $Script:GC_UI.GrpHeader.Text      = 'Select a source user to view their groups'
        $Script:GC_UI.GrpList.Items.Clear()
        $Script:GC_UI.GrpList.Visibility        = 'Collapsed'
        $Script:GC_UI.GrpPlaceholder.Text       = 'Select a source user to see their groups'
        $Script:GC_UI.GrpPlaceholder.Visibility = 'Visible'
        $Script:GC_UI.BtnCopy.IsEnabled         = $false
    })

    Write-GcLog 'Group Copy ready. Select a tenant to begin.' 'Muted'
    return $content
}
