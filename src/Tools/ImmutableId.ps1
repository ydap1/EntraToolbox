<#
    ImmutableId.ps1 — assign onPremisesImmutableId to cloud-only Entra users.

    The list starts empty: add all users, a department or an office location,
    then search the list to see who already has an ImmutableId.

    Uses a per-row checkbox column so you can pick exactly which accounts get an
    ID.  The DataGrid uses IsHitTestVisible="False" on the checkbox so clicks
    pass through to a PreviewMouseLeftButtonDown handler at the Grid level that
    manually toggles the Selected property and calls Items.Refresh().

    Prefix: IID_
    Exposes: Initialize-ImmutableIdTool
#>

# ── Shared state ───────────────────────────────────────────────────────────────
$Script:IID_UI           = @{}
$Script:IID_Rows         = [System.Collections.Generic.List[object]]::new()   # every user added to the list
$Script:IID_AllUsers     = @()     # cloud-only members available to add
$Script:IID_CheckboxCol  = $null   # reference to col 0 for hit-testing
$Script:IID_ApplyTimer   = $null

# ── New-ImmutableIdValue ───────────────────────────────────────────────────────
function New-ImmutableIdValue {
    [Convert]::ToBase64String([System.Guid]::NewGuid().ToByteArray())
}

# ── Visual-tree helper ─────────────────────────────────────────────────────────
function Find-IidAncestor {
    param($Element, [type]$AncestorType)
    $cur = $Element -as [System.Windows.DependencyObject]
    while ($cur) {
        if ($cur -is $AncestorType) { return $cur }
        $cur = [System.Windows.Media.VisualTreeHelper]::GetParent($cur)
    }
    return $null
}

