<#
    Bulk UPN / Domain Change tab for Art's Entra Toolbox.
    Dot-sourced by Start.ps1.
    Exposes Initialize-BulkUpnChangeTool.

    Moves cloud-only users to a different verified domain suffix.
    On-prem synced accounts (onPremisesSyncEnabled=true) are excluded —
    their UPN is owned by AD Connect and cannot be changed via Graph.
#>

$Script:BUC_UI         = $null
$Script:BUC_AllUsers   = @()
$Script:BUC_Rows       = New-Object System.Collections.ObjectModel.ObservableCollection[PSObject]
$Script:BUC_Domains    = @()
$Script:BUC_Depts      = @()
$Script:BUC_Offices    = @()
$Script:BUC_GroupData  = @()   # {Label, Field, AllUsers}
$Script:BUC_LoadTimer  = $null
$Script:BUC_ApplyTimer = $null

function Write-BucLog {
    param([string]$Msg, [string]$Color = 'TextDim')
    Write-AppLog $Msg $Color
}

function Update-BucGroupCombos {
    $Script:BUC_Depts = @($Script:BUC_AllUsers | Where-Object { $_.department } |
                          ForEach-Object { $_.department } | Sort-Object -Unique)
    $Script:BUC_UI.DeptCombo.Items.Clear()
    foreach ($dept in $Script:BUC_Depts) {
        $cnt  = ($Script:BUC_AllUsers | Where-Object { $_.department -eq $dept }).Count
        $item = [System.Windows.Controls.ComboBoxItem]::new()
        $item.Content = "$dept  ($cnt)"
        $item.Tag     = $dept
        [void]$Script:BUC_UI.DeptCombo.Items.Add($item)
    }
    $Script:BUC_UI.DeptCombo.IsEnabled  = ($Script:BUC_Depts.Count -gt 0)
    if ($Script:BUC_UI.DeptCombo.Items.Count -gt 0) {
        $Script:BUC_UI.DeptCombo.SelectedIndex = 0
        $Script:BUC_UI.BtnAddDept.IsEnabled    = $true
    }

    $Script:BUC_Offices = @($Script:BUC_AllUsers | Where-Object { $_.officeLocation } |
                             ForEach-Object { $_.officeLocation } | Sort-Object -Unique)
    $Script:BUC_UI.OfficeCombo.Items.Clear()
    foreach ($office in $Script:BUC_Offices) {
        $cnt  = ($Script:BUC_AllUsers | Where-Object { $_.officeLocation -eq $office }).Count
        $item = [System.Windows.Controls.ComboBoxItem]::new()
        $item.Content = "$office  ($cnt)"
        $item.Tag     = $office
        [void]$Script:BUC_UI.OfficeCombo.Items.Add($item)
    }
    $Script:BUC_UI.OfficeCombo.IsEnabled  = ($Script:BUC_Offices.Count -gt 0)
    if ($Script:BUC_UI.OfficeCombo.Items.Count -gt 0) {
        $Script:BUC_UI.OfficeCombo.SelectedIndex = 0
        $Script:BUC_UI.BtnAddOffice.IsEnabled    = $true
    }
}

function Add-BucByField {
    param([string]$Field, $ComboBox)
    $selItem = $ComboBox.SelectedItem
    if (-not $selItem) { return }
    $value = if ($selItem -is [System.Windows.Controls.ComboBoxItem]) { $selItem.Tag } else { $selItem.ToString() }
    if (-not $value) { return }

    $domain = if ($Script:BUC_UI.DomainCombo.SelectedItem) {
        $Script:BUC_UI.DomainCombo.SelectedItem.ToString()
    } else { '' }

    $added = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($r in $Script:BUC_Rows) { [void]$added.Add($r.Id) }

    $users = @($Script:BUC_AllUsers | Where-Object { $_.$Field -eq $value -and -not $added.Contains($_.id) })
    foreach ($u in $users) {
        $local = ($u.userPrincipalName -split '@')[0]
        [void]$Script:BUC_Rows.Add([PSCustomObject]@{
            Id     = $u.id
            Name   = $u.displayName
            OldUpn = $u.userPrincipalName
            NewUpn = if ($domain) { "$local@$domain" } else { '' }
            Status = 'Pending'
        })
    }
    Update-BucUserFilter
    Update-BucButtons
    $label = if ($Field -eq 'department') { 'department' } else { 'office location' }
    if ($users.Count -gt 0) {
        Write-BucLog "Added $($users.Count) user(s) from ${label}: $value" 'Text'
    } else {
        Write-BucLog "No new users to add for ${label}: $value (all already in list)." 'TextDim'
    }
}

