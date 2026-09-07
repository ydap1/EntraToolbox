<#
    Licence Assignment tool for Art's Entra Toolbox.
    Dot-sourced by Start.ps1.
    Exposes Initialize-LicenceAssignmentTool.

    Shows a user's assigned Microsoft 365 licences and the tenant's available SKUs.
    Allows assigning or removing licences one at a time.
#>

$Script:LA_UI           = $null
$Script:LA_AllUsers     = @()
$Script:LA_AllSkus      = @()
$Script:LA_SelectedUser = $null
$Script:LA_SkuTimer     = $null
$Script:LA_LicTimer     = $null
$Script:LA_ActionTimer  = $null

# Common Microsoft 365 education SKU friendly names
$Script:LA_SkuNames = @{
    'STANDARDWOFFPACK_IW_STUDENT'  = 'Microsoft 365 A1 for Students'
    'STANDARDWOFFPACK_IW_FACULTY'  = 'Microsoft 365 A1 for Faculty'
    'STANDARDWOFFPACK_STUDENT'     = 'Microsoft 365 A1 for Students'
    'STANDARDWOFFPACK_FACULTY'     = 'Microsoft 365 A1 for Faculty'
    'M365EDU_A3_STUDENT'           = 'Microsoft 365 A3 for Students'
    'M365EDU_A3_FACULTY'           = 'Microsoft 365 A3 for Faculty'
    'M365EDU_A5_STUDENT'           = 'Microsoft 365 A5 for Students'
    'M365EDU_A5_FACULTY'           = 'Microsoft 365 A5 for Faculty'
    'INTUNE_A_VL'                  = 'Intune for Education'
    'EMS_EDU_FACULTY'              = 'EMS A3 for Faculty'
    'EMS_EDU_STUDENT'              = 'EMS A3 for Students'
    'EXCHANGESTANDARD'             = 'Exchange Online (Plan 1)'
    'EXCHANGEENTERPRISE'           = 'Exchange Online (Plan 2)'
    'SPB'                          = 'Microsoft 365 Business Premium'
    'O365_BUSINESS_ESSENTIALS'     = 'Microsoft 365 Business Basic'
    'O365_BUSINESS_PREMIUM'        = 'Microsoft 365 Business Standard'
    'ENTERPRISEPACK'               = 'Microsoft 365 E3'
    'ENTERPRISEPREMIUM'            = 'Microsoft 365 E5'
    'POWER_BI_STANDARD'            = 'Power BI (Free)'
    'POWER_BI_PRO'                 = 'Power BI Pro'
    'TEAMS_EXPLORATORY'            = 'Microsoft Teams Exploratory'
    'FLOW_FREE'                    = 'Power Automate Free'
    'VISIOCLIENT'                  = 'Visio Plan 2'
    'PROJECTPREMIUM'               = 'Project Plan 5'
    'AAD_PREMIUM'                  = 'Microsoft Entra ID P1'
    'AAD_PREMIUM_P2'               = 'Microsoft Entra ID P2'
}

function Write-LaLog {
    param([string]$Msg, [string]$Color = 'TextDim')
    Write-AppLog $Msg $Color
}

function Get-LaSkuLabel {
    param([string]$PartNumber, [int]$Available = -1)
    $name = if ($Script:LA_SkuNames.ContainsKey($PartNumber)) {
        $Script:LA_SkuNames[$PartNumber]
    } else {
        $PartNumber -replace '_', ' '
    }
    if ($Available -ge 0) {
        $avText = if ($Available -eq 0) { ' (0 available)' } else { " ($Available available)" }
        return "$name$avText"
    }
    return $name
}

function Start-LaUserLoad {
    if ($Script:DemoMode) { Start-LaUserLoadDemo; return }

    $Script:LA_UI.UserSearch.IsEnabled = $false
    $Script:LA_UI.UserList.IsEnabled   = $false
    Write-LaLog 'Loading users...' 'TextDim'

    Request-EtbUsers -OnReady 'Complete-LaUserLoad'
}