# ── XAML ───────────────────────────────────────────────────────────────────────
$Script:IID_Xaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
      Background="#12121C">
  <Grid.Resources>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground"      Value="White"/>
      <Setter Property="FontWeight"      Value="SemiBold"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor"          Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    CornerRadius="5" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.82"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.65"/>
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

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#C0C0E0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>

  </Grid.Resources>

  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="260" MinWidth="200"/>
    <ColumnDefinition Width="5"/>
    <ColumnDefinition Width="*"/>
  </Grid.ColumnDefinitions>
  <GridSplitter Grid.Column="1" Width="5" HorizontalAlignment="Stretch"
                Background="#3C3C5A" Cursor="SizeWE" ResizeBehavior="PreviousAndNext"/>

  <!-- ── Sidebar: choose who to list ─────────────────────────────────── -->
  <Border Grid.Column="0" Background="#1C1C2A">
    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <StackPanel x:Name="IidPicker" Margin="12" IsEnabled="False">
        <TextBlock Text="The list starts empty. Add the users you want to check or change."
                   Foreground="#7878A0" TextWrapping="Wrap" Margin="0,0,0,12"/>
        <Button x:Name="IidBtnAddAll" Content="Add all users" Style="{StaticResource EtbAction}" Margin="0,0,0,16"/>
        <TextBlock Text="Department" Foreground="#7878A0" Margin="0,0,0,6"/>
        <ComboBox x:Name="IidDepartments" Style="{StaticResource EtbPopulationCombo}" AutomationProperties.Name="Department"/>
        <Button x:Name="IidBtnAddDept" Content="Add department" Style="{StaticResource EtbAction}" Margin="0,8,0,16"/>
        <TextBlock Text="Office location" Foreground="#7878A0" Margin="0,0,0,6"/>
        <ComboBox x:Name="IidOffices" Style="{StaticResource EtbPopulationCombo}" AutomationProperties.Name="Office location"/>
        <Button x:Name="IidBtnAddOffice" Content="Add office location" Style="{StaticResource EtbAction}" Margin="0,8,0,16"/>
        <Button x:Name="IidBtnClear" Content="Clear list" Style="{StaticResource EtbAction}"/>
      </StackPanel>
    </ScrollViewer>
  </Border>

  <Grid Grid.Column="2">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- ── Search and filter toolbar ──────────────────────────────────── -->
    <Border Grid.Row="0" Background="#1A1A2C" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1"
            Padding="16,10">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="260"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <TextBox x:Name="IidSearch" AutomationProperties.Name="Search the list by name or UPN"
                 ToolTip="Search the list by name or UPN" VerticalAlignment="Center"/>
        <WrapPanel Grid.Column="1" Orientation="Horizontal" Margin="16,0,0,0" VerticalAlignment="Center">
          <CheckBox x:Name="IidChkEmptyOnly" Content="Hide users who already have an ImmutableId"
                    IsChecked="False" Margin="0,0,24,0" VerticalAlignment="Center"/>
          <CheckBox x:Name="IidChkOverwrite"
                    Content="Allow overwriting existing ImmutableIds  &#x26A0; permanent" Foreground="#FBBF24"
                    IsChecked="False" VerticalAlignment="Center"/>
        </WrapPanel>
      </Grid>
    </Border>

    <!-- ── Action toolbar ─────────────────────────────────────────────── -->
    <Border Grid.Row="1" Background="#1A1A2C" Padding="12,8">
      <DockPanel LastChildFill="False">

        <!-- Selection buttons + count -->
        <StackPanel DockPanel.Dock="Left" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="IidBtnCheckAll" Content="Select All"
                  Style="{StaticResource Btn}" Background="#3C3C5A" Padding="10,6"
                  ToolTip="Tick every row shown by the current search"
                  IsEnabled="False" Margin="0,0,6,0"/>
          <Button x:Name="IidBtnUncheckAll" Content="Deselect All"
                  Style="{StaticResource Btn}" Background="#3C3C5A" Padding="10,6"
                  ToolTip="Untick every row shown by the current search"
                  IsEnabled="False" Margin="0,0,16,0"/>
          <TextBlock x:Name="IidLblCount" VerticalAlignment="Center"
                     Foreground="#7878A0" FontSize="12"/>
        </StackPanel>

        <!-- Action buttons -->
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="IidBtnGenerate"
                  Content="Generate IDs for selected rows"
                  Style="{StaticResource Btn}" Background="#6366F1" Padding="12,7"
                  ToolTip="Creates a new random Base64 ImmutableId for each checked row that does not yet have one generated"
                  IsEnabled="False" Margin="0,0,8,0"/>
          <Button x:Name="IidBtnApply"
                  Content="Assign ImmutableIds to selected rows"
                  Style="{StaticResource Btn}" Background="#EF4444" Padding="12,7"
                  ToolTip="Permanently writes the generated ID to Entra for each checked row that has a generated ID ready"
                  IsEnabled="False" Margin="0,0,8,0"/>
          <Button x:Name="IidBtnRemove"
                  Content="Remove ImmutableId from selected"
                  Style="{StaticResource Btn}" Background="#7F1D1D" Padding="12,7"
                  ToolTip="Clears onPremisesImmutableId (sets to null) on each checked row that currently has one"
                  IsEnabled="False"/>
        </StackPanel>

      </DockPanel>
    </Border>

    <!-- ── DataGrid ─────────────────────────────────────────────────────── -->
    <DataGrid x:Name="IidGrid" Grid.Row="2" Margin="12,10" CanUserSortColumns="True"
              RowStyle="{StaticResource DgRow}" CellStyle="{StaticResource DgCell}"
              VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
      <DataGrid.Columns>

        <!-- col 0: Include checkbox. IsHitTestVisible=False so clicks bubble up -->
        <DataGridTemplateColumn Header="Include" Width="72" SortMemberPath="Selected">
          <DataGridTemplateColumn.CellTemplate>
            <DataTemplate>
              <CheckBox IsChecked="{Binding Selected, Mode=OneWay}"
                        IsHitTestVisible="False"
                        HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </DataTemplate>
          </DataGridTemplateColumn.CellTemplate>
        </DataGridTemplateColumn>

        <DataGridTextColumn Header="Display Name"         Binding="{Binding Name}"       Width="170" SortMemberPath="Name"/>
        <DataGridTextColumn Header="User Principal Name"  Binding="{Binding Upn}"        Width="230" SortMemberPath="Upn"/>
        <DataGridTextColumn Header="Department"           Binding="{Binding Department}" Width="100" SortMemberPath="Department"/>
        <DataGridTextColumn Header="Office"               Binding="{Binding Office}"     Width="110" SortMemberPath="Office"/>
        <DataGridTextColumn Header="Current ImmutableId"  Binding="{Binding CurrentId}"  Width="200" SortMemberPath="CurrentId"
                            Foreground="#7878A0"/>
        <DataGridTextColumn Header="New ImmutableId (to be assigned)" Binding="{Binding NewId}" Width="*" SortMemberPath="NewId"/>

        <!-- Status with colour-coded text -->
        <DataGridTemplateColumn Header="Status" Width="110" SortMemberPath="Status">
          <DataGridTemplateColumn.CellTemplate>
            <DataTemplate>
              <TextBlock Text="{Binding Status}" FontWeight="SemiBold" FontSize="11"
                         Padding="4,2" VerticalAlignment="Center">
                <TextBlock.Style>
                  <Style TargetType="TextBlock">
                    <Setter Property="Foreground" Value="#7878A0"/>
                    <Style.Triggers>
                      <DataTrigger Binding="{Binding Status}" Value="Ready">
                        <Setter Property="Foreground" Value="#6366F1"/>
                      </DataTrigger>
                      <DataTrigger Binding="{Binding Status}" Value="Assigned">
                        <Setter Property="Foreground" Value="#22C55E"/>
                      </DataTrigger>
                      <DataTrigger Binding="{Binding Status}" Value="Error">
                        <Setter Property="Foreground" Value="#EF4444"/>
                      </DataTrigger>
                      <DataTrigger Binding="{Binding Status}" Value="Removed">
                        <Setter Property="Foreground" Value="#94A3B8"/>
                      </DataTrigger>
                    </Style.Triggers>
                  </Style>
                </TextBlock.Style>
              </TextBlock>
            </DataTemplate>
          </DataGridTemplateColumn.CellTemplate>
        </DataGridTemplateColumn>

      </DataGrid.Columns>
    </DataGrid>
  </Grid>

