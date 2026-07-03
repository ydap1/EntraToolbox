<#
    ImmutableId.ps1 — assign onPremisesImmutableId to cloud-only Entra users.

    Uses a per-row checkbox column so you can pick exactly which accounts get an
    ID.  The DataGrid uses IsHitTestVisible="False" on the checkbox so clicks
    pass through to a PreviewMouseLeftButtonDown handler at the Grid level that
    manually toggles the Selected property and calls Items.Refresh().

    Prefix: IID_
    Exposes: Initialize-ImmutableIdTool
#>

# ── Shared state ───────────────────────────────────────────────────────────────
$Script:IID_UI           = @{}
$Script:IID_Rows         = $null   # ObservableCollection[PSObject]
$Script:IID_CheckboxCol  = $null   # reference to col 0 for hit-testing
$Script:IID_LoadState    = @{ Done = $false; Users = $null; Error = $null }
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
      <Setter Property="Foreground" Value="#C2C2E0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>

    <Style TargetType="DataGrid">
      <Setter Property="Background"           Value="#1C1C2A"/>
      <Setter Property="Foreground"           Value="#E2E2F0"/>
      <Setter Property="BorderBrush"          Value="#3C3C5A"/>
      <Setter Property="BorderThickness"      Value="1"/>
      <Setter Property="RowBackground"        Value="Transparent"/>
      <Setter Property="AlternatingRowBackground" Value="#17172A"/>
      <Setter Property="GridLinesVisibility"  Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#23233A"/>
      <Setter Property="SelectionMode"        Value="Single"/>
      <Setter Property="SelectionUnit"        Value="FullRow"/>
      <Setter Property="CanUserAddRows"       Value="False"/>
      <Setter Property="CanUserDeleteRows"    Value="False"/>
      <Setter Property="CanUserResizeRows"    Value="False"/>
      <Setter Property="AutoGenerateColumns"  Value="False"/>
      <Setter Property="HeadersVisibility"    Value="Column"/>
      <Setter Property="ScrollViewer.CanContentScroll" Value="True"/>
    </Style>

    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background"    Value="#242436"/>
      <Setter Property="Foreground"    Value="#7878A0"/>
      <Setter Property="FontSize"      Value="11"/>
      <Setter Property="FontWeight"    Value="Bold"/>
      <Setter Property="Padding"       Value="10,8"/>
      <Setter Property="BorderBrush"   Value="#3C3C5A"/>
      <Setter Property="BorderThickness" Value="0,0,1,1"/>
    </Style>

    <Style TargetType="DataGridRow">
      <Setter Property="Cursor" Value="Hand"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#1E1E32"/>
        </Trigger>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#26264A"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="DataGridCell">
      <Setter Property="Padding"           Value="10,6"/>
      <Setter Property="BorderThickness"   Value="0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="FocusVisualStyle"  Value="{x:Null}"/>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="Transparent"/>
          <Setter Property="Foreground" Value="#E2E2F0"/>
        </Trigger>
      </Style.Triggers>
    </Style>

  </Grid.Resources>

  <Grid.RowDefinitions>
    <RowDefinition Height="Auto"/>
    <RowDefinition Height="Auto"/>
    <RowDefinition Height="*"/>
  </Grid.RowDefinitions>

  <!-- ── Title bar ──────────────────────────────────────────────────────── -->
  <Border Grid.Row="0" Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1"
          Padding="20,14">
    <StackPanel>
      <TextBlock Text="Immutable ID Assignment" Foreground="White"
                 FontSize="16" FontWeight="Bold"/>
      <TextBlock Margin="0,4,0,0" TextWrapping="Wrap" FontSize="12"
                 Foreground="#7878A0"
                 Text="Assign or remove the onPremisesImmutableId on cloud-only users. Use the checkboxes to select accounts, then generate and assign IDs — or remove an existing ID from selected users."/>
    </StackPanel>
  </Border>

  <!-- ── Filter toolbar ─────────────────────────────────────────────────── -->
  <Border Grid.Row="1" Background="#191927" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1"
          Padding="16,10">
    <WrapPanel Orientation="Horizontal">
      <CheckBox x:Name="IidChkEmptyOnly" Content="Show only users without an existing ImmutableId"
                IsChecked="True" Margin="0,0,24,0" VerticalAlignment="Center"/>
      <CheckBox x:Name="IidChkOverwrite"
                Content="Allow overwriting existing ImmutableIds  &#x26A0; permanent" Foreground="#F59E0B"
                IsChecked="False" VerticalAlignment="Center"/>
    </WrapPanel>
  </Border>

  <!-- ── Action toolbar ─────────────────────────────────────────────────── -->
  <Border Grid.Row="2" Background="#16162A" Padding="12,8">
    <DockPanel LastChildFill="False">

      <!-- Selection buttons + count -->
      <StackPanel DockPanel.Dock="Left" Orientation="Horizontal" VerticalAlignment="Center">
        <Button x:Name="IidBtnCheckAll" Content="Select All"
                Style="{StaticResource Btn}" Background="#3C3C5A" Padding="10,6"
                ToolTip="Mark every visible row for ID assignment"
                IsEnabled="False" Margin="0,0,6,0"/>
        <Button x:Name="IidBtnUncheckAll" Content="Deselect All"
                Style="{StaticResource Btn}" Background="#3C3C5A" Padding="10,6"
                ToolTip="Clear all row selections"
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
                Style="{StaticResource Btn}" Background="#D97706" Padding="12,7"
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

  <!-- ── DataGrid ───────────────────────────────────────────────────────── -->
  <DataGrid x:Name="IidGrid" Grid.Row="3" Margin="12,10">
    <DataGrid.Columns>

      <!-- col 0: Include checkbox. IsHitTestVisible=False so clicks bubble up -->
      <DataGridTemplateColumn Header="Include" Width="72" CanUserSort="True"
                              SortMemberPath="Selected">
        <DataGridTemplateColumn.CellTemplate>
          <DataTemplate>
            <CheckBox IsChecked="{Binding Selected, Mode=OneWay}"
                      IsHitTestVisible="False"
                      HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </DataTemplate>
        </DataGridTemplateColumn.CellTemplate>
      </DataGridTemplateColumn>

      <DataGridTextColumn Header="Display Name"         Binding="{Binding Name}"      Width="190"/>
      <DataGridTextColumn Header="User Principal Name"  Binding="{Binding Upn}"       Width="250"/>
      <DataGridTextColumn Header="Current ImmutableId"  Binding="{Binding CurrentId}" Width="210"
                          Foreground="#7878A0"/>
      <DataGridTextColumn Header="New ImmutableId (to be assigned)" Binding="{Binding NewId}" Width="*"/>

      <!-- Status with colour-coded text -->
      <DataGridTemplateColumn Header="Status" Width="120">
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
        CurrentId   = if ($CurrentId) { $CurrentId } else { '—' }
        HasExisting = [bool]$CurrentId
        NewId       = $NewId
        Status      = $Status
        Selected    = $Selected
    }
}

