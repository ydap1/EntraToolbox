<#
    Licence Assignment for Art's Entra Toolbox.
    Dot-sourced by Start.ps1. Exposes Initialize-LicenceAssignmentTool.

    Left: user search list. Right: two panels — assigned licences and
    available tenant SKUs. Remove/Assign act on the selected list row.
#>

$Script:LA_UI       = $null
$Script:LA_AllUsers = @()
$Script:LA_AllSkus  = @()
$Script:LA_User     = $null

$Script:LA_UserTimer = $null
$Script:LA_SkuTimer  = $null
$Script:LA_LicTimer  = $null
$Script:LA_ActTimer  = $null

$Script:LA_SkuNames = @{
    STANDARDWOFFPACK_IW_STUDENT = 'Microsoft 365 A1 for Students'
    STANDARDWOFFPACK_FACULTY    = 'Microsoft 365 A1 for Faculty'
    M365EDU_A3_STUUSEBNFT       = 'Microsoft 365 A3 for Students'
    M365EDU_A3_FACULTY          = 'Microsoft 365 A3 for Faculty'
    M365EDU_A5_STUUSEBNFT       = 'Microsoft 365 A5 for Students'
    M365EDU_A5_FACULTY          = 'Microsoft 365 A5 for Faculty'
    ENTERPRISEPACK              = 'Office 365 E3'
    ENTERPRISEPREMIUM           = 'Office 365 E5'
    SPE_E3                      = 'Microsoft 365 E3'
    SPE_E5                      = 'Microsoft 365 E5'
    INTUNE_A                    = 'Microsoft Intune'
}

function Get-LaName([string]$Part) {
    if ($Script:LA_SkuNames.ContainsKey($Part)) { return $Script:LA_SkuNames[$Part] }
    return $Part
}

function Write-LaLog([string]$Msg, [string]$Color = 'TextDim') { Write-AppLog $Msg $Color }

# ── User load ──────────────────────────────────────────────────────────────────
function Start-LaUserLoad {
    if ($Script:DemoMode) { Start-LaUserLoadDemo; return }
    if (-not $Script:LA_UI) { return }
    $Script:LA_UI.UserSearch.IsEnabled = $false
    $Script:LA_UI.UserList.IsEnabled   = $false
    Write-LaLog 'Loading users...' 'TextDim'
    if ($Script:LA_UserTimer) { $Script:LA_UserTimer.Stop() }
    $Script:LA_UserTimer = Start-AsyncWork -RefSeed @{ Users = $null } -Script {
        $list = [System.Collections.Generic.List[object]]::new()
        $url  = 'https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName&$top=999&$filter=accountEnabled eq true'
        do {
            $r = Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
            foreach ($u in $r.value) { $list.Add($u) }
            $url = $r.'@odata.nextLink'
        } while ($url)
        $Ref['Users'] = $list.ToArray()
    } -OnComplete {
        param($ref)
        try {
            if ($ref['Error'] -eq '401') { Write-LaLog 'Session expired.' 'Danger'; return }
            if ($ref['Error'])           { Write-LaLog "Users: $($ref['Error'])" 'Danger'; return }
            $Script:LA_AllUsers = @($ref['Users'] | Sort-Object displayName)
            Update-LaFilter
            $Script:LA_UI.UserSearch.IsEnabled = $true
            $Script:LA_UI.UserList.IsEnabled   = $true
            Write-LaLog "Loaded $($Script:LA_AllUsers.Count) users." 'Success'
        } catch { Write-Log "LA user-load: $_" 'ERROR' }
    }
}

# ── SKU load ───────────────────────────────────────────────────────────────────
function Start-LaSkuLoad {
    if ($Script:DemoMode) { Start-LaSkuLoadDemo; return }
    if (-not $Script:LA_UI) { return }
    if ($Script:LA_SkuTimer) { $Script:LA_SkuTimer.Stop() }
    $Script:LA_SkuTimer = Start-AsyncWork -RefSeed @{ Skus = $null } -Script {
        $r = Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus' `
            -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
        $Ref['Skus'] = $r.value
    } -OnComplete {
        param($ref)
        try {
            if ($ref['Error']) { Write-LaLog "SKUs: $($ref['Error'])" 'Danger'; return }
            $Script:LA_AllSkus = @($ref['Skus'])
        } catch { Write-Log "LA sku-load: $_" 'ERROR' }
    }
}