function Complete-LaUserLoad {
    try {
        if ($Script:UserCache.Error -eq '401') {
            Write-LaLog 'Session expired — reconnect.' 'Danger'
            return
        }
        if ($Script:UserCache.Error) {
            Write-LaLog "Error loading users: $($Script:UserCache.Error)" 'Danger'
            return
        }
        $Script:LA_AllUsers = @($Script:UserCache.Users | Sort-Object { $_.displayName })
        Update-LaUserFilter
        $Script:LA_UI.UserSearch.IsEnabled = $true
        $Script:LA_UI.UserList.IsEnabled   = $true
        Write-LaLog "Loaded $($Script:LA_AllUsers.Count) users." 'Success'
        Set-MainStatus "Loaded $($Script:LA_AllUsers.Count) users." 'Success'
    } catch {
        Write-Log "LA user-load error: $_" 'ERROR'
    }
}

function Start-LaSkuLoad {
    if ($Script:DemoMode) { return } # Start-LaUserLoadDemo supplies the demo SKUs.

    if ($Script:LA_SkuTimer) { $Script:LA_SkuTimer.Stop() }
    $Script:LA_SkuTimer = Start-AsyncWork -RefSeed @{ Skus = $null } -Script {
        $Ref['Skus'] = @(Get-EtbGraphCollection `
            -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus?$select=skuId,skuPartNumber,consumedUnits,prepaidUnits,capabilityStatus' `
            -Headers @{ Authorization = "Bearer $Token" })
    } -OnComplete {
        param($ref)
        try {
            if ($ref['Error']) {
                Write-LaLog "Could not load tenant licences: $($ref['Error'])" 'Warning'
                return
            }
            $Script:LA_AllSkus = @($ref['Skus'] | Where-Object { $_.capabilityStatus -eq 'Enabled' })
            Write-LaLog "Loaded $($Script:LA_AllSkus.Count) tenant licence SKUs." 'TextDim'
        } catch {
            Write-Log "LA sku-load timer error: $_" 'ERROR'
        }
    }
}

function Update-LaUserFilter {
    $filter = $Script:LA_UI.UserSearch.Text.Trim()
    Clear-EtbList $Script:LA_UI.UserList
    $list = if ([string]::IsNullOrWhiteSpace($filter)) { $Script:LA_AllUsers } else {
        $Script:LA_AllUsers | Where-Object {
            $_.displayName -like "*$filter*" -or $_.userPrincipalName -like "*$filter*"
        }
    }
    Set-EtbListItems -List $Script:LA_UI.UserList -Items @(foreach ($u in $list) {
        [pscustomobject]@{ Content = $u.displayName; Tag = $u; ToolTip = $u.userPrincipalName }
    })
}

function Set-LaUserSelected {
    param($User)
    $Script:LA_SelectedUser = $User

    $Script:LA_UI.AssignedList.Items.Clear()
    $Script:LA_UI.AvailableList.Items.Clear()
    $Script:LA_UI.BtnRemove.IsEnabled = $false
    $Script:LA_UI.BtnAssign.IsEnabled = $false

    if (-not $User) {
        $Script:LA_UI.SelName.Text          = 'No user selected'
        $Script:LA_UI.SelUpn.Text           = ''
        $Script:LA_UI.AssignedHeader.Text   = 'ASSIGNED LICENCES'
        $Script:LA_UI.AvailableHeader.Text  = 'AVAILABLE TO ASSIGN'
        $Script:LA_UI.AssignedPlaceholder.Visibility  = 'Visible'
        $Script:LA_UI.AvailablePlaceholder.Visibility = 'Visible'
        return
    }

    $Script:LA_UI.SelName.Text  = $User.displayName
    $Script:LA_UI.SelUpn.Text   = $User.userPrincipalName
    $Script:LA_UI.AssignedHeader.Text  = 'LOADING...'
    $Script:LA_UI.AvailableHeader.Text = 'AVAILABLE TO ASSIGN'
    $Script:LA_UI.AssignedPlaceholder.Text       = 'Loading...'
    $Script:LA_UI.AssignedPlaceholder.Visibility = 'Visible'
    Start-LaLicenceLoad -UserId $User.id
}