# ── Rebuild rows from raw load ─────────────────────────────────────────────────
function Rebuild-IidRows {
    if (-not $Script:IID_LoadState.Done -or -not $Script:IID_LoadState.Users) { return }
    $emptyOnly = $Script:IID_UI.ChkEmptyOnly.IsChecked

    # Preserve existing per-user selections and generated IDs
    $prevSel = @{}
    $prevNew = @{}
    if ($Script:IID_Rows) {
        foreach ($r in $Script:IID_Rows) {
            $prevSel[$r.Id] = $r.Selected
            $prevNew[$r.Id] = $r.NewId
        }
    }

    $Script:IID_Rows.Clear()
    foreach ($u in $Script:IID_LoadState.Users) {
        $cid = $u.onPremisesImmutableId
        if ($emptyOnly -and $cid) { continue }
        $defaultSel = -not [bool]$cid
        $sel = if ($prevSel.ContainsKey($u.id)) { $prevSel[$u.id] } else { $defaultSel }
        $nid = if ($prevNew.ContainsKey($u.id))  { $prevNew[$u.id]  } else { '' }
        $Script:IID_Rows.Add((New-IidRow -User $u -Selected $sel -CurrentId $cid -NewId $nid))
    }

    $Script:IID_UI.Grid.Items.Refresh()
    Update-IidCounts
}

# ── Count / button state ───────────────────────────────────────────────────────
function Update-IidCounts {
    $total      = $Script:IID_Rows.Count
    $checked    = ($Script:IID_Rows | Where-Object Selected).Count
    $ready      = ($Script:IID_Rows | Where-Object { $_.Selected -and $_.NewId -and $_.NewId -ne '' }).Count
    $removable  = ($Script:IID_Rows | Where-Object { $_.Selected -and $_.HasExisting }).Count

    $Script:IID_UI.LblCount.Text = "$total shown  ·  $checked selected  ·  $ready ready to assign"

    $anyPending = ($Script:IID_Rows | Where-Object { $_.Selected -and (-not $_.NewId -or $_.NewId -eq '') }).Count -gt 0
    $Script:IID_UI.BtnGenerate.IsEnabled = $anyPending
    $Script:IID_UI.BtnApply.IsEnabled    = $ready -gt 0
    $Script:IID_UI.BtnRemove.IsEnabled   = $removable -gt 0
}