function Update-LaFilter {
    $q = $Script:LA_UI.UserSearch.Text.Trim()
    $Script:LA_UI.UserList.Items.Clear()
    $src = if ([string]::IsNullOrWhiteSpace($q)) { $Script:LA_AllUsers } else {
        $Script:LA_AllUsers | Where-Object { $_.displayName -like "*$q*" -or $_.userPrincipalName -like "*$q*" }
    }
    foreach ($u in $src) {
        $i         = [System.Windows.Controls.ListBoxItem]::new()
        $i.Content = $u.displayName
        $i.ToolTip = $u.userPrincipalName
        $i.Tag     = $u
        [void]$Script:LA_UI.UserList.Items.Add($i)
    }
}

# ── Licence load for selected user ─────────────────────────────────────────────
function Start-LaLicLoad {
    param([string]$UserId)
    if ($Script:DemoMode) { Start-LaLicLoadDemo; return }
    Clear-LaLists
    $Script:LA_UI.AssignedHeader.Text  = 'Loading...'
    $Script:LA_UI.AvailableHeader.Text = 'Available'
    if ($Script:LA_LicTimer) { $Script:LA_LicTimer.Stop() }
    $Script:LA_LicTimer = Start-AsyncWork -Vars @{ UserId = $UserId } -RefSeed @{ Assigned = $null } -Script {
        $r = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$UserId/licenseDetails" `
            -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
        $Ref['Assigned'] = $r.value
    } -OnComplete {
        param($ref)
        try {
            if ($ref['Error']) { Write-LaLog "Licence load: $($ref['Error'])" 'Danger'; $Script:LA_UI.AssignedHeader.Text = 'Error'; return }
            $assigned = @($ref['Assigned'])

            # Build a plain hashtable keyed by skuId — avoids HashSet constructor ambiguity
            $assignedMap = @{}
            foreach ($l in $assigned) { $assignedMap[$l.skuId] = $l.skuPartNumber }

            # Populate assigned list
            $Script:LA_UI.AssignedList.Items.Clear()
            foreach ($l in $assigned | Sort-Object skuPartNumber) {
                $lbi         = [System.Windows.Controls.ListBoxItem]::new()
                $lbi.Content = Get-LaName $l.skuPartNumber
                $lbi.ToolTip = $l.skuPartNumber
                $lbi.Tag     = $l.skuId
                [void]$Script:LA_UI.AssignedList.Items.Add($lbi)
            }
            $Script:LA_UI.AssignedHeader.Text = "Assigned ($($assigned.Count))"

            # Populate available list (tenant pool minus already-assigned)
            $Script:LA_UI.AvailableList.Items.Clear()
            $dangerBrush = New-SolidBrush 'Danger'
            $dimBrush    = New-SolidBrush 'TextDim'
            $availCount  = 0
            foreach ($sku in $Script:LA_AllSkus | Sort-Object skuPartNumber) {
                if ($assignedMap.ContainsKey($sku.skuId)) { continue }
                $seats       = $sku.prepaidUnits.enabled - $sku.consumedUnits
                $lbi         = [System.Windows.Controls.ListBoxItem]::new()
                $lbi.Content = "$(Get-LaName $sku.skuPartNumber)   ($seats seats)"
                $lbi.ToolTip = $sku.skuPartNumber
                $lbi.Tag     = @{ SkuId = $sku.skuId; Seats = $seats }
                if ($seats -le 0) { $lbi.Foreground = $dangerBrush } else { $lbi.Foreground = $dimBrush }
                [void]$Script:LA_UI.AvailableList.Items.Add($lbi)
                $availCount++
            }
            $Script:LA_UI.AvailableHeader.Text = "Available ($availCount)"

            Update-LaButtons
        } catch { Write-Log "LA lic-load complete: $_" 'ERROR' }
    }
}

function Clear-LaLists {
    $Script:LA_UI.AssignedList.Items.Clear()
    $Script:LA_UI.AvailableList.Items.Clear()
    $Script:LA_UI.AssignedHeader.Text  = 'Assigned'
    $Script:LA_UI.AvailableHeader.Text = 'Available'
    Update-LaButtons
}