</Grid>
'@

# ── Log helper ─────────────────────────────────────────────────────────────────
function Write-IidLog {
    param([string]$Message, [string]$Color = 'TextDim')
    Write-AppLog $Message $Color
}

# ── Row factory ────────────────────────────────────────────────────────────────
function New-IidRow {
    param($User, [bool]$Selected, [string]$CurrentId, [string]$NewId = '', [string]$Status = 'Pending')
    [PSCustomObject]@{
        Id          = $User.id
        Name        = $User.displayName
        Upn         = $User.userPrincipalName
        Department  = $User.department
        Office      = $User.officeLocation
        CurrentId   = if ($CurrentId) { $CurrentId } else { '—' }
        HasExisting = [bool]$CurrentId
        NewId       = $NewId
        Status      = $Status
        Selected    = $Selected
    }
}

# Rows matching the search text and the hide-existing filter.
function Select-IidRows {
    param([object[]]$Rows, [string]$Query, [bool]$HideExisting)
    foreach ($r in $Rows) {
        if ($HideExisting -and $r.HasExisting) { continue }
        if ($Query -and "$($r.Name)".IndexOf($Query, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
            "$($r.Upn)".IndexOf($Query, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $r
    }
}

# Adds users to the list, skipping anyone already in it. Users without an
# ImmutableId start ticked, as they are the usual target.
function Add-IidUsers {
    param([object[]]$Users)
    $listed = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Script:IID_Rows | ForEach-Object Id))
    $added = 0
    foreach ($u in $Users) {
        if (-not $u.id -or -not $listed.Add($u.id)) { continue }
        $cid = $u.onPremisesImmutableId
        $Script:IID_Rows.Add((New-IidRow -User $u -Selected (-not [bool]$cid) -CurrentId $cid))
        $added++
    }
    Update-IidView
    Write-IidLog "Immutable ID: added $added user(s) to the list$(if ($Users.Count -gt $added) { "; $($Users.Count - $added) already listed" })." 'TextDim'
}

# Shows the filtered rows, keeping the user's column sort.
function Update-IidView {
    $grid  = $Script:IID_UI.Grid
    $sorts = @($grid.Items.SortDescriptions)
    $dirs  = @{}
    foreach ($col in $grid.Columns) { if ($null -ne $col.SortDirection) { $dirs[$col.SortMemberPath] = $col.SortDirection } }
    $shown = @(Select-IidRows -Rows $Script:IID_Rows -Query $Script:IID_UI.Search.Text.Trim() -HideExisting ([bool]$Script:IID_UI.ChkEmptyOnly.IsChecked))
    $grid.ItemsSource = [System.Collections.Generic.List[object]]::new([object[]]$shown)
    foreach ($sort in $sorts) { $grid.Items.SortDescriptions.Add($sort) }
    foreach ($col in $grid.Columns) { if ($dirs.ContainsKey($col.SortMemberPath)) { $col.SortDirection = $dirs[$col.SortMemberPath] } }
    Update-IidCounts
}

# ── Count / button state ───────────────────────────────────────────────────────
function Update-IidCounts {
    $total      = $Script:IID_Rows.Count
    $shown      = if ($Script:IID_UI.Grid.ItemsSource) { $Script:IID_UI.Grid.ItemsSource.Count } else { 0 }
    $checked    = ($Script:IID_Rows | Where-Object Selected).Count
    $ready      = ($Script:IID_Rows | Where-Object { $_.Selected -and $_.NewId -and $_.NewId -ne '' }).Count
    $removable  = ($Script:IID_Rows | Where-Object { $_.Selected -and $_.HasExisting }).Count

    $Script:IID_UI.LblCount.Text = if ($total) { "$total in list  ·  $shown shown  ·  $checked selected  ·  $ready ready to assign" } else { 'No users in the list yet.' }
    $Script:IID_UI.BtnCheckAll.IsEnabled   = $shown -gt 0
    $Script:IID_UI.BtnUncheckAll.IsEnabled = $shown -gt 0

    $anyPending = ($Script:IID_Rows | Where-Object { $_.Selected -and (-not $_.NewId -or $_.NewId -eq '') }).Count -gt 0
    $Script:IID_UI.BtnGenerate.IsEnabled = $anyPending
    $Script:IID_UI.BtnApply.IsEnabled    = $ready -gt 0
    $Script:IID_UI.BtnRemove.IsEnabled   = $removable -gt 0
}

# ── Select All / Deselect All ─────────────────────────────────────────────────
function Set-IidAllSelected {
    param([bool]$Value)
    foreach ($r in $Script:IID_UI.Grid.ItemsSource) { $r.Selected = $Value }
    $Script:IID_UI.Grid.Items.Refresh()
    Update-IidCounts
}

# ── Generate IDs for checked rows ─────────────────────────────────────────────
function Invoke-IidGenerate {
    $count = 0
    foreach ($r in $Script:IID_Rows) {
        if ($r.Selected -and (-not $r.NewId -or $r.NewId -eq '')) {
            $r.NewId  = New-ImmutableIdValue
            $r.Status = 'Ready'
            $count++
        }
    }
    $Script:IID_UI.Grid.Items.Refresh()
    Update-IidCounts
    Write-IidLog "Generated ImmutableId for $count selected user(s)." 'Accent'
    Write-Log    "ImmutableId: generated $count new values" 'INFO'
}

# ── Apply (async) ──────────────────────────────────────────────────────────────
function Start-IidApply {
    $overwrite = $Script:IID_UI.ChkOverwrite.IsChecked
    $toAssign  = @($Script:IID_Rows | Where-Object { $_.Selected -and $_.NewId -and $_.NewId -ne '' })

    if ($toAssign.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            'No selected rows have a generated ImmutableId ready to assign.`n`nGenerate IDs first, then click Assign.',
            'Nothing to Assign', 'OK', 'Information') | Out-Null
        return
    }

    if ($Script:DryMode) {
        Write-IidLog "[DRY] Would assign ImmutableId to $($toAssign.Count) user(s):" 'Warning'
        foreach ($r in $toAssign) { Write-IidLog "  $($r.Name) → $($r.NewId)" 'Warning' }
        Write-Log "ImmutableId: dry run - would assign $($toAssign.Count) IDs" 'INFO'
        return
    }

    $alreadyHaveId = @($toAssign | Where-Object { $_.HasExisting })
    if ($alreadyHaveId.Count -gt 0 -and -not $overwrite) {
        [System.Windows.MessageBox]::Show(
            "$($alreadyHaveId.Count) selected user(s) already have an ImmutableId.`n`nEnable 'Allow overwriting' in the filter bar, or deselect those users.",
            'Overwrite Not Enabled', 'OK', 'Warning') | Out-Null
        return
    }

    $preview = ($toAssign | Select-Object -First 5 | ForEach-Object { "  • $($_.Name)" }) -join "`n"
    if ($toAssign.Count -gt 5) { $preview += "`n  … and $($toAssign.Count - 5) more" }

    $msg = @"
You are about to permanently assign an ImmutableId to $($toAssign.Count) user account(s):

$preview

WARNING — this action:
  • Cannot be undone without Microsoft Support assistance
  • Binds each account to a specific AD Connect sync anchor
  • May prevent the account being imported from on-premises AD later

Type YES (all capitals) to confirm.
"@
    Add-Type -AssemblyName Microsoft.VisualBasic
    $confirm = [Microsoft.VisualBasic.Interaction]::InputBox($msg, 'Confirm ImmutableId Assignment', '')
    if ($confirm -ne 'YES') {
        Write-IidLog 'Assignment cancelled.' 'Warning'
        return
    }

    $Script:IID_UI.BtnApply.IsEnabled      = $false
    $Script:IID_UI.BtnGenerate.IsEnabled   = $false
    $Script:IID_UI.BtnCheckAll.IsEnabled   = $false
    $Script:IID_UI.BtnUncheckAll.IsEnabled = $false

    Write-IidLog "Assigning ImmutableIds to $($toAssign.Count) user(s)…" 'Accent'
    Write-Log    "ImmutableId: starting assignment for $($toAssign.Count) user(s)" 'INFO'

    $workItems = @($toAssign | ForEach-Object { @{ Id = $_.Id; Name = $_.Name; NewId = $_.NewId } })

    if ($Script:IID_ApplyTimer) { $Script:IID_ApplyTimer.Stop() }
    $Script:IID_ApplyTimer = Start-AsyncWork -BulkName 'Immutable ID' -BulkTotal $workItems.Count -RefSeed @{ Results = @() } -Vars @{ Pending = $workItems } -Script {
        $out = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Pending) {
            if ($Ref['CancelRequested']) { break }
            try {
                $body = ConvertTo-Json @{ onPremisesImmutableId = $item.NewId } -Compress
                $null = Invoke-RestMethod "https://graph.microsoft.com/v1.0/users/$($item.Id)" `
                    -Method PATCH -Headers @{ Authorization = "Bearer $Token" } `
                    -Body $body -ContentType 'application/json' -ErrorAction Stop
                $out.Add(@{ Id = $item.Id; Success = $true })
            } catch {
                $out.Add(@{ Id = $item.Id; Success = $false; Error = $_.Exception.Message })
            }
        }
        $Ref['Results'] = $out.ToArray()
    } -OnComplete {
        param($ref)
        try {
            if ($ref['Error']) {
                Write-IidLog "Assignment error: $($ref['Error'])" 'Danger'
                Write-Log "ImmutableId: assignment error: $($ref['Error'])" 'ERROR'
            } else {
                $ok = 0; $err = 0
                foreach ($res in $ref['Results']) {
                    $row = $Script:IID_Rows | Where-Object { $_.Id -eq $res.Id } | Select-Object -First 1
                    if (-not $row) { continue }
                    if ($res.Success) {
                        Write-EtbAudit -Tool 'Immutable ID' -Action 'Assign immutable ID' `
                                       -Target $row.Upn -Detail $row.NewId
                        $row.Status      = 'Assigned'
                        $row.CurrentId   = $row.NewId
                        $row.NewId       = ''
                        $row.HasExisting = $true
                        $ok++
                    } else {
                        $row.Status = 'Error'
                        Write-IidLog "  Error on $($row.Name): $($res.Error)" 'Danger'
                        Write-EtbAudit -Tool 'Immutable ID' -Action 'Assign immutable ID' `
                                       -Target $row.Upn -Result 'Failed' -Detail $res.Error
                        $err++
                    }
                }
                $Script:IID_UI.Grid.Items.Refresh()
                Write-IidLog "$(if ($ref.CancelRequested) { 'Stopped' } else { 'Done' }) — $ok assigned, $err error(s)." $(if ($err -or $ref.CancelRequested) { 'Warning' } else { 'Success' })
                Write-Log "ImmutableId: $ok assigned, $err errors" 'INFO'
            }
            $Script:IID_UI.BtnCheckAll.IsEnabled   = $true
            $Script:IID_UI.BtnUncheckAll.IsEnabled = $true
            Update-IidCounts
        } catch {
            Write-Log "ImmutableId apply timer error: $_" 'ERROR'
        }
    }
}