function Update-BucUserFilter {
    $q = $Script:BUC_UI.Search.Text.Trim()
    $Script:BUC_UI.UserList.Items.Clear()

    $added = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($r in $Script:BUC_Rows) { [void]$added.Add($r.Id) }

    $list = if ([string]::IsNullOrWhiteSpace($q)) { $Script:BUC_AllUsers } else {
        $Script:BUC_AllUsers | Where-Object {
            $_.displayName -like "*$q*" -or $_.userPrincipalName -like "*$q*"
        }
    }
    foreach ($u in $list) {
        if ($added.Contains($u.id)) { continue }
        $lbi         = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Content = "$($u.displayName)  ($($u.userPrincipalName))"
        $lbi.Tag     = $u
        [void]$Script:BUC_UI.UserList.Items.Add($lbi)
    }
}

function Add-BucSelected {
    $domain = if ($Script:BUC_UI.DomainCombo.SelectedItem) {
        $Script:BUC_UI.DomainCombo.SelectedItem.ToString()
    } else { '' }

    foreach ($item in @($Script:BUC_UI.UserList.SelectedItems)) {
        $u     = $item.Tag
        $local = ($u.userPrincipalName -split '@')[0]
        $row   = [PSCustomObject]@{
            Id     = $u.id
            Name   = $u.displayName
            OldUpn = $u.userPrincipalName
            NewUpn = if ($domain) { "$local@$domain" } else { '' }
            Status = 'Pending'
        }
        [void]$Script:BUC_Rows.Add($row)
    }
    Update-BucUserFilter
    Update-BucButtons
}

function Update-BucNewUpns {
    $domain = if ($Script:BUC_UI.DomainCombo.SelectedItem) {
        $Script:BUC_UI.DomainCombo.SelectedItem.ToString()
    } else { '' }
    foreach ($r in $Script:BUC_Rows) {
        if ($r.Status -ne 'Pending') { continue }
        $local    = ($r.OldUpn -split '@')[0]
        $r.NewUpn = if ($domain) { "$local@$domain" } else { '' }
    }
    $Script:BUC_UI.PreviewGrid.Items.Refresh()
    Update-BucButtons
}

function Update-BucButtons {
    $hasDomain  = $null -ne $Script:BUC_UI.DomainCombo.SelectedItem
    $hasPending = ($Script:BUC_Rows | Where-Object { $_.Status -eq 'Pending' }).Count -gt 0
    $allHaveNew = ($Script:BUC_Rows | Where-Object { $_.Status -eq 'Pending' -and [string]::IsNullOrEmpty($_.NewUpn) }).Count -eq 0
    $Script:BUC_UI.BtnApply.IsEnabled  = ($hasDomain -and $hasPending -and $allHaveNew)
    $Script:BUC_UI.BtnClear.IsEnabled  = $Script:BUC_Rows.Count -gt 0
}

