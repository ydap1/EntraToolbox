<#
    Licence Assignment tab for Art's Entra Toolbox.
    Dot-sourced by Start.ps1.
    Exposes Initialize-LicenceAssignmentTool.

    View, assign, and remove M365 licences for any user.
    Uses /subscribedSkus for tenant pool, /users/{id}/licenseDetails for per-user view,
    and /users/{id}/assignLicense for both assign and remove.
#>

$Script:LA_UI          = $null
$Script:LA_AllUsers    = @()
$Script:LA_AllSkus     = @()
$Script:LA_SelectedUser= $null

$Script:LA_UserTimer   = $null
$Script:LA_SkuTimer    = $null
$Script:LA_LicTimer    = $null
$Script:LA_ActionTimer = $null

# ── Friendly SKU name map ──────────────────────────────────────────────────────
$Script:LA_SkuNames = @{
    'STANDARDWOFFPACK_IW_STUDENT' = 'Microsoft 365 A1 for Students'
    'STANDARDWOFFPACK_FACULTY'    = 'Microsoft 365 A1 for Faculty'
    'M365EDU_A3_STUUSEBNFT'       = 'Microsoft 365 A3 for Students'
    'M365EDU_A3_FACULTY'          = 'Microsoft 365 A3 for Faculty'
    'M365EDU_A5_STUUSEBNFT'       = 'Microsoft 365 A5 for Students'
    'M365EDU_A5_FACULTY'          = 'Microsoft 365 A5 for Faculty'
    'ENTERPRISEPACK'              = 'Office 365 E3'
    'ENTERPRISEPREMIUM'           = 'Office 365 E5'
    'SPE_E3'                      = 'Microsoft 365 E3'
    'SPE_E5'                      = 'Microsoft 365 E5'
    'INTUNE_A'                    = 'Microsoft Intune'
}

function Get-LaFriendlyName {
    param([string]$SkuPartNumber)
    if ($Script:LA_SkuNames.ContainsKey($SkuPartNumber)) { return $Script:LA_SkuNames[$SkuPartNumber] }
    return $SkuPartNumber
}

# ── Log helper ─────────────────────────────────────────────────────────────────
function Write-LaLog {
    param([string]$Msg, [string]$Color = 'TextDim')
    Write-AppLog $Msg $Color
}

# ── Async user load ────────────────────────────────────────────────────────────
function Start-LaUserLoad {
    if ($Script:DemoMode) { Start-LaUserLoadDemo; return }
    if (-not $Script:LA_UI) { return }

    $Script:LA_UI.UserSearch.IsEnabled = $false
    $Script:LA_UI.UserList.IsEnabled   = $false
    Write-LaLog 'Loading users...' 'TextDim'

    if ($Script:LA_UserTimer) { $Script:LA_UserTimer.Stop() }
    $Script:LA_UserTimer = Start-AsyncWork -RefSeed @{ Users = $null } -Script {
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
            if ($ref['Error'] -eq '401') { Write-LaLog 'Session expired — reconnect.' 'Danger'; return }
            if ($ref['Error']) { Write-LaLog "Error loading users: $($ref['Error'])" 'Danger'; return }
            $Script:LA_AllUsers = @($ref['Users'] | Sort-Object { $_.displayName })
            Update-LaUserFilter
            $Script:LA_UI.UserSearch.IsEnabled = $true
            $Script:LA_UI.UserList.IsEnabled   = $true
            Write-LaLog "Loaded $($Script:LA_AllUsers.Count) users." 'Success'
        } catch { Write-Log "LA user-load error: $_" 'ERROR' }
    }
}

# ── Async SKU load ─────────────────────────────────────────────────────────────
function Start-LaSkuLoad {
    if ($Script:DemoMode) { Start-LaSkuLoadDemo; return }
    if (-not $Script:LA_UI) { return }

    if ($Script:LA_SkuTimer) { $Script:LA_SkuTimer.Stop() }
    $Script:LA_SkuTimer = Start-AsyncWork -RefSeed @{ Skus = $null } -Script {
        $resp = Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus' `
            -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
        $Ref['Skus'] = $resp.value
    } -OnComplete {
        param($ref)
        try {
            if ($ref['Error']) { Write-LaLog "Error loading SKUs: $($ref['Error'])" 'Danger'; return }
            $Script:LA_AllSkus = @($ref['Skus'])
            Write-Log "LA: loaded $($Script:LA_AllSkus.Count) tenant SKUs" 'DEBUG'
        } catch { Write-Log "LA sku-load error: $_" 'ERROR' }
    }
}