# ── Remove ImmutableId (async) ────────────────────────────────────────────────
function Start-IidRemove {
    $toRemove = @($Script:IID_Rows | Where-Object { $_.Selected -and $_.HasExisting })

    if ($toRemove.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            'No selected rows have an existing ImmutableId to remove.',
            'Nothing to Remove', 'OK', 'Information') | Out-Null
        return
    }

    if ($Script:DryMode) {
        Write-IidLog "[DRY] Would remove ImmutableId from $($toRemove.Count) user(s):" 'Warning'
        foreach ($r in $toRemove) { Write-IidLog "  $($r.Name)  ($($r.CurrentId))" 'Warning' }
        Write-Log "ImmutableId: dry run - would remove $($toRemove.Count) IDs" 'INFO'
        return
    }

    $preview = ($toRemove | Select-Object -First 5 | ForEach-Object { "  • $($_.Name)" }) -join "`n"
    if ($toRemove.Count -gt 5) { $preview += "`n  … and $($toRemove.Count - 5) more" }

    $msg = @"
You are about to remove the ImmutableId from $($toRemove.Count) user account(s):

$preview

WARNING — removing the ImmutableId:
  • Breaks any existing AD Connect soft-match or sync anchor for this account
  • Cannot be undone without reassigning a new ID