# ── Async load (users + verified domains) ─────────────────────────────────────
function Start-BucLoad {
    if ($Script:DemoMode) { Start-BucLoadDemo; return }

    $Script:BUC_UI.Search.IsEnabled   = $false
    $Script:BUC_UI.UserList.IsEnabled = $false
    $Script:BUC_UI.DomainCombo.Items.Clear()
    Write-BucLog 'Loading users and verified domains...' 'TextDim'

    if ($Script:BUC_LoadTimer) { $Script:BUC_LoadTimer.Stop() }
    $Script:BUC_LoadTimer = Start-AsyncWork -RefSeed @{ Users = $null; Domains = $null } -Script {
        $users = [System.Collections.Generic.List[object]]::new()
        $url   = 'https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName,onPremisesSyncEnabled,department,officeLocation&$top=999&$filter=accountEnabled eq true'
        do {
            $resp = Invoke-RestMethod -Uri $url `
                -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
            foreach ($u in $resp.value) {
                if (-not $u.onPremisesSyncEnabled) { $users.Add($u) }
            }
            $url = $resp.'@odata.nextLink'
        } while ($url)

        $dResp = Invoke-RestMethod `
            -Uri 'https://graph.microsoft.com/v1.0/domains?$select=id,isVerified' `
            -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
        $domains = @($dResp.value | Where-Object { $_.isVerified } | ForEach-Object { $_.id } | Sort-Object)

        $Ref['Users']   = $users.ToArray()
        $Ref['Domains'] = $domains
    } -OnComplete {
        param($ref)
        try {
            if ($ref['Error'] -eq '401') {
                Write-BucLog 'Session expired — reconnect via the tenant selector.' 'Danger'
                Set-MainStatus 'Session expired.' 'Danger'
                return
            }
            if ($ref['Error']) {
                Write-BucLog "Load error: $($ref['Error'])" 'Danger'
                return
            }

            $Script:BUC_AllUsers = @($ref['Users'] | Sort-Object { $_.displayName })
            $Script:BUC_Domains  = $ref['Domains']

            foreach ($d in $Script:BUC_Domains) { [void]$Script:BUC_UI.DomainCombo.Items.Add($d) }
            if ($Script:BUC_UI.DomainCombo.Items.Count -gt 0) {
                $Script:BUC_UI.DomainCombo.SelectedIndex = 0
            }

            Update-BucGroupCombos
            Update-BucUserFilter
            $Script:BUC_UI.Search.IsEnabled   = $true
            $Script:BUC_UI.UserList.IsEnabled = $true
            $n = $Script:BUC_AllUsers.Count; $nd = $Script:BUC_Domains.Count
            Write-BucLog "Loaded $n cloud-only user(s) and $nd verified domain(s)." 'Success'
            Set-MainStatus "BUC: $n users loaded." 'Success'
        } catch {
            Write-Log "BUC load-timer error: $_" 'ERROR'
        }
    }
}

# ── Async apply ───────────────────────────────────────────────────────────────
function Start-BucApply {
    $pending = @($Script:BUC_Rows | Where-Object { $_.Status -eq 'Pending' })
    if ($pending.Count -eq 0) { return }

    if ($Script:DryMode) {
        Write-BucLog "[DRY] Would change UPN domain for $($pending.Count) user(s):" 'Warning'
        foreach ($p in $pending) { Write-BucLog "  $($p.OldUpn) → $($p.NewUpn)" 'Warning' }
        Write-Log "BUC: dry run - would change $($pending.Count) UPNs" 'INFO'
        return
    }

    $work    = @($pending | ForEach-Object {
        @{ Id = $_.Id; OldUpn = $_.OldUpn; NewUpn = $_.NewUpn }
    })

    $Script:BUC_UI.BtnApply.IsEnabled = $false
    Write-BucLog "Changing UPN domain for $($pending.Count) user(s)..." 'TextDim'

    if ($Script:BUC_ApplyTimer) { $Script:BUC_ApplyTimer.Stop() }
    $Script:BUC_ApplyTimer = Start-AsyncWork -RefSeed @{ Results = @() } -Vars @{ Pending = $work } -IntervalMs 500 -Script {
        $out = [System.Collections.Generic.List[object]]::new()
        foreach ($r in $Pending) {
            $res = @{ Id = $r.Id; OldUpn = $r.OldUpn; NewUpn = $r.NewUpn; Ok = $false; Err = '' }
            try {
                $escaped = $r.NewUpn -replace '\\','\\' -replace '"','\"'
                $body    = "{`"userPrincipalName`":`"$escaped`"}"
                Invoke-RestMethod `
                    -Uri "https://graph.microsoft.com/v1.0/users/$($r.Id)" `
                    -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } `
                    -Method PATCH -Body $body -ErrorAction Stop
                $res['Ok'] = $true
            } catch {
                $res['Err'] = $_.Exception.Message
            }
            $out.Add($res)
        }
        $Ref['Results'] = $out.ToArray()
    } -OnComplete {
        param($ref)
        try {
            $ok = 0; $fail = 0
            foreach ($res in $ref['Results']) {
                $row = $Script:BUC_Rows | Where-Object { $_.Id -eq $res['Id'] } | Select-Object -First 1
                if ($res['Ok']) {
                    $ok++
                    Write-BucLog "Changed: $($res['OldUpn'])  →  $($res['NewUpn'])" 'Success'
                    if ($row) { $row.Status = 'Done' }
                } else {
                    $fail++
                    Write-BucLog "Failed:  $($res['OldUpn']) — $($res['Err'])" 'Danger'
                    if ($row) { $row.Status = 'Error' }
                }
            }
            $Script:BUC_UI.PreviewGrid.Items.Refresh()
            $summary = "Done — changed: $ok  failed: $fail"
            Write-BucLog $summary 'Text'
            Set-MainStatus $summary (if ($fail -gt 0) { 'Warning' } else { 'Success' })
            Update-BucButtons
        } catch {
            Write-Log "BUC apply-timer error: $_" 'ERROR'
        }
    }
}

# ── Demo stubs ─────────────────────────────────────────────────────────────────
function Start-BucLoadDemo {
    $Script:BUC_AllUsers = @(
        [PSCustomObject]@{ id='d1'; displayName='Alice Smith';  userPrincipalName='alice@contoso.edu';  department='Year 10'; officeLocation='Main Building' }
        [PSCustomObject]@{ id='d2'; displayName='Bob Jones';    userPrincipalName='bob@contoso.edu';    department='Year 10'; officeLocation='Main Building' }
        [PSCustomObject]@{ id='d3'; displayName='Carol White';  userPrincipalName='carol@contoso.edu';  department='Year 11'; officeLocation='Sixth Form Centre' }
        [PSCustomObject]@{ id='d4'; displayName='Dave Black';   userPrincipalName='dave@contoso.edu';   department='Year 11'; officeLocation='Sixth Form Centre' }
        [PSCustomObject]@{ id='d5'; displayName='Eve Green';    userPrincipalName='eve@contoso.edu';    department='Staff';   officeLocation='Admin Block' }
        [PSCustomObject]@{ id='d6'; displayName='Frank Hall';   userPrincipalName='frank@contoso.edu';  department='Staff';   officeLocation='Admin Block' }
    )
    $Script:BUC_Domains = @('contoso.edu', 'contoso.ac.uk', 'students.contoso.edu')
    $Script:BUC_UI.DomainCombo.Items.Clear()
    foreach ($d in $Script:BUC_Domains) { [void]$Script:BUC_UI.DomainCombo.Items.Add($d) }
    $Script:BUC_UI.DomainCombo.SelectedIndex = 0
    Update-BucGroupCombos
    Update-BucUserFilter
    $Script:BUC_UI.Search.IsEnabled   = $true
    $Script:BUC_UI.UserList.IsEnabled = $true
    Write-BucLog "Demo: loaded $($Script:BUC_AllUsers.Count) users and $($Script:BUC_Domains.Count) domains." 'Success'
}

function Start-BucApplyDemo {
    $pending = @($Script:BUC_Rows | Where-Object { $_.Status -eq 'Pending' })
    Write-BucLog "Demo: simulating UPN change for $($pending.Count) user(s)..." 'TextDim'
    foreach ($r in $pending) {
        Write-BucLog "Demo changed: $($r.OldUpn)  →  $($r.NewUpn)" 'Success'
        $r.Status = 'Done'
    }
    $Script:BUC_UI.PreviewGrid.Items.Refresh()
    Write-BucLog 'Demo complete.' 'Text'
    Update-BucButtons
}

# ── XAML ───────────────────────────────────────────────────────────────────────
$Script:BucXaml = @'
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

    <Style TargetType="ComboBox">
      <Setter Property="Background"        Value="#242436"/>
      <Setter Property="Foreground"        Value="#E2E2F0"/>
      <Setter Property="BorderBrush"       Value="#3C3C5A"/>
      <Setter Property="BorderThickness"   Value="1"/>
      <Setter Property="Height"            Value="32"/>
      <Setter Property="Padding"           Value="8,0"/>
      <Setter Property="MaxDropDownHeight" Value="200"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <Border x:Name="bd" CornerRadius="4"
                      Background="{TemplateBinding Background}"
                      BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="{TemplateBinding BorderThickness}"/>
              <ContentPresenter Margin="{TemplateBinding Padding}"
                                VerticalAlignment="Center" HorizontalAlignment="Left"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentStringFormat="{TemplateBinding SelectionBoxItemStringFormat}"
                                IsHitTestVisible="False"/>
              <Path x:Name="arrow" Data="M0,0 L4,4 L8,0 Z" Fill="#7878A0"
                    HorizontalAlignment="Right" VerticalAlignment="Center"
                    Margin="0,0,10,0" IsHitTestVisible="False"/>
              <ToggleButton Focusable="False" Cursor="Hand"
                            IsChecked="{Binding IsDropDownOpen,
                                        RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Rectangle Fill="Transparent"/>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <Popup x:Name="PART_Popup" AllowsTransparency="True"
                     IsOpen="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}}"
                     Placement="Bottom" PopupAnimation="Slide">
                <Border Background="#242436" BorderBrush="#3C3C5A" BorderThickness="1"
                        CornerRadius="0,0,4,4" MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <ScrollViewer><ItemsPresenter/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#6366F1"/>
              </Trigger>
              <Trigger Property="IsDropDownOpen" Value="True">
                <Setter TargetName="bd"    Property="CornerRadius" Value="4,4,0,0"/>
                <Setter TargetName="arrow" Property="Fill"         Value="#E2E2F0"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="#1C1C2A"/>
                <Setter Property="Foreground" Value="#3C3C5A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#E2E2F0"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding"    Value="10,7"/>
      <Setter Property="Cursor"     Value="Hand"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#2E2E48"/>
        </Trigger>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#6366F1"/>
          <Setter Property="Foreground" Value="White"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="DataGrid">
      <Setter Property="Background"               Value="#12121C"/>
      <Setter Property="Foreground"               Value="#E2E2F0"/>
      <Setter Property="BorderThickness"          Value="0"/>
      <Setter Property="GridLinesVisibility"      Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#1E1E32"/>
      <Setter Property="RowBackground"            Value="#12121C"/>
      <Setter Property="AlternatingRowBackground" Value="#181826"/>
      <Setter Property="ColumnHeaderHeight"       Value="34"/>
      <Setter Property="RowHeight"                Value="28"/>
      <Setter Property="AutoGenerateColumns"      Value="False"/>
      <Setter Property="CanUserAddRows"           Value="False"/>
      <Setter Property="CanUserDeleteRows"        Value="False"/>
      <Setter Property="IsReadOnly"               Value="True"/>
      <Setter Property="SelectionMode"            Value="Extended"/>
      <Setter Property="SelectionUnit"            Value="FullRow"/>
      <Setter Property="CanUserSortColumns"       Value="True"/>
      <Setter Property="FontSize"                 Value="12"/>
    </Style>

    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background"      Value="#1C1C2A"/>
      <Setter Property="Foreground"      Value="#7878A0"/>
      <Setter Property="FontWeight"      Value="SemiBold"/>
      <Setter Property="Padding"         Value="12,0"/>
      <Setter Property="BorderBrush"     Value="#3C3C5A"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="FontSize"        Value="11"/>
      <Setter Property="Cursor"          Value="Hand"/>
    </Style>

    <Style TargetType="DataGridRow">
      <Setter Property="Background" Value="Transparent"/>
      <Style.Triggers>
        <Trigger Property="IsSelected"  Value="True">
          <Setter Property="Background" Value="#2A2A50"/>
        </Trigger>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#1E1E38"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding"         Value="12,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Padding="{TemplateBinding Padding}" Background="{TemplateBinding Background}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

  </Grid.Resources>

  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="280" MinWidth="200"/>
    <ColumnDefinition Width="5"/>
    <ColumnDefinition Width="*"/>
  </Grid.ColumnDefinitions>

  <GridSplitter Grid.Column="1" Width="5" HorizontalAlignment="Stretch"
                Background="#3C3C5A" Cursor="SizeWE" ResizeBehavior="PreviousAndNext"/>

  <!-- ── Left sidebar: user picker ──────────────────────────────────────────── -->
  <Border Grid.Column="0" Background="#1C1C2A">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- Group import: by department and by office location -->
      <Border Grid.Row="0" Padding="12,12,12,10" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
        <StackPanel>
          <TextBlock Text="BY DEPARTMENT" Foreground="#50507A" FontSize="10"
                     FontWeight="Bold" Margin="0,0,0,6"/>
          <ComboBox x:Name="BucDeptCombo" IsEnabled="False"/>
          <Button x:Name="BucBtnAddDept" Content="Add All  →" IsEnabled="False"
                  Style="{StaticResource PrimaryBtn}" Background="#6366F1"
                  Padding="12,8" Margin="0,6,0,0" HorizontalAlignment="Stretch"/>

          <TextBlock Text="BY OFFICE LOCATION" Foreground="#50507A" FontSize="10"
                     FontWeight="Bold" Margin="0,14,0,6"/>
          <ComboBox x:Name="BucOfficeCombo" IsEnabled="False"/>
          <Button x:Name="BucBtnAddOffice" Content="Add All  →" IsEnabled="False"
                  Style="{StaticResource PrimaryBtn}" Background="#6366F1"
                  Padding="12,8" Margin="0,6,0,0" HorizontalAlignment="Stretch"/>
        </StackPanel>
      </Border>

      <!-- Individual search -->
      <Border Grid.Row="1" Padding="12,10" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
        <StackPanel>
          <TextBlock Text="INDIVIDUAL SEARCH" Foreground="#50507A" FontSize="10"
                     FontWeight="Bold" Margin="0,0,0,8"/>
          <TextBox x:Name="BucSearch" IsEnabled="False" Height="34"
                   ToolTip="Filter by name or UPN"/>
        </StackPanel>
      </Border>

      <ListBox x:Name="BucUserList" Grid.Row="2" IsEnabled="False"
               SelectionMode="Extended"
               ScrollViewer.HorizontalScrollBarVisibility="Disabled"
               VirtualizingPanel.IsVirtualizing="True"
               VirtualizingPanel.VirtualizationMode="Recycling"
               Margin="0,2,0,2"/>

      <Border Grid.Row="3" Padding="10,8" BorderBrush="#3C3C5A" BorderThickness="0,1,0,0">
        <Button x:Name="BucBtnAdd" Content="Add Selected  →" IsEnabled="False"
                Style="{StaticResource PrimaryBtn}" Background="#6366F1"
                Padding="12,8" HorizontalAlignment="Stretch"/>
      </Border>
    </Grid>
  </Border>

  <!-- ── Right panel ────────────────────────────────────────────────────────── -->
  <Grid Grid.Column="2">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="170"/>
    </Grid.RowDefinitions>

    <!-- Action bar -->
    <Border Grid.Row="0" Background="#1C1C2A" BorderBrush="#3C3C5A"
            BorderThickness="0,0,0,1" Padding="16,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="220"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="8"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="8"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <TextBlock Grid.Column="0" Text="Target domain:" Foreground="#7878A0"
                   VerticalAlignment="Center" Margin="0,0,10,0" FontSize="12"/>
        <ComboBox x:Name="BucDomainCombo" Grid.Column="1"/>
        <!-- spacer col 2 -->
        <Button x:Name="BucBtnRemove" Grid.Column="3" Content="Remove"
                Style="{StaticResource PrimaryBtn}" Background="#3C3C5A"
                Padding="14,8" IsEnabled="False"
                ToolTip="Remove selected rows from the preview"/>
        <Button x:Name="BucBtnClear" Grid.Column="5" Content="Clear All"
                Style="{StaticResource PrimaryBtn}" Background="#3C3C5A"
                Padding="14,8" IsEnabled="False"
                ToolTip="Remove all pending rows"/>
        <Button x:Name="BucBtnApply" Grid.Column="7" Content="Apply Changes"
                Style="{StaticResource PrimaryBtn}" Background="#EF4444"
                Padding="18,8" IsEnabled="False"
                ToolTip="Rename UPNs for all pending rows"/>
      </Grid>
    </Border>

    <!-- Preview grid -->
    <DataGrid x:Name="BucPreviewGrid" Grid.Row="1" Margin="0">
      <DataGrid.Columns>
        <DataGridTextColumn Header="Display Name" Binding="{Binding Name}"   Width="180"/>
        <DataGridTextColumn Header="Current UPN"  Binding="{Binding OldUpn}" Width="*"/>
        <DataGridTextColumn Header="New UPN"       Binding="{Binding NewUpn}" Width="*"/>
        <DataGridTextColumn Header="Status"        Binding="{Binding Status}" Width="70"/>
      </DataGrid.Columns>
    </DataGrid>

  </Grid>

</Grid>
'@

# ── Initialize ─────────────────────────────────────────────────────────────────
function Initialize-BulkUpnChangeTool {
    $reader  = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new((Invoke-ThemeXaml $Script:BucXaml)))
    $content = [System.Windows.Markup.XamlReader]::Load($reader)

    $Script:BUC_UI = @{
        DeptCombo   = $content.FindName('BucDeptCombo')
        BtnAddDept  = $content.FindName('BucBtnAddDept')
        OfficeCombo = $content.FindName('BucOfficeCombo')
        BtnAddOffice= $content.FindName('BucBtnAddOffice')
        Search      = $content.FindName('BucSearch')
        UserList    = $content.FindName('BucUserList')
        BtnAdd      = $content.FindName('BucBtnAdd')
        DomainCombo = $content.FindName('BucDomainCombo')
        PreviewGrid = $content.FindName('BucPreviewGrid')
        BtnRemove   = $content.FindName('BucBtnRemove')
        BtnClear    = $content.FindName('BucBtnClear')
        BtnApply    = $content.FindName('BucBtnApply')
        # LogBox removed — use Write-AppLog to the global Log pane
    }

    $Script:BUC_UI.PreviewGrid.ItemsSource = $Script:BUC_Rows

    $Script:BUC_UI.Search.Add_TextChanged({
        try { Update-BucUserFilter }
        catch { Write-Log "BUC Search TextChanged error: $_" 'ERROR' }
    })

    $Script:BUC_UI.UserList.Add_SelectionChanged({
        try {
            $Script:BUC_UI.BtnAdd.IsEnabled = $Script:BUC_UI.UserList.SelectedItems.Count -gt 0
        } catch { Write-Log "BUC UserList SelectionChanged error: $_" 'ERROR' }
    })

    $Script:BUC_UI.BtnAdd.Add_Click({
        try { Add-BucSelected }
        catch { Write-Log "BUC BtnAdd click error: $_" 'ERROR' }
    })

    $Script:BUC_UI.BtnAddDept.Add_Click({
        try { Add-BucByField -Field 'department' -ComboBox $Script:BUC_UI.DeptCombo }
        catch { Write-Log "BUC BtnAddDept click error: $_" 'ERROR' }
    })

    $Script:BUC_UI.BtnAddOffice.Add_Click({
        try { Add-BucByField -Field 'officeLocation' -ComboBox $Script:BUC_UI.OfficeCombo }
        catch { Write-Log "BUC BtnAddOffice click error: $_" 'ERROR' }
    })

    $Script:BUC_UI.DomainCombo.Add_SelectionChanged({
        try { Update-BucNewUpns }
        catch { Write-Log "BUC DomainCombo SelectionChanged error: $_" 'ERROR' }
    })

    $Script:BUC_UI.PreviewGrid.Add_SelectionChanged({
        try {
            $Script:BUC_UI.BtnRemove.IsEnabled = $Script:BUC_UI.PreviewGrid.SelectedItems.Count -gt 0
        } catch { Write-Log "BUC PreviewGrid SelectionChanged error: $_" 'ERROR' }
    })

    $Script:BUC_UI.BtnRemove.Add_Click({
        try {
            foreach ($r in @($Script:BUC_UI.PreviewGrid.SelectedItems)) {
                [void]$Script:BUC_Rows.Remove($r)
            }
            Update-BucUserFilter
            Update-BucButtons
            $Script:BUC_UI.BtnRemove.IsEnabled = $false
        } catch { Write-Log "BUC BtnRemove click error: $_" 'ERROR' }
    })

    $Script:BUC_UI.BtnClear.Add_Click({
        try {
            $Script:BUC_Rows.Clear()
            Update-BucUserFilter
            Update-BucButtons
            $Script:BUC_UI.BtnRemove.IsEnabled = $false
        } catch { Write-Log "BUC BtnClear click error: $_" 'ERROR' }
    })

    $Script:BUC_UI.BtnApply.Add_Click({
        try {
            $pending = @($Script:BUC_Rows | Where-Object { $_.Status -eq 'Pending' })
            if ($pending.Count -eq 0) { return }

            $domain = $Script:BUC_UI.DomainCombo.SelectedItem.ToString()
            $msg    = "WARNING — this can break things!`n`n" +
                      "You are about to change the UPN domain for $($pending.Count) user(s) to @$domain.`n`n" +
                      "Consequences:`n" +
                      "  • All active sessions and refresh tokens are immediately invalidated`n" +
                      "  • The sign-in name changes right now — users may be unable to sign in`n" +
                      "    until they update saved passwords and app connections`n" +
                      "  • Apps or integrations that hard-code UPNs will break`n" +
                      "  • If Azure AD Connect is running it may revert these changes`n`n" +
                      "Are you absolutely sure you want to continue?"
            $result = [System.Windows.MessageBox]::Show(
                $msg, 'Confirm Bulk UPN Domain Change',
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning)
            if ($result -ne [System.Windows.MessageBoxResult]::Yes) { return }

            if ($Script:DemoMode) { Start-BucApplyDemo; return }
            Start-BucApply
        } catch { Write-Log "BUC BtnApply click error: $_" 'ERROR' }
    })

    Register-ConnectCallback 'Start-BucLoad'
    $Script:ResetCallbacks.Add({
        if ($Script:BUC_LoadTimer)  { $Script:BUC_LoadTimer.Stop();  $Script:BUC_LoadTimer  = $null }
        if ($Script:BUC_ApplyTimer) { $Script:BUC_ApplyTimer.Stop(); $Script:BUC_ApplyTimer = $null }
        $Script:BUC_AllUsers = @()
        $Script:BUC_Domains  = @()
        $Script:BUC_Depts    = @()
        $Script:BUC_Offices  = @()
        $Script:BUC_Rows.Clear()
        $Script:BUC_UI.DeptCombo.Items.Clear()
        $Script:BUC_UI.DeptCombo.IsEnabled    = $false
        $Script:BUC_UI.BtnAddDept.IsEnabled   = $false
        $Script:BUC_UI.OfficeCombo.Items.Clear()
        $Script:BUC_UI.OfficeCombo.IsEnabled   = $false
        $Script:BUC_UI.BtnAddOffice.IsEnabled  = $false
        $Script:BUC_UI.Search.Text             = ''
        $Script:BUC_UI.Search.IsEnabled        = $false
        $Script:BUC_UI.UserList.Items.Clear()
        $Script:BUC_UI.UserList.IsEnabled      = $false
        $Script:BUC_UI.DomainCombo.Items.Clear()
        $Script:BUC_UI.BtnAdd.IsEnabled        = $false
        $Script:BUC_UI.BtnRemove.IsEnabled     = $false
        $Script:BUC_UI.BtnClear.IsEnabled      = $false
        $Script:BUC_UI.BtnApply.IsEnabled      = $false
    })

    Write-BucLog 'Bulk UPN Change ready. Connect to a tenant to begin.' 'Muted'
    return $content
}