function Update-LaButtons {
    $hasSel  = $null -ne $Script:LA_UI.AssignedList.SelectedItem
    $Script:LA_UI.BtnRemove.IsEnabled = $hasSel

    $avSel   = $Script:LA_UI.AvailableList.SelectedItem
    $hasSeats = $avSel -and $avSel.Tag.Seats -gt 0
    $Script:LA_UI.BtnAssign.IsEnabled = $hasSeats
}

# ── Assign ─────────────────────────────────────────────────────────────────────
function Start-LaAssign {
    $sel = $Script:LA_UI.AvailableList.SelectedItem
    if (-not $sel -or -not $Script:LA_User) { return }
    $skuId = $sel.Tag.SkuId
    $userId = $Script:LA_User.id
    if ($Script:DryMode) { Write-LaLog "[DRY] Would assign $($sel.Content) to $($Script:LA_User.displayName)" 'Warning'; return }
    Write-LaLog "Assigning $($sel.Content)..." 'TextDim'
    $Script:LA_UI.BtnAssign.IsEnabled = $false
    if ($Script:LA_ActTimer) { $Script:LA_ActTimer.Stop() }
    $Script:LA_ActTimer = Start-AsyncWork -Vars @{ UserId = $userId; SkuId = $skuId } -RefSeed @{ Ok = $false } -Script {
        $body = '{"addLicenses":[{"skuId":"' + $SkuId + '"}],"removeLicenses":[]}'
        Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$UserId/assignLicense" `
            -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } `
            -Method POST -Body $body -ErrorAction Stop | Out-Null
        $Ref['Ok'] = $true
    } -OnComplete {
        param($ref)
        try {
            if ($ref['Error']) { Write-LaLog "Assign failed: $($ref['Error'])" 'Danger'; Update-LaButtons; return }
            Write-LaLog 'Licence assigned.' 'Success'
            Start-LaLicLoad -UserId $Script:LA_User.id
        } catch { Write-Log "LA assign: $_" 'ERROR' }
    }
}

# ── Remove ─────────────────────────────────────────────────────────────────────
function Start-LaRemove {
    $sel = $Script:LA_UI.AssignedList.SelectedItem
    if (-not $sel -or -not $Script:LA_User) { return }
    $skuId  = $sel.Tag
    $userId = $Script:LA_User.id
    if ($Script:DryMode) { Write-LaLog "[DRY] Would remove $($sel.Content) from $($Script:LA_User.displayName)" 'Warning'; return }
    Write-LaLog "Removing $($sel.Content)..." 'TextDim'
    $Script:LA_UI.BtnRemove.IsEnabled = $false
    if ($Script:LA_ActTimer) { $Script:LA_ActTimer.Stop() }
    $Script:LA_ActTimer = Start-AsyncWork -Vars @{ UserId = $userId; SkuId = $skuId } -RefSeed @{ Ok = $false } -Script {
        $body = '{"addLicenses":[],"removeLicenses":["' + $SkuId + '"]}'
        Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$UserId/assignLicense" `
            -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } `
            -Method POST -Body $body -ErrorAction Stop | Out-Null
        $Ref['Ok'] = $true
    } -OnComplete {
        param($ref)
        try {
            if ($ref['Error']) { Write-LaLog "Remove failed: $($ref['Error'])" 'Danger'; Update-LaButtons; return }
            Write-LaLog 'Licence removed.' 'Success'
            Start-LaLicLoad -UserId $Script:LA_User.id
        } catch { Write-Log "LA remove: $_" 'ERROR' }
    }
}

# ── Demo ───────────────────────────────────────────────────────────────────────
function Start-LaUserLoadDemo {
    $Script:LA_AllUsers = @($Script:Demo_Users | Select-Object -First 12)
    Update-LaFilter
    $Script:LA_UI.UserSearch.IsEnabled = $true
    $Script:LA_UI.UserList.IsEnabled   = $true
    Write-LaLog 'Demo: users loaded.' 'Muted'
}

function Start-LaSkuLoadDemo {
    $Script:LA_AllSkus = @(
        [PSCustomObject]@{ skuId='s1'; skuPartNumber='STANDARDWOFFPACK_IW_STUDENT'; consumedUnits=340; prepaidUnits=@{enabled=500} }
        [PSCustomObject]@{ skuId='s2'; skuPartNumber='STANDARDWOFFPACK_FACULTY';    consumedUnits=45;  prepaidUnits=@{enabled=50} }
        [PSCustomObject]@{ skuId='s3'; skuPartNumber='INTUNE_A';                    consumedUnits=50;  prepaidUnits=@{enabled=50} }
    )
}

function Start-LaLicLoadDemo {
    # Fake: first user has A1 Students assigned, others available
    $assigned = @([PSCustomObject]@{ skuId='s1'; skuPartNumber='STANDARDWOFFPACK_IW_STUDENT' })
    $assignedMap = @{ 's1' = $true }
    $Script:LA_UI.AssignedList.Items.Clear()
    foreach ($l in $assigned) {
        $lbi = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Content = Get-LaName $l.skuPartNumber
        $lbi.ToolTip = $l.skuPartNumber
        $lbi.Tag     = $l.skuId
        [void]$Script:LA_UI.AssignedList.Items.Add($lbi)
    }
    $Script:LA_UI.AssignedHeader.Text = "Assigned ($($assigned.Count))"
    $Script:LA_UI.AvailableList.Items.Clear()
    $dangerBrush = New-SolidBrush 'Danger'
    $dimBrush    = New-SolidBrush 'TextDim'
    foreach ($sku in $Script:LA_AllSkus) {
        if ($assignedMap[$sku.skuId]) { continue }
        $seats = $sku.prepaidUnits.enabled - $sku.consumedUnits
        $lbi   = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Content = "$(Get-LaName $sku.skuPartNumber)   ($seats seats)"
        $lbi.ToolTip = $sku.skuPartNumber
        $lbi.Tag     = @{ SkuId = $sku.skuId; Seats = $seats }
        $lbi.Foreground = if ($seats -le 0) { $dangerBrush } else { $dimBrush }
        [void]$Script:LA_UI.AvailableList.Items.Add($lbi)
    }
    $Script:LA_UI.AvailableHeader.Text = "Available (2)"
    Update-LaButtons
}

# ── XAML ───────────────────────────────────────────────────────────────────────
$Script:LaXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
      Background="#12121C">
  <Grid.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground"      Value="White"/>
      <Setter Property="FontWeight"      Value="SemiBold"/>
      <Setter Property="FontSize"        Value="12"/>
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
            <Border Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                            Background="{TemplateBinding Background}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ListBox">
      <Setter Property="Background"      Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Foreground" Value="#E2E2F0"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding"    Value="12,7"/>
      <Setter Property="Cursor"     Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    Padding="{TemplateBinding Padding}">
              <TextBlock Text="{TemplateBinding Content}"
                         Foreground="{TemplateBinding Foreground}"
                         TextTrimming="CharacterEllipsis"/>
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
  </Grid.Resources>

  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="260" MinWidth="180"/>
    <ColumnDefinition Width="5"/>
    <ColumnDefinition Width="*"/>
  </Grid.ColumnDefinitions>

  <GridSplitter Grid.Column="1" Width="5" HorizontalAlignment="Stretch"
                Background="#3C3C5A" Cursor="SizeWE" ResizeBehavior="PreviousAndNext"/>

  <!-- Left: user picker -->
  <Border Grid.Column="0" Background="#1C1C2A">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <Border Grid.Row="0" Padding="12,10" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
        <StackPanel>
          <TextBlock Text="USERS" Foreground="#50507A" FontSize="10" FontWeight="Bold" Margin="0,0,0,8"/>
          <TextBox x:Name="LaUserSearch" IsEnabled="False" Height="34"/>
        </StackPanel>
      </Border>
      <ListBox x:Name="LaUserList" Grid.Row="1" IsEnabled="False"
               ScrollViewer.HorizontalScrollBarVisibility="Disabled"
               VirtualizingPanel.IsVirtualizing="True"
               VirtualizingPanel.VirtualizationMode="Recycling"/>
    </Grid>
  </Border>

  <!-- Right: assigned + available -->
  <Grid Grid.Column="2">
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="5"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <GridSplitter Grid.Row="1" Height="5" HorizontalAlignment="Stretch"
                  Background="#3C3C5A" Cursor="SizeNS" ResizeBehavior="PreviousAndNext"/>

    <!-- Assigned -->
    <Grid Grid.Row="0">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <Border Grid.Row="0" Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1" Padding="16,10">
        <TextBlock x:Name="LaAssignedHeader" Text="Assigned" Foreground="#7878A0" FontSize="11" FontWeight="SemiBold"/>
      </Border>
      <ListBox x:Name="LaAssignedList" Grid.Row="1"
               ScrollViewer.HorizontalScrollBarVisibility="Disabled"
               VirtualizingPanel.IsVirtualizing="True"
               VirtualizingPanel.VirtualizationMode="Recycling"/>
      <Border Grid.Row="2" Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="0,1,0,0" Padding="14,10">
        <Button x:Name="LaBtnRemove" Content="Remove Selected Licence"
                Style="{StaticResource Btn}" Background="#EF4444"
                Padding="14,8" IsEnabled="False" HorizontalAlignment="Left"/>
      </Border>
    </Grid>

    <!-- Available -->
    <Grid Grid.Row="2">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <Border Grid.Row="0" Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1" Padding="16,10">
        <TextBlock x:Name="LaAvailableHeader" Text="Available" Foreground="#7878A0" FontSize="11" FontWeight="SemiBold"/>
      </Border>
      <ListBox x:Name="LaAvailableList" Grid.Row="1"
               ScrollViewer.HorizontalScrollBarVisibility="Disabled"
               VirtualizingPanel.IsVirtualizing="True"
               VirtualizingPanel.VirtualizationMode="Recycling"/>
      <Border Grid.Row="2" Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="0,1,0,0" Padding="14,10">
        <Button x:Name="LaBtnAssign" Content="Assign Selected Licence"
                Style="{StaticResource Btn}" Background="#6366F1"
                Padding="14,8" IsEnabled="False" HorizontalAlignment="Left"/>
      </Border>
    </Grid>
  </Grid>
</Grid>
'@

# ── Initialize ─────────────────────────────────────────────────────────────────
function Initialize-LicenceAssignmentTool {
    $reader  = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new((Invoke-ThemeXaml $Script:LaXaml)))
    $content = [System.Windows.Markup.XamlReader]::Load($reader)

    $Script:LA_UI = @{
        UserSearch      = $content.FindName('LaUserSearch')
        UserList        = $content.FindName('LaUserList')
        AssignedList    = $content.FindName('LaAssignedList')
        AvailableList   = $content.FindName('LaAvailableList')
        AssignedHeader  = $content.FindName('LaAssignedHeader')
        AvailableHeader = $content.FindName('LaAvailableHeader')
        BtnRemove       = $content.FindName('LaBtnRemove')
        BtnAssign       = $content.FindName('LaBtnAssign')
    }

    $Script:LA_UI.UserSearch.Add_TextChanged({
        try { Update-LaFilter } catch { Write-Log "LA search: $_" 'ERROR' }
    })

    $Script:LA_UI.UserList.Add_SelectionChanged({
        try {
            $sel = $Script:LA_UI.UserList.SelectedItem
            if (-not $sel) { return }
            $Script:LA_User = $sel.Tag
            Write-Log "LA: selected $($Script:LA_User.displayName)" 'DEBUG'
            Start-LaLicLoad -UserId $Script:LA_User.id
        } catch { Write-Log "LA user select: $_" 'ERROR' }
    })

    $Script:LA_UI.AssignedList.Add_SelectionChanged({
        try { Update-LaButtons } catch {}
    })

    $Script:LA_UI.AvailableList.Add_SelectionChanged({
        try { Update-LaButtons } catch {}
    })

    $Script:LA_UI.BtnRemove.Add_Click({
        try { Start-LaRemove } catch { Write-Log "LA remove: $_" 'ERROR' }
    })

    $Script:LA_UI.BtnAssign.Add_Click({
        try { Start-LaAssign } catch { Write-Log "LA assign: $_" 'ERROR' }
    })

    Register-ConnectCallback 'Start-LaUserLoad'
    Register-ConnectCallback 'Start-LaSkuLoad'

    $Script:ResetCallbacks.Add({
        $Script:LA_AllUsers = @()
        $Script:LA_AllSkus  = @()
        $Script:LA_User     = $null
        $Script:LA_UI.UserSearch.Text      = ''
        $Script:LA_UI.UserSearch.IsEnabled = $false
        $Script:LA_UI.UserList.Items.Clear()
        $Script:LA_UI.UserList.IsEnabled   = $false
        Clear-LaLists
    })

    Write-LaLog 'Licence Assignment ready. Connect a tenant to begin.' 'Muted'
    return $content
}