Type YES (all capitals) to confirm.
"@
    Add-Type -AssemblyName Microsoft.VisualBasic
    $confirm = [Microsoft.VisualBasic.Interaction]::InputBox($msg, 'Confirm ImmutableId Removal', '')
    if ($confirm -ne 'YES') {
        Write-IidLog 'Removal cancelled.' 'Warning'
        return
    }

    $Script:IID_UI.BtnRemove.IsEnabled   = $false
    $Script:IID_UI.BtnApply.IsEnabled    = $false
    $Script:IID_UI.BtnGenerate.IsEnabled = $false
    $Script:IID_UI.BtnCheckAll.IsEnabled   = $false
    $Script:IID_UI.BtnUncheckAll.IsEnabled = $false

    Write-IidLog "Removing ImmutableId from $($toRemove.Count) user(s)…" 'Accent'
    Write-Log    "ImmutableId: starting removal for $($toRemove.Count) user(s)" 'INFO'

    $workItems = @($toRemove | ForEach-Object { @{ Id = $_.Id; Name = $_.Name } })

    if ($Script:IID_ApplyTimer) { $Script:IID_ApplyTimer.Stop() }
    $Script:IID_ApplyTimer = Start-AsyncWork -BulkName 'Immutable ID' -BulkTotal $workItems.Count -RefSeed @{ Results = @() } -Vars @{ Pending = $workItems } -Script {
        $out = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Pending) {
            if ($Ref['CancelRequested']) { break }
            try {
                $null = Invoke-RestMethod "https://graph.microsoft.com/v1.0/users/$($item.Id)" `
                    -Method PATCH -Headers @{ Authorization = "Bearer $Token" } `
                    -Body '{"onPremisesImmutableId":null}' -ContentType 'application/json' -ErrorAction Stop
                $out.Add(@{ Id = $item.Id; Success = $true })
            } catch {
                $out.Add(@{ Id = $item.Id; Success = $false; Error = $_.Exception.Message })
            }
        }
        $Ref['Results'] = $out.ToArray()
    } -OnComplete {
        param($ref)
        try {
            if ($ref['Error']) {
                Write-IidLog "Removal error: $($ref['Error'])" 'Danger'
                Write-Log "ImmutableId: removal error: $($ref['Error'])" 'ERROR'
            } else {
                $ok = 0; $err = 0
                foreach ($res in $ref['Results']) {
                    $row = $Script:IID_Rows | Where-Object { $_.Id -eq $res.Id } | Select-Object -First 1
                    if (-not $row) { continue }
                    if ($res.Success) {
                        Write-EtbAudit -Tool 'Immutable ID' -Action 'Remove immutable ID' `
                                       -Target $row.Upn -Detail "Was: $($row.CurrentId)"
                        $row.Status      = 'Removed'
                        $row.CurrentId   = '—'
                        $row.NewId       = ''
                        $row.HasExisting = $false
                        $ok++
                    } else {
                        $row.Status = 'Error'
                        Write-IidLog "  Error on $($row.Name): $($res.Error)" 'Danger'
                        Write-EtbAudit -Tool 'Immutable ID' -Action 'Remove immutable ID' `
                                       -Target $row.Upn -Result 'Failed' -Detail $res.Error
                        $err++
                    }
                }
                $Script:IID_UI.Grid.Items.Refresh()
                Write-IidLog "$(if ($ref.CancelRequested) { 'Stopped' } else { 'Done' }) — $ok removed, $err error(s)." $(if ($err -or $ref.CancelRequested) { 'Warning' } else { 'Success' })
                Write-Log "ImmutableId: $ok removed, $err errors" 'INFO'
            }
            $Script:IID_UI.BtnCheckAll.IsEnabled   = $true
            $Script:IID_UI.BtnUncheckAll.IsEnabled = $true
            Update-IidCounts
        } catch {
            Write-Log "ImmutableId remove timer error: $_" 'ERROR'
        }
    }
}