function Start-LaLicenceLoad {
    param([string]$UserId)
    if ($Script:DemoMode) { Start-LaLicenceLoadDemo -UserId $UserId; return }

    if ($Script:LA_LicTimer) { $Script:LA_LicTimer.Stop() }
    $Script:LA_LicTimer = Start-AsyncWork `
        -Vars    @{ UserId = $UserId } `
        -RefSeed @{ RequestedId = $UserId; Licences = $null } `
        -Script {
            $Ref['Licences'] = @(Get-EtbGraphCollection `
                -Uri "https://graph.microsoft.com/v1.0/users/$UserId/licenseDetails?`$select=skuId,skuPartNumber" `
                -Headers @{ Authorization = "Bearer $Token" })
        } -OnComplete {
            param($ref)
            if ($Script:LA_SelectedUser.id -ne $ref.RequestedId) { return }
            try {
                if ($ref['Error']) {
                    $Script:LA_UI.AssignedHeader.Text = 'ASSIGNED LICENCES'
                    $Script:LA_UI.AssignedPlaceholder.Text = "Error: $($ref['Error'])"
                    return
                }

                $licences = @($ref['Licences'])
                $assignedSkuIds = @($licences | ForEach-Object { $_.skuId })

                $Script:LA_UI.AssignedList.Items.Clear()
                if ($licences.Count -eq 0) {
                    $Script:LA_UI.AssignedHeader.Text = 'ASSIGNED LICENCES (0)'
                    $Script:LA_UI.AssignedPlaceholder.Text       = 'No licences assigned.'
                    $Script:LA_UI.AssignedPlaceholder.Visibility = 'Visible'
                } else {
                    $Script:LA_UI.AssignedHeader.Text = "ASSIGNED LICENCES ($($licences.Count))"
                    $Script:LA_UI.AssignedPlaceholder.Visibility = 'Collapsed'
                    foreach ($lic in $licences | Sort-Object { $_.skuPartNumber }) {
                        $lbi         = [System.Windows.Controls.ListBoxItem]::new()
                        $lbi.Content = Get-LaSkuLabel $lic.skuPartNumber
                        $lbi.Tag     = $lic
                        [void]$Script:LA_UI.AssignedList.Items.Add($lbi)
                    }
                }

                # Populate available (tenant SKUs not already assigned)
                $Script:LA_UI.AvailableList.Items.Clear()
                $available = @($Script:LA_AllSkus | Where-Object { $_.skuId -notin $assignedSkuIds })
                if ($available.Count -eq 0) {
                    $Script:LA_UI.AvailablePlaceholder.Text       = 'All available SKUs are already assigned.'
                    $Script:LA_UI.AvailablePlaceholder.Visibility = 'Visible'
                } else {
                    $Script:LA_UI.AvailablePlaceholder.Visibility = 'Collapsed'
                    foreach ($sku in $available | Sort-Object { $_.skuPartNumber }) {
                        $avail = $sku.prepaidUnits.enabled - $sku.consumedUnits
                        $lbi   = [System.Windows.Controls.ListBoxItem]::new()
                        $lbi.Content = Get-LaSkuLabel $sku.skuPartNumber $avail
                        $lbi.Tag     = $sku
                        if ($avail -le 0) { $lbi.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#7878A0') }
                        [void]$Script:LA_UI.AvailableList.Items.Add($lbi)
                    }
                }
            } catch {
                Write-Log "LA lic-load timer error: $_" 'ERROR'
            }
        }
}

function Start-LaRemove {
    $user = $Script:LA_SelectedUser
    $sel  = $Script:LA_UI.AssignedList.SelectedItem
    if (-not $user -or -not $sel) { return }
    $lic  = $sel.Tag

    if ($Script:DryMode -or $Script:DemoMode) {
        Write-LaLog "[DRY] Would remove $($sel.Content) from $($user.displayName)" 'Warning'
        return
    }

    $Script:LA_UI.BtnRemove.IsEnabled = $false
    $Script:LA_UI.BtnAssign.IsEnabled = $false
    Write-LaLog "Removing $($sel.Content) from $($user.displayName)..." 'TextDim'

    if ($Script:LA_ActionTimer) { $Script:LA_ActionTimer.Stop() }
    $Script:LA_ActionTimer = Start-AsyncWork `
        -Vars    @{ UserId = $user.id; SkuId = $lic.skuId } `
        -RefSeed @{ Name = $user.displayName; Upn = $user.userPrincipalName; Sku = [string]$sel.Content } `
        -Script {
            $body = "{`"addLicenses`":[],`"removeLicenses`":[`"$SkuId`"]}"
            Invoke-RestMethod `
                -Uri "https://graph.microsoft.com/v1.0/users/$UserId/assignLicense" `
                -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } `
                -Method POST -Body $body -ErrorAction Stop
        } -OnComplete {
            param($ref)
            try {
                if ($ref['Error']) {
                    Write-LaLog "Remove failed: $($ref['Error'])" 'Danger'
                    Set-MainStatus 'Remove licence failed.' 'Danger'
                    Write-EtbAudit -Tool 'Licence Assignment' -Action 'Remove licence' `
                                   -Target $ref.Upn -Result 'Failed' -Detail "$($ref.Sku): $($ref['Error'])"
                } else {
                    $displayName = $ref.Name
                    Write-LaLog "Licence removed from $displayName." 'Success'
                    Set-MainStatus 'Licence removed.' 'Success'
                    Write-EtbAudit -Tool 'Licence Assignment' -Action 'Remove licence' `
                                   -Target $ref.Upn -Detail $ref.Sku
                    if ($Script:LA_SelectedUser) { Start-LaLicenceLoad -UserId $Script:LA_SelectedUser.id }
                }
                $Script:LA_UI.BtnRemove.IsEnabled = $false
            } catch {
                Write-Log "LA remove timer error: $_" 'ERROR'
            }
        }
}

function Start-LaAssign {
    $user = $Script:LA_SelectedUser
    $sel  = $Script:LA_UI.AvailableList.SelectedItem
    if (-not $user -or -not $sel) { return }
    $sku  = $sel.Tag
    if ($sku.prepaidUnits.enabled - $sku.consumedUnits -le 0) {
        Write-LaLog 'No available seats remain for this licence.' 'Warning'
        return
    }

    if ($Script:DryMode -or $Script:DemoMode) {
        Write-LaLog "[DRY] Would assign $($sel.Content) to $($user.displayName)" 'Warning'
        return
    }

    $Script:LA_UI.BtnAssign.IsEnabled = $false
    $Script:LA_UI.BtnRemove.IsEnabled = $false
    Write-LaLog "Assigning $($sel.Content) to $($user.displayName)..." 'TextDim'

    if ($Script:LA_ActionTimer) { $Script:LA_ActionTimer.Stop() }
    $Script:LA_ActionTimer = Start-AsyncWork `
        -Vars    @{ UserId = $user.id; SkuId = $sku.skuId } `
        -RefSeed @{ Name = $user.displayName; Upn = $user.userPrincipalName; Sku = [string]$sel.Content } `
        -Script {
            $body = "{`"addLicenses`":[{`"skuId`":`"$SkuId`"}],`"removeLicenses`":[]}"
            Invoke-RestMethod `
                -Uri "https://graph.microsoft.com/v1.0/users/$UserId/assignLicense" `
                -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } `
                -Method POST -Body $body -ErrorAction Stop
        } -OnComplete {
            param($ref)
            try {
                if ($ref['Error']) {
                    Write-LaLog "Assign failed: $($ref['Error'])" 'Danger'
                    Set-MainStatus 'Assign licence failed.' 'Danger'
                    Write-EtbAudit -Tool 'Licence Assignment' -Action 'Assign licence' `
                                   -Target $ref.Upn -Result 'Failed' -Detail "$($ref.Sku): $($ref['Error'])"
                } else {
                    $displayName = $ref.Name
                    Write-LaLog "Licence assigned to $displayName." 'Success'
                    Set-MainStatus 'Licence assigned.' 'Success'
                    Write-EtbAudit -Tool 'Licence Assignment' -Action 'Assign licence' `
                                   -Target $ref.Upn -Detail $ref.Sku
                    if ($Script:LA_SelectedUser) { Start-LaLicenceLoad -UserId $Script:LA_SelectedUser.id }
                }
                $Script:LA_UI.BtnAssign.IsEnabled = $false
            } catch {
                Write-Log "LA assign timer error: $_" 'ERROR'
            }
        }
}

function Start-LaUserLoadDemo {
    $Script:LA_AllUsers = @($Script:Demo_Users | Select-Object -First 8)
    $Script:LA_AllSkus  = @(
        [PSCustomObject]@{ skuId='sku-a1s'; skuPartNumber='STANDARDWOFFPACK_IW_STUDENT'; consumedUnits=120; prepaidUnits=@{enabled=200}; capabilityStatus='Enabled' }
        [PSCustomObject]@{ skuId='sku-a1f'; skuPartNumber='STANDARDWOFFPACK_IW_FACULTY'; consumedUnits=25;  prepaidUnits=@{enabled=50};  capabilityStatus='Enabled' }
        [PSCustomObject]@{ skuId='sku-int'; skuPartNumber='INTUNE_A_VL';                  consumedUnits=10;  prepaidUnits=@{enabled=50};  capabilityStatus='Enabled' }
    )
    Update-LaUserFilter
    $Script:LA_UI.UserSearch.IsEnabled = $true
    $Script:LA_UI.UserList.IsEnabled   = $true
    Write-LaLog 'Demo: loaded 8 users, 3 SKUs.' 'Success'
}

function Start-LaLicenceLoadDemo {
    param([string]$UserId)
    $Script:LA_UI.AssignedList.Items.Clear()
    $Script:LA_UI.AvailableList.Items.Clear()
    $Script:LA_UI.AssignedPlaceholder.Visibility  = 'Collapsed'
    $Script:LA_UI.AvailablePlaceholder.Visibility = 'Collapsed'

    $assigned = @(
        [PSCustomObject]@{ skuId='sku-a1s'; skuPartNumber='STANDARDWOFFPACK_IW_STUDENT' }
    )
    $Script:LA_UI.AssignedHeader.Text = "ASSIGNED LICENCES ($($assigned.Count))"
    foreach ($lic in $assigned) {
        $lbi         = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Content = Get-LaSkuLabel $lic.skuPartNumber
        $lbi.Tag     = $lic
        [void]$Script:LA_UI.AssignedList.Items.Add($lbi)
    }
    $assignedIds = @($assigned | ForEach-Object { $_.skuId })
    $available   = @($Script:LA_AllSkus | Where-Object { $_.skuId -notin $assignedIds })
    foreach ($sku in $available) {
        $avail = $sku.prepaidUnits.enabled - $sku.consumedUnits
        $lbi   = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Content = Get-LaSkuLabel $sku.skuPartNumber $avail
        $lbi.Tag     = $sku
        [void]$Script:LA_UI.AvailableList.Items.Add($lbi)
    }
}

$Script:LaXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
      Background="#12121C">
  <Grid.Resources>

    <Style x:Key="ActionBtn" TargetType="Button">
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
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ListBoxItem">
      <Setter Property="Foreground"                 Value="#E2E2F0"/>
      <Setter Property="Background"                 Value="Transparent"/>
      <Setter Property="Padding"                    Value="10,7"/>
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

  </Grid.Resources>

  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="260" MinWidth="200"/>
    <ColumnDefinition Width="5"/>
    <ColumnDefinition Width="*"/>
  </Grid.ColumnDefinitions>

  <GridSplitter Grid.Column="1" Width="5" HorizontalAlignment="Stretch"
                Background="#3C3C5A" Cursor="SizeWE" ResizeBehavior="PreviousAndNext"/>

  <!-- Left: user list -->
  <Border Grid.Column="0" Background="#1C1C2A">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <Border Grid.Row="0" Padding="12,10" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
        <StackPanel>
          <TextBlock Text="SELECT USER" Foreground="#50507A" FontSize="10"
                     FontWeight="Bold" Margin="0,0,0,8"/>
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

  <!-- Right: licence panels -->
  <Grid Grid.Column="2">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- Selected user bar -->
    <Border Grid.Row="0" Background="#1C1C2A" BorderBrush="#3C3C5A"
            BorderThickness="0,0,0,1" Padding="16,12">
      <StackPanel>
        <TextBlock x:Name="LaSelName" Text="No user selected"
                   Foreground="#7878A0" FontStyle="Italic" FontSize="14" FontWeight="SemiBold"/>
        <TextBlock x:Name="LaSelUpn" Foreground="#50507A" FontSize="11" Margin="0,3,0,0"/>
      </StackPanel>
    </Border>

    <!-- Licence panels split -->
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*" MinWidth="200"/>
        <ColumnDefinition Width="5"/>
        <ColumnDefinition Width="*" MinWidth="200"/>
      </Grid.ColumnDefinitions>

      <GridSplitter Grid.Column="1" Width="5" HorizontalAlignment="Stretch"
                    Background="#3C3C5A" Cursor="SizeWE" ResizeBehavior="PreviousAndNext"/>

      <!-- Assigned licences panel -->
      <Grid Grid.Column="0">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Border Grid.Row="0" Background="#1C1C2A" Padding="12,8"
                BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
          <TextBlock x:Name="LaAssignedHeader" Text="ASSIGNED LICENCES"
                     Foreground="#50507A" FontSize="10" FontWeight="Bold"/>
        </Border>
        <Grid Grid.Row="1">
          <TextBlock x:Name="LaAssignedPlaceholder" Text="Select a user to view licences."
                     Foreground="#50507A" FontStyle="Italic" FontSize="12"
                     HorizontalAlignment="Center" VerticalAlignment="Center"
                     Visibility="Visible"/>
          <ListBox x:Name="LaAssignedList"
                   ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                   Margin="0,2,0,2"/>
        </Grid>
        <Border Grid.Row="2" Background="#1C1C2A" Padding="10,8"
                BorderBrush="#3C3C5A" BorderThickness="0,1,0,0">
          <Button x:Name="LaBtnRemove" Content="Remove Selected Licence"
                  Style="{StaticResource ActionBtn}" Background="#EF4444"
                  Padding="12,7" IsEnabled="False" HorizontalAlignment="Left"/>
        </Border>
      </Grid>

      <!-- Available licences panel -->
      <Grid Grid.Column="2">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Border Grid.Row="0" Background="#1C1C2A" Padding="12,8"
                BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
          <TextBlock x:Name="LaAvailableHeader" Text="AVAILABLE TO ASSIGN"
                     Foreground="#50507A" FontSize="10" FontWeight="Bold"/>
        </Border>
        <Grid Grid.Row="1">
          <TextBlock x:Name="LaAvailablePlaceholder" Text="Select a user to view available licences."
                     Foreground="#50507A" FontStyle="Italic" FontSize="12"
                     HorizontalAlignment="Center" VerticalAlignment="Center"
                     Visibility="Visible"/>
          <ListBox x:Name="LaAvailableList"
                   ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                   Margin="0,2,0,2"/>
        </Grid>
        <Border Grid.Row="2" Background="#1C1C2A" Padding="10,8"
                BorderBrush="#3C3C5A" BorderThickness="0,1,0,0">
          <Button x:Name="LaBtnAssign" Content="Assign Selected Licence"
                  Style="{StaticResource ActionBtn}" Background="#6366F1"
                  Padding="12,7" IsEnabled="False" HorizontalAlignment="Left"/>
        </Border>
      </Grid>
    </Grid>
  </Grid>

</Grid>
'@

function Initialize-LicenceAssignmentTool {
    $reader  = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new((Invoke-ThemeXaml $Script:LaXaml)))
    $content = [System.Windows.Markup.XamlReader]::Load($reader)

    $Script:LA_UI = @{
        UserSearch           = $content.FindName('LaUserSearch')
        UserList             = $content.FindName('LaUserList')
        SelName              = $content.FindName('LaSelName')
        SelUpn               = $content.FindName('LaSelUpn')
        AssignedHeader       = $content.FindName('LaAssignedHeader')
        AssignedList         = $content.FindName('LaAssignedList')
        AssignedPlaceholder  = $content.FindName('LaAssignedPlaceholder')
        AvailableHeader      = $content.FindName('LaAvailableHeader')
        AvailableList        = $content.FindName('LaAvailableList')
        AvailablePlaceholder = $content.FindName('LaAvailablePlaceholder')
        BtnRemove            = $content.FindName('LaBtnRemove')
        BtnAssign            = $content.FindName('LaBtnAssign')
    }

    $Script:LA_UI.UserSearch.Add_TextChanged({
        try { Invoke-EtbDebounced -Key 'LA_User' -Command 'Update-LaUserFilter' }
        catch { Write-Log "LA UserSearch error: $_" 'ERROR' }
    })

    $Script:LA_UI.UserList.Add_SelectionChanged({
        try {
            $sel  = $Script:LA_UI.UserList.SelectedItem
            $user = if ($sel) { $sel.Tag } else { $null }
            Set-LaUserSelected $user
        } catch { Write-Log "LA UserList SelectionChanged error: $_" 'ERROR' }
    })

    $Script:LA_UI.AssignedList.Add_SelectionChanged({
        try {
            $Script:LA_UI.BtnRemove.IsEnabled = ($null -ne $Script:LA_UI.AssignedList.SelectedItem)
        } catch { Write-Log "LA AssignedList SelectionChanged error: $_" 'ERROR' }
    })

    $Script:LA_UI.AvailableList.Add_SelectionChanged({
        try {
            $Script:LA_UI.BtnAssign.IsEnabled = ($null -ne $Script:LA_UI.AvailableList.SelectedItem)
        } catch { Write-Log "LA AvailableList SelectionChanged error: $_" 'ERROR' }
    })

    $Script:LA_UI.BtnRemove.Add_Click({
        try { Start-LaRemove }
        catch { Write-Log "LA BtnRemove click error: $_" 'ERROR' }
    })

    $Script:LA_UI.BtnAssign.Add_Click({
        try { Start-LaAssign }
        catch { Write-Log "LA BtnAssign click error: $_" 'ERROR' }
    })

    Register-ConnectCallback 'Start-LaUserLoad'
    Register-ConnectCallback 'Start-LaSkuLoad'
    $Script:ResetCallbacks.Add({
        $Script:LA_AllUsers     = @()
        $Script:LA_AllSkus      = @()
        $Script:LA_SelectedUser = $null
        if ($Script:LA_SkuTimer)    { $Script:LA_SkuTimer.Stop() }
        if ($Script:LA_LicTimer)    { $Script:LA_LicTimer.Stop() }
        if ($Script:LA_ActionTimer) { $Script:LA_ActionTimer.Stop() }
        Clear-EtbList $Script:LA_UI.UserList
        $Script:LA_UI.UserSearch.Text      = ''
        $Script:LA_UI.UserSearch.IsEnabled = $false
        $Script:LA_UI.UserList.IsEnabled   = $false
        $Script:LA_UI.SelName.Text         = 'No user selected'
        $Script:LA_UI.SelUpn.Text          = ''
        $Script:LA_UI.AssignedHeader.Text  = 'ASSIGNED LICENCES'
        $Script:LA_UI.AvailableHeader.Text = 'AVAILABLE TO ASSIGN'
        $Script:LA_UI.AssignedList.Items.Clear()
        $Script:LA_UI.AvailableList.Items.Clear()
        $Script:LA_UI.AssignedPlaceholder.Text       = 'Select a user to view licences.'
        $Script:LA_UI.AssignedPlaceholder.Visibility = 'Visible'
        $Script:LA_UI.AvailablePlaceholder.Text       = 'Select a user to view available licences.'
        $Script:LA_UI.AvailablePlaceholder.Visibility = 'Visible'
        $Script:LA_UI.BtnRemove.IsEnabled = $false
        $Script:LA_UI.BtnAssign.IsEnabled = $false
    })

    Write-LaLog 'Licence Assignment ready. Select a tenant to begin.' 'Muted'
    return $content
}