# ── Select All / Deselect All ─────────────────────────────────────────────────
function Set-IidAllSelected {
    param([bool]$Value)
    foreach ($r in $Script:IID_Rows) { $r.Selected = $Value }
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
    $Script:IID_ApplyTimer = Start-AsyncWork -RefSeed @{ Results = @() } -Vars @{ Pending = $workItems } -Script {
        $out = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Pending) {
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
                        $row.Status      = 'Assigned'
                        $row.CurrentId   = $row.NewId
                        $row.NewId       = ''
                        $row.HasExisting = $true
                        $ok++
                    } else {
                        $row.Status = 'Error'
                        Write-IidLog "  Error on $($row.Name): $($res.Error)" 'Danger'
                        $err++
                    }
                }
                $Script:IID_UI.Grid.Items.Refresh()
                Write-IidLog "Done — $ok assigned, $err error(s)." 'Success'
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
    $Script:IID_ApplyTimer = Start-AsyncWork -RefSeed @{ Results = @() } -Vars @{ Pending = $workItems } -Script {
        $out = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Pending) {
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
                        $row.Status      = 'Removed'
                        $row.CurrentId   = '—'
                        $row.NewId       = ''
                        $row.HasExisting = $false
                        $ok++
                    } else {
                        $row.Status = 'Error'
                        Write-IidLog "  Error on $($row.Name): $($res.Error)" 'Danger'
                        $err++
                    }
                }
                $Script:IID_UI.Grid.Items.Refresh()
                Write-IidLog "Done — $ok removed, $err error(s)." 'Success'
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

# ── Load from Graph (async) ────────────────────────────────────────────────────
function Start-IidLoad {
    $Script:IID_Rows.Clear()
    $Script:IID_UI.Grid.Items.Refresh()
    $Script:IID_UI.LblCount.Text           = 'Loading users…'
    $Script:IID_UI.BtnGenerate.IsEnabled   = $false
    $Script:IID_UI.BtnApply.IsEnabled      = $false
    $Script:IID_UI.BtnCheckAll.IsEnabled   = $false
    $Script:IID_UI.BtnUncheckAll.IsEnabled = $false
    Write-IidLog 'Loading cloud-only users from Entra…' 'Accent'

    Request-EtbUsers -OnReady 'Complete-IidLoad'
}

function Complete-IidLoad {
    try {
        if ($Script:UserCache.Error) {
            Write-IidLog "Load failed: $($Script:UserCache.Error)" 'Danger'
            Write-Log "ImmutableId: load error: $($Script:UserCache.Error)" 'ERROR'
            $Script:IID_UI.LblCount.Text = 'Load failed.'
            return
        }
        $Script:IID_LoadState.Users = @($Script:UserCache.Users | Where-Object {
            $_.userType -eq 'Member' -and -not $_.onPremisesSyncEnabled
        })
        $Script:IID_LoadState.Done  = $true
        Write-Log "ImmutableId: loaded $($Script:IID_LoadState.Users.Count) cloud-only members" 'INFO'
        Rebuild-IidRows
        $Script:IID_UI.BtnCheckAll.IsEnabled   = $true
        $Script:IID_UI.BtnUncheckAll.IsEnabled = $true
        Write-IidLog "Loaded $($Script:IID_Rows.Count) user(s)." 'Success'
    } catch {
        Write-Log "ImmutableId load error: $_" 'ERROR'
    }
}

# ── Demo stubs ─────────────────────────────────────────────────────────────────
function Start-IidLoadDemo {
    $Script:IID_LoadState.Users = @(
        [PSCustomObject]@{ id='u1'; displayName='Alice Johnson'; userPrincipalName='alice@contoso.academy'; onPremisesImmutableId='';         onPremisesSyncEnabled=$false }
        [PSCustomObject]@{ id='u2'; displayName='Bob Smith';     userPrincipalName='bob@contoso.academy';   onPremisesImmutableId='';         onPremisesSyncEnabled=$false }
        [PSCustomObject]@{ id='u3'; displayName='Carol White';   userPrincipalName='carol@contoso.academy'; onPremisesImmutableId='abc123=='; onPremisesSyncEnabled=$false }
        [PSCustomObject]@{ id='u4'; displayName='Dave Brown';    userPrincipalName='dave@contoso.academy';  onPremisesImmutableId='';         onPremisesSyncEnabled=$false }
        [PSCustomObject]@{ id='u5'; displayName='Emma Davis';    userPrincipalName='emma@contoso.academy';  onPremisesImmutableId='xyz987=='; onPremisesSyncEnabled=$false }
    )
    $Script:IID_LoadState.Done = $true
    Rebuild-IidRows
    $Script:IID_UI.BtnCheckAll.IsEnabled   = $true
    $Script:IID_UI.BtnUncheckAll.IsEnabled = $true
    Write-IidLog '[DEMO] 5 Contoso Academy users loaded (2 already have an ImmutableId).' 'TextDim'
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

    $Script:IID_Rows = [System.Collections.ObjectModel.ObservableCollection[PSObject]]::new()
    $Script:IID_UI.Grid.ItemsSource = $Script:IID_Rows
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
        try { Rebuild-IidRows } catch { Write-Log "IID EmptyOnly checked error: $_" 'ERROR' }
    })
    $Script:IID_UI.ChkEmptyOnly.Add_Unchecked({
        try { Rebuild-IidRows } catch { Write-Log "IID EmptyOnly unchecked error: $_" 'ERROR' }
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
            $Script:IID_LoadState.Done  = $false
            $Script:IID_LoadState.Users = $null
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