# ── Load users (shared cache) ──────────────────────────────────────────────────
function Start-IidLoad {
    $Script:IID_UI.Picker.IsEnabled = $false
    $Script:IID_UI.LblCount.Text    = 'Loading users…'
    Request-EtbUsers -OnReady 'Complete-IidLoad'
}

function Complete-IidLoad {
    try {
        if ($Script:UserCache.Error) {
            Write-IidLog "Immutable ID: load failed: $($Script:UserCache.Error)" 'Danger'
            $Script:IID_UI.LblCount.Text = 'Load failed.'
            return
        }
        Set-IidUsers @($Script:UserCache.Users | Where-Object { $_.userType -eq 'Member' -and -not $_.onPremisesSyncEnabled })
    } catch {
        Write-Log "ImmutableId load error: $_" 'ERROR'
    }
}

function Set-IidUsers {
    param([object[]]$Users)
    $Script:IID_AllUsers = $Users
    Set-EtbPopulationCombo -ComboBox $Script:IID_UI.Departments -Users $Users -Mode Department
    Set-EtbPopulationCombo -ComboBox $Script:IID_UI.Offices -Users $Users -Mode OfficeLocation
    $Script:IID_UI.Picker.IsEnabled = $true
    Update-IidCounts
    Write-Log "ImmutableId: $($Users.Count) cloud-only members available" 'INFO'
}