function Update-LaUserFilter {
    $filter = $Script:LA_UI.UserSearch.Text.Trim()
    $Script:LA_UI.UserList.Items.Clear()
    $list = if ([string]::IsNullOrWhiteSpace($filter)) { $Script:LA_AllUsers } else {
        $Script:LA_AllUsers | Where-Object {
            $_.displayName -like "*$filter*" -or $_.userPrincipalName -like "*$filter*"
        }
    }
    foreach ($u in $list) {
        $lbi         = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Content = $u.displayName
        $lbi.Tag     = $u
        $lbi.ToolTip = $u.userPrincipalName
        [void]$Script:LA_UI.UserList.Items.Add($lbi)
    }
}

# ── Load licences for selected user ───────────────────────────────────────────
function Start-LaLicenceLoad {
    param([string]$UserId)
    if ($Script:DemoMode) { Start-LaLicenceLoadDemo -UserId $UserId; return }

    $Script:LA_UI.AssignedGrid.ItemsSource   = $null
    $Script:LA_UI.AvailableGrid.ItemsSource  = $null
    $Script:LA_UI.AssignedHeader.Text        = 'Loading...'
    $Script:LA_UI.AvailableHeader.Text       = 'Available Licences'

    if ($Script:LA_LicTimer) { $Script:LA_LicTimer.Stop() }
    $Script:LA_LicTimer = Start-AsyncWork `
        -Vars    @{ UserId = $UserId } `
        -RefSeed @{ Assigned = $null } `
        -Script {
            $resp = Invoke-RestMethod `
                -Uri "https://graph.microsoft.com/v1.0/users/$UserId/licenseDetails" `
                -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
            $Ref['Assigned'] = $resp.value
        } -OnComplete {
            param($ref)
            try {
                if ($ref['Error']) { Write-LaLog "Error loading licences: $($ref['Error'])" 'Danger'; return }

                $assigned = @($ref['Assigned'])
                $assignedIds = [System.Collections.Generic.HashSet[string]]::new(
                    ($assigned | ForEach-Object { $_.skuId }))

                # Build assigned rows
                $assignedItems = [System.Collections.Generic.List[PSCustomObject]]::new()
                foreach ($lic in $assigned | Sort-Object { $_.skuPartNumber }) {
                    $assignedItems.Add([PSCustomObject]@{
                        FriendlyName   = Get-LaFriendlyName $lic.skuPartNumber
                        SkuPartNumber  = $lic.skuPartNumber
                        SkuId          = $lic.skuId
                    })
                }

                # Build available rows (tenant SKUs not already assigned)
                $availItems = [System.Collections.Generic.List[PSCustomObject]]::new()
                foreach ($sku in $Script:LA_AllSkus | Sort-Object { $_.skuPartNumber }) {
                    if ($assignedIds.Contains($sku.skuId)) { continue }
                    $avail = $sku.prepaidUnits.enabled - $sku.consumedUnits
                    $availItems.Add([PSCustomObject]@{
                        FriendlyName      = Get-LaFriendlyName $sku.skuPartNumber
                        SkuPartNumber     = $sku.skuPartNumber
                        SkuId             = $sku.skuId
                        AvailableSeats    = $avail
                        HasAvailableSeats = ($avail -gt 0)
                    })
                }

                $Script:LA_UI.AssignedGrid.ItemsSource  = $assignedItems
                $Script:LA_UI.AvailableGrid.ItemsSource = $availItems
                $Script:LA_UI.AssignedHeader.Text       = "Assigned ($($assignedItems.Count))"
                $Script:LA_UI.AvailableHeader.Text      = "Available from tenant pool ($($availItems.Count))"
            } catch { Write-Log "LA licence-load error: $_" 'ERROR' }
        }
}

# ── Assign / Remove ────────────────────────────────────────────────────────────
function Start-LaAssign {
    param([string]$SkuId)
    if (-not $Script:LA_SelectedUser) { return }
    $user = $Script:LA_SelectedUser
    if ($Script:DryMode) {
        Write-LaLog "[DRY] Would assign SKU $SkuId to $($user.displayName)" 'Warning'
        return
    }
    Write-LaLog "Assigning licence to $($user.displayName)..." 'TextDim'
    if ($Script:LA_ActionTimer) { $Script:LA_ActionTimer.Stop() }
    $Script:LA_ActionTimer = Start-AsyncWork `
        -Vars    @{ UserId = $user.id; SkuId = $SkuId } `
        -RefSeed @{ Ok = $false } `
        -Script {
            $body = '{"addLicenses":[{"skuId":"' + $SkuId + '"}],"removeLicenses":[]}'
            Invoke-RestMethod `
                -Uri "https://graph.microsoft.com/v1.0/users/$UserId/assignLicense" `
                -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } `
                -Method POST -Body $body -ErrorAction Stop
            $Ref['Ok'] = $true
        } -OnComplete {
            param($ref)
            try {
                if ($ref['Error']) { Write-LaLog "Assign failed: $($ref['Error'])" 'Danger'; return }
                Write-LaLog "Licence assigned successfully." 'Success'
                Start-LaLicenceLoad -UserId $Script:LA_SelectedUser.id
            } catch { Write-Log "LA assign error: $_" 'ERROR' }
        }
}

function Start-LaRemove {
    param([string]$SkuId)
    if (-not $Script:LA_SelectedUser) { return }
    $user = $Script:LA_SelectedUser
    if ($Script:DryMode) {
        Write-LaLog "[DRY] Would remove SKU $SkuId from $($user.displayName)" 'Warning'
        return
    }
    Write-LaLog "Removing licence from $($user.displayName)..." 'TextDim'
    if ($Script:LA_ActionTimer) { $Script:LA_ActionTimer.Stop() }
    $Script:LA_ActionTimer = Start-AsyncWork `
        -Vars    @{ UserId = $user.id; SkuId = $SkuId } `
        -RefSeed @{ Ok = $false } `
        -Script {
            $body = '{"addLicenses":[],"removeLicenses":["' + $SkuId + '"]}'
            Invoke-RestMethod `
                -Uri "https://graph.microsoft.com/v1.0/users/$UserId/assignLicense" `
                -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } `
                -Method POST -Body $body -ErrorAction Stop
            $Ref['Ok'] = $true
        } -OnComplete {
            param($ref)
            try {
                if ($ref['Error']) { Write-LaLog "Remove failed: $($ref['Error'])" 'Danger'; return }
                Write-LaLog "Licence removed successfully." 'Success'
                Start-LaLicenceLoad -UserId $Script:LA_SelectedUser.id
            } catch { Write-Log "LA remove error: $_" 'ERROR' }
        }
}

# ── Demo stubs ────────────────────────────────────────────────────────────────
function Start-LaUserLoadDemo {
    $Script:LA_AllUsers = @(
        $Script:Demo_Users | Select-Object -First 15
    )
    Update-LaUserFilter
    $Script:LA_UI.UserSearch.IsEnabled = $true
    $Script:LA_UI.UserList.IsEnabled   = $true
    Write-LaLog 'Demo: loaded users.' 'Muted'
}

function Start-LaSkuLoadDemo {
    $Script:LA_AllSkus = @(
        [PSCustomObject]@{ skuId = 'sku-a1s'; skuPartNumber = 'STANDARDWOFFPACK_IW_STUDENT'; consumedUnits = 340; prepaidUnits = @{ enabled = 500 } }
        [PSCustomObject]@{ skuId = 'sku-a1f'; skuPartNumber = 'STANDARDWOFFPACK_FACULTY';    consumedUnits = 45;  prepaidUnits = @{ enabled = 50 } }
        [PSCustomObject]@{ skuId = 'sku-int'; skuPartNumber = 'INTUNE_A';                    consumedUnits = 50;  prepaidUnits = @{ enabled = 50 } }
    )
}

function Start-LaLicenceLoadDemo {
    param([string]$UserId)
    $assignedItems = @(
        [PSCustomObject]@{ FriendlyName = 'Microsoft 365 A1 for Students'; SkuPartNumber = 'STANDARDWOFFPACK_IW_STUDENT'; SkuId = 'sku-a1s' }
    )
    $availItems = @(
        [PSCustomObject]@{ FriendlyName = 'Microsoft 365 A1 for Faculty'; SkuPartNumber = 'STANDARDWOFFPACK_FACULTY'; SkuId = 'sku-a1f'; AvailableSeats = 5;  HasAvailableSeats = $true }
        [PSCustomObject]@{ FriendlyName = 'Microsoft Intune';             SkuPartNumber = 'INTUNE_A';                 SkuId = 'sku-int'; AvailableSeats = 0;  HasAvailableSeats = $false }
    )
    $Script:LA_UI.AssignedGrid.ItemsSource  = $assignedItems
    $Script:LA_UI.AvailableGrid.ItemsSource = $availItems
    $Script:LA_UI.AssignedHeader.Text       = "Assigned ($($assignedItems.Count))"
    $Script:LA_UI.AvailableHeader.Text      = "Available from tenant pool ($($availItems.Count))"
}

# ── XAML ───────────────────────────────────────────────────────────────────────
$Script:LaXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
      Background="#12121C">
  <Grid.Resources>

    <Style x:Key="PrimaryBtn" TargetType="Button">
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

    <Style x:Key="DgHdr" TargetType="DataGridColumnHeader">
      <Setter Property="Background"     Value="#1C1C2A"/>
      <Setter Property="Foreground"     Value="#7878A0"/>
      <Setter Property="BorderBrush"    Value="#3C3C5A"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="Padding"        Value="10,0"/>
      <Setter Property="Height"         Value="32"/>
      <Setter Property="FontSize"       Value="11"/>
      <Setter Property="FontWeight"     Value="SemiBold"/>
    </Style>

    <Style x:Key="DgCell" TargetType="DataGridCell">
      <Setter Property="Foreground"       Value="#E2E2F0"/>
      <Setter Property="Background"       Value="Transparent"/>
      <Setter Property="BorderThickness"  Value="0"/>
      <Setter Property="Padding"          Value="10,0"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="Transparent"/>
          <Setter Property="Foreground" Value="#E2E2F0"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="DgRow" TargetType="DataGridRow">
      <Setter Property="Background" Value="Transparent"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#1E1E38"/>
        </Trigger>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#2A2A50"/>
        </Trigger>
      </Style.Triggers>
    </Style>

  </Grid.Resources>

  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="260" MinWidth="200"/>
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
               VirtualizingPanel.VirtualizationMode="Recycling"
               Margin="0,2,0,2"/>
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

    <!-- Assigned licences -->
    <Grid Grid.Row="0">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <Border Grid.Row="0" Background="#1C1C2A" BorderBrush="#3C3C5A"
              BorderThickness="0,0,0,1" Padding="16,10">
        <TextBlock x:Name="LaAssignedHeader" Text="Assigned Licences"
                   Foreground="#7878A0" FontSize="11" FontWeight="SemiBold"/>
      </Border>
      <DataGrid x:Name="LaAssignedGrid" Grid.Row="1"
                AutoGenerateColumns="False" IsReadOnly="False"
                CanUserAddRows="False" CanUserDeleteRows="False"
                CanUserReorderColumns="False" CanUserResizeRows="False"
                SelectionMode="Single" HeadersVisibility="Column"
                RowBackground="#12121C" AlternatingRowBackground="#14171C"
                GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#1E1E32"
                Background="#12121C" BorderThickness="0" Foreground="#E2E2F0"
                ColumnHeaderStyle="{StaticResource DgHdr}"
                CellStyle="{StaticResource DgCell}"
                RowStyle="{StaticResource DgRow}"
                RowHeight="34">
        <DataGrid.Columns>
          <DataGridTextColumn Header="Licence Name" Binding="{Binding FriendlyName}"
                              Width="*" IsReadOnly="True"/>
          <DataGridTextColumn Header="SKU Part Number" Binding="{Binding SkuPartNumber}"
                              Width="200" IsReadOnly="True"/>
          <DataGridTemplateColumn Header="" Width="90" IsReadOnly="True">
            <DataGridTemplateColumn.CellTemplate>
              <DataTemplate>
                <Button Content="Remove" Tag="{Binding SkuId}"
                        Background="#EF4444" Foreground="White"
                        FontSize="11" FontWeight="SemiBold" Padding="8,4"
                        BorderThickness="0" Cursor="Hand" Margin="4,4"/>
              </DataTemplate>
            </DataGridTemplateColumn.CellTemplate>
          </DataGridTemplateColumn>
        </DataGrid.Columns>
      </DataGrid>
    </Grid>

    <!-- Available licences -->
    <Grid Grid.Row="2">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <Border Grid.Row="0" Background="#1C1C2A" BorderBrush="#3C3C5A"
              BorderThickness="0,0,0,1" Padding="16,10">
        <TextBlock x:Name="LaAvailableHeader" Text="Available Licences"
                   Foreground="#7878A0" FontSize="11" FontWeight="SemiBold"/>
      </Border>
      <DataGrid x:Name="LaAvailableGrid" Grid.Row="1"
                AutoGenerateColumns="False" IsReadOnly="False"
                CanUserAddRows="False" CanUserDeleteRows="False"
                CanUserReorderColumns="False" CanUserResizeRows="False"
                SelectionMode="Single" HeadersVisibility="Column"
                RowBackground="#12121C" AlternatingRowBackground="#14171C"
                GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#1E1E32"
                Background="#12121C" BorderThickness="0" Foreground="#E2E2F0"
                ColumnHeaderStyle="{StaticResource DgHdr}"
                CellStyle="{StaticResource DgCell}"
                RowStyle="{StaticResource DgRow}"
                RowHeight="34">
        <DataGrid.Columns>
          <DataGridTextColumn Header="Licence Name" Binding="{Binding FriendlyName}"
                              Width="*" IsReadOnly="True"/>
          <DataGridTemplateColumn Header="Available Seats" Width="130" IsReadOnly="True">
            <DataGridTemplateColumn.CellTemplate>
              <DataTemplate>
                <TextBlock x:Name="tbSeats" Text="{Binding AvailableSeats}"
                           VerticalAlignment="Center" Padding="10,0" Foreground="#E2E2F0"/>
                <DataTemplate.Triggers>
                  <DataTrigger Binding="{Binding HasAvailableSeats}" Value="False">
                    <Setter TargetName="tbSeats" Property="Foreground" Value="#EF4444"/>
                  </DataTrigger>
                </DataTemplate.Triggers>
              </DataTemplate>
            </DataGridTemplateColumn.CellTemplate>
          </DataGridTemplateColumn>
          <DataGridTemplateColumn Header="" Width="90" IsReadOnly="True">
            <DataGridTemplateColumn.CellTemplate>
              <DataTemplate>
                <Button Content="Assign" Tag="{Binding SkuId}"
                        IsEnabled="{Binding HasAvailableSeats}"
                        Background="#6366F1" Foreground="White"
                        FontSize="11" FontWeight="SemiBold" Padding="8,4"
                        BorderThickness="0" Cursor="Hand" Margin="4,4"/>
              </DataTemplate>
            </DataGridTemplateColumn.CellTemplate>
          </DataGridTemplateColumn>
        </DataGrid.Columns>
      </DataGrid>
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
        AssignedGrid    = $content.FindName('LaAssignedGrid')
        AvailableGrid   = $content.FindName('LaAvailableGrid')
        AssignedHeader  = $content.FindName('LaAssignedHeader')
        AvailableHeader = $content.FindName('LaAvailableHeader')
    }

    $Script:LA_UI.UserSearch.Add_TextChanged({
        try { Update-LaUserFilter }
        catch { Write-Log "LA UserSearch error: $_" 'ERROR' }
    })

    $Script:LA_UI.UserList.Add_SelectionChanged({
        try {
            $sel = $Script:LA_UI.UserList.SelectedItem
            if (-not $sel) { return }
            $Script:LA_SelectedUser = $sel.Tag
            Write-Log "LA: selected user $($Script:LA_SelectedUser.displayName)" 'DEBUG'
            Start-LaLicenceLoad -UserId $Script:LA_SelectedUser.id
        } catch { Write-Log "LA UserList SelectionChanged error: $_" 'ERROR' }
    })

    # Routed button click for Assigned grid (Remove)
    $Script:LA_UI.AssignedGrid.AddHandler(
        [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
        [System.Windows.RoutedEventHandler]{
            param($s, $e)
            if ($e.OriginalSource -is [System.Windows.Controls.Button]) {
                $skuId = $e.OriginalSource.Tag
                if ($skuId) { Start-LaRemove -SkuId $skuId }
            }
        }
    )

    # Routed button click for Available grid (Assign)
    $Script:LA_UI.AvailableGrid.AddHandler(
        [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
        [System.Windows.RoutedEventHandler]{
            param($s, $e)
            if ($e.OriginalSource -is [System.Windows.Controls.Button]) {
                $skuId = $e.OriginalSource.Tag
                if ($skuId) { Start-LaAssign -SkuId $skuId }
            }
        }
    )

    Register-ConnectCallback 'Start-LaUserLoad'
    Register-ConnectCallback 'Start-LaSkuLoad'
    $Script:ResetCallbacks.Add({
        $Script:LA_AllUsers     = @()
        $Script:LA_AllSkus      = @()
        $Script:LA_SelectedUser = $null
        $Script:LA_UI.UserSearch.Text      = ''
        $Script:LA_UI.UserSearch.IsEnabled = $false
        $Script:LA_UI.UserList.Items.Clear()
        $Script:LA_UI.UserList.IsEnabled   = $false
        $Script:LA_UI.AssignedGrid.ItemsSource  = $null
        $Script:LA_UI.AvailableGrid.ItemsSource = $null
        $Script:LA_UI.AssignedHeader.Text       = 'Assigned Licences'
        $Script:LA_UI.AvailableHeader.Text      = 'Available Licences'
    })

    Write-LaLog 'Licence Assignment ready. Select a tenant to begin.' 'Muted'
    return $content
}