# ── Demo stubs ─────────────────────────────────────────────────────────────────
function Start-IidLoadDemo {
    # Every fourth demo user already has an ID, so search and the hide filter have something to show.
    $i = 0
    Set-IidUsers @($Script:Demo_Users | ForEach-Object {
        $u = $_ | Select-Object *
        $u | Add-Member -NotePropertyName onPremisesImmutableId -NotePropertyValue $(if (($i++ % 4) -eq 0) { New-ImmutableIdValue } else { '' }) -Force
        $u
    })
}

function Start-IidApplyDemo {
    $toAssign = @($Script:IID_Rows | Where-Object { $_.Selected -and $_.NewId -and $_.NewId -ne '' })
    foreach ($r in $toAssign) {
        $r.Status      = 'Assigned'
        $r.CurrentId   = $r.NewId
        $r.NewId       = ''
        $r.HasExisting = $true
    }
    $Script:IID_UI.Grid.Items.Refresh()
    Update-IidCounts
    Write-IidLog "[DEMO] Assigned ImmutableId to $($toAssign.Count) user(s)." 'TextDim'
}

function Start-IidRemoveDemo {
    $toRemove = @($Script:IID_Rows | Where-Object { $_.Selected -and $_.HasExisting })
    foreach ($r in $toRemove) {
        $r.Status      = 'Removed'
        $r.CurrentId   = '—'
        $r.NewId       = ''
        $r.HasExisting = $false
    }
    $Script:IID_UI.Grid.Items.Refresh()
    Update-IidCounts
    Write-IidLog "[DEMO] Removed ImmutableId from $($toRemove.Count) user(s)." 'TextDim'
}

function Invoke-IidOnConnect {
    if ($Script:DemoMode) { Start-IidLoadDemo } else { Start-IidLoad }
}

# ── Initialize-ImmutableIdTool ─────────────────────────────────────────────────
function Initialize-ImmutableIdTool {
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new((Invoke-ThemeXaml $Script:IID_Xaml)))
    $panel  = [System.Windows.Markup.XamlReader]::Load($reader)

    $Script:IID_UI = @{
        Grid          = $panel.FindName('IidGrid')
        Picker        = $panel.FindName('IidPicker')
        BtnAddAll     = $panel.FindName('IidBtnAddAll')
        Departments   = $panel.FindName('IidDepartments')
        BtnAddDept    = $panel.FindName('IidBtnAddDept')
        Offices       = $panel.FindName('IidOffices')
        BtnAddOffice  = $panel.FindName('IidBtnAddOffice')
        BtnClear      = $panel.FindName('IidBtnClear')
        Search        = $panel.FindName('IidSearch')
        LblCount      = $panel.FindName('IidLblCount')
        BtnGenerate   = $panel.FindName('IidBtnGenerate')
        BtnApply      = $panel.FindName('IidBtnApply')
        BtnRemove     = $panel.FindName('IidBtnRemove')
        BtnCheckAll   = $panel.FindName('IidBtnCheckAll')
        BtnUncheckAll = $panel.FindName('IidBtnUncheckAll')
        ChkEmptyOnly  = $panel.FindName('IidChkEmptyOnly')
        ChkOverwrite  = $panel.FindName('IidChkOverwrite')
        # Log removed — use the global Log pane
    }

    $Script:IID_CheckboxCol = $Script:IID_UI.Grid.Columns[0]

    # ── Checkbox toggle: PreviewMouseLeftButtonDown on the Grid ────────────────
    $Script:IID_UI.Grid.Add_PreviewMouseLeftButtonDown({
        param($s, $e)
        try {
            $cell = Find-IidAncestor -Element $e.OriginalSource `
                                     -AncestorType ([System.Windows.Controls.DataGridCell])
            if (-not $cell) { return }
            if ($cell.Column -ne $Script:IID_CheckboxCol) { return }
            $row = $cell.DataContext
            if ($row -is [PSObject]) {
                $row.Selected = -not $row.Selected
                $Script:IID_UI.Grid.Items.Refresh()
                Update-IidCounts
                $e.Handled = $true
            }
        } catch { Write-Log "IID checkbox toggle error: $_" 'ERROR' }
    })

    $Script:IID_UI.BtnCheckAll.Add_Click({
        try { Set-IidAllSelected $true }
        catch { Write-Log "IID CheckAll error: $_" 'ERROR' }
    })
    $Script:IID_UI.BtnUncheckAll.Add_Click({
        try { Set-IidAllSelected $false }
        catch { Write-Log "IID UncheckAll error: $_" 'ERROR' }
    })

    $Script:IID_UI.ChkEmptyOnly.Add_Checked({
        try { Update-IidView } catch { Write-Log "IID EmptyOnly checked error: $_" 'ERROR' }
    })
    $Script:IID_UI.ChkEmptyOnly.Add_Unchecked({
        try { Update-IidView } catch { Write-Log "IID EmptyOnly unchecked error: $_" 'ERROR' }
    })
    $Script:IID_UI.Search.Add_TextChanged({ Invoke-EtbDebounced -Key 'IID_Search' -Command 'Update-IidView' })
    $Script:IID_UI.BtnAddAll.Add_Click({
        try { Add-IidUsers $Script:IID_AllUsers } catch { Write-Log "IID add all error: $_" 'ERROR' }
    })
    $Script:IID_UI.BtnAddDept.Add_Click({
        try { Add-IidUsers @($Script:IID_UI.Departments.SelectedItem.DataContext.Users) } catch { Write-Log "IID add department error: $_" 'ERROR' }
    })
    $Script:IID_UI.BtnAddOffice.Add_Click({
        try { Add-IidUsers @($Script:IID_UI.Offices.SelectedItem.DataContext.Users) } catch { Write-Log "IID add office error: $_" 'ERROR' }
    })
    $Script:IID_UI.BtnClear.Add_Click({
        try { $Script:IID_Rows.Clear(); Update-IidView } catch { Write-Log "IID clear error: $_" 'ERROR' }
    })
    $Script:IID_UI.ChkOverwrite.Add_Checked({
        try { Write-IidLog 'Overwrite enabled — existing ImmutableIds may be replaced.' 'Warning' } catch {}
    })
    $Script:IID_UI.ChkOverwrite.Add_Unchecked({
        try { Write-IidLog 'Overwrite disabled.' 'TextDim' } catch {}
    })

    $Script:IID_UI.BtnGenerate.Add_Click({
        try { Invoke-IidGenerate }
        catch { Write-Log "IID Generate click error: $_" 'ERROR' }
    })
    $Script:IID_UI.BtnApply.Add_Click({
        try {
            if ($Script:DemoMode) { Start-IidApplyDemo; return }
            Start-IidApply
        } catch { Write-Log "IID Apply click error: $_" 'ERROR' }
    })

    $Script:IID_UI.BtnRemove.Add_Click({
        try {
            if ($Script:DemoMode) { Start-IidRemoveDemo; return }
            Start-IidRemove
        } catch { Write-Log "IID Remove click error: $_" 'ERROR' }
    })

    # ── Lifecycle ──────────────────────────────────────────────────────────────
    Register-ConnectCallback 'Invoke-IidOnConnect'
    $Script:ResetCallbacks.Add({
        try {
            if ($Script:IID_ApplyTimer) { $Script:IID_ApplyTimer.Stop(); $Script:IID_ApplyTimer = $null }
            $Script:IID_Rows.Clear()
            $Script:IID_AllUsers = @()
            $Script:IID_UI.Grid.ItemsSource = $null
            $Script:IID_UI.Search.Text = ''
            $Script:IID_UI.Picker.IsEnabled = $false
            foreach ($combo in 'Departments','Offices') { $Script:IID_UI[$combo].Items.Clear(); $Script:IID_UI[$combo].IsEnabled = $false }
            $Script:IID_UI.LblCount.Text             = ''
            $Script:IID_UI.BtnGenerate.IsEnabled     = $false
            $Script:IID_UI.BtnApply.IsEnabled        = $false
            $Script:IID_UI.BtnRemove.IsEnabled       = $false
            $Script:IID_UI.BtnCheckAll.IsEnabled     = $false
            $Script:IID_UI.BtnUncheckAll.IsEnabled   = $false
        } catch { Write-Log "ImmutableId ResetCallback error: $_" 'ERROR' }
    })

    return $panel
}
