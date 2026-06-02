<#
    Main shell window for Art's Entra Toolbox.
    Dot-sourced by Start.ps1. Exposes Show-MainWindow.
#>

$Script:MainUI  = $null
$Script:DlgWin  = $null
$Script:DlgTid  = $null
$Script:DlgName = $null
$Script:DlgStat = $null
$Script:DlgOk   = $null
$Script:DlgCancel = $null

function Set-MainStatus {
    param([string]$Text, [string]$Color = 'TextDim')
    $Script:MainUI.Status.Text       = $Text
    $Script:MainUI.Status.Foreground = Get-ThemeHex $Color
}

$Script:MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Art's Entra Toolbox" Width="1200" Height="780"
        MinWidth="900" MinHeight="600"
        Background="#12121C" FontFamily="Segoe UI" FontSize="13"
        WindowStartupLocation="CenterScreen">
  <Window.Resources>

    <Style x:Key="FlatBtn" TargetType="Button">
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

    <Style TargetType="TabControl">
      <Setter Property="Background"      Value="#12121C"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding"         Value="0"/>
    </Style>

    <Style TargetType="TabItem">
      <Setter Property="Foreground"      Value="#7878A0"/>
      <Setter Property="Background"      Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding"         Value="20,12"/>
      <Setter Property="FontWeight"      Value="SemiBold"/>
      <Setter Property="FontSize"        Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border Padding="{TemplateBinding Padding}" Cursor="Hand">
              <Border x:Name="ind" BorderThickness="0,0,0,2" BorderBrush="Transparent" Padding="0,0,0,2">
                <ContentPresenter ContentSource="Header"/>
              </Border>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter Property="Foreground" Value="#E2E2F0"/>
                <Setter TargetName="ind" Property="BorderBrush" Value="#6366F1"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="#C0C0E0"/>
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
      <Setter Property="MaxDropDownHeight" Value="220"/>
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
                                        RelativeSource={RelativeSource TemplatedParent},
                                        Mode=TwoWay}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Rectangle Fill="Transparent"/>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <Popup x:Name="PART_Popup" AllowsTransparency="True"
                     IsOpen="{Binding IsDropDownOpen,
                              RelativeSource={RelativeSource TemplatedParent}}"
                     Placement="Bottom" PopupAnimation="Slide">
                <Border Background="#242436" BorderBrush="#3C3C5A" BorderThickness="1"
                        CornerRadius="0,0,4,4"
                        MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <ScrollViewer>
                    <ItemsPresenter/>
                  </ScrollViewer>
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

  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="60"/>
      <RowDefinition Height="50"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="32"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <Border Grid.Row="0" x:Name="MainHeaderBorder" Background="#1C1C2A">
      <Border.Effect>
        <DropShadowEffect BlurRadius="10" ShadowDepth="2" Opacity="0.35" Color="Black"/>
      </Border.Effect>
      <Grid Margin="20,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Border Width="30" Height="30" CornerRadius="7" Background="#6366F1" Margin="0,0,12,0">
            <TextBlock Text="E" Foreground="White" FontWeight="Bold" FontSize="16"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel VerticalAlignment="Center">
            <TextBlock Text="Art's Entra Toolbox" Foreground="White" FontSize="15" FontWeight="Bold"/>
            <TextBlock Text="Tenant management toolkit"
                       Foreground="#50507A" FontSize="11"/>
          </StackPanel>
        </StackPanel>
        <Border Grid.Column="1" x:Name="TenantBadge" CornerRadius="4"
                Background="#242436" Padding="10,5" VerticalAlignment="Center" Visibility="Collapsed">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Ellipse Width="7" Height="7" Fill="#22C55E" Margin="0,0,6,0" VerticalAlignment="Center"/>
            <TextBlock x:Name="LblTenantName" Foreground="#6366F1" FontSize="11" FontWeight="SemiBold"
                       VerticalAlignment="Center"/>
          </StackPanel>
        </Border>
      </Grid>
    </Border>

    <!-- Tenant bar -->
    <Border Grid.Row="1" x:Name="MainTenantBar" Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="16,0">
        <TextBlock Text="Tenant:" Foreground="#7878A0" VerticalAlignment="Center" Margin="0,0,10,0"/>
        <ComboBox x:Name="TenantCombo" Width="280" IsEnabled="False"/>
        <Button x:Name="BtnAddTenant" Content="+" Style="{StaticResource FlatBtn}"
                Background="#6366F1" Padding="10,6" Margin="8,0,0,0"
                FontSize="16" ToolTip="Add a new tenant" Width="34"/>
        <Button x:Name="BtnRemoveTenant" Content="-" Style="{StaticResource FlatBtn}"
                Background="#3C3C5A" Padding="10,6" Margin="4,0,0,0"
                FontSize="16" ToolTip="Remove selected tenant" Width="34" IsEnabled="False"/>
        <Button x:Name="BtnDisconnect" Content="Disconnect" Style="{StaticResource FlatBtn}"
                Background="#EF4444" Padding="10,6" Margin="12,0,0,0"
                ToolTip="Sign out and clear saved credentials for this tenant" IsEnabled="False"/>
        <Button x:Name="BtnDemo" Content="Demo" Style="{StaticResource FlatBtn}"
                Background="#7C3AED" Padding="10,6" Margin="12,0,0,0"
                ToolTip="Run in demo mode with fake Contoso Academy data"/>
      </StackPanel>
    </Border>

    <!-- Main TabControl -->
    <TabControl x:Name="MainTabs" Grid.Row="2">
      <TabControl.Template>
        <ControlTemplate TargetType="TabControl">
          <Grid Background="#12121C">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
              <TabPanel IsItemsHost="True" Margin="4,0"/>
            </Border>
            <ContentPresenter Grid.Row="1" ContentSource="SelectedContent"/>
          </Grid>
        </ControlTemplate>
      </TabControl.Template>
      <TabItem x:Name="TabPwReset"     Header="Year Group Passwords"/>
      <TabItem x:Name="TabPwUser"      Header="User Password Reset"/>
      <TabItem x:Name="TabLastDevice"  Header="Last Device"/>
      <TabItem x:Name="TabSignIn"      Header="Sign-In Logs"/>
      <TabItem x:Name="TabGroupCopy"   Header="Group Copy"/>
      <TabItem x:Name="TabTeams"       Header="Teams Provisioning"/>
    </TabControl>

    <!-- Status bar -->
    <Border Grid.Row="3" x:Name="MainStatusBar" Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="0,1,0,0">
      <Grid Margin="14,0">
        <TextBlock x:Name="MainStatus" Text="Ready - select a tenant to begin"
                   Foreground="#50507A" FontSize="11" VerticalAlignment="Center"/>
        <TextBlock x:Name="MainVersion" Foreground="#3C3C5A" FontSize="11"
                   VerticalAlignment="Center" HorizontalAlignment="Right"/>
      </Grid>
    </Border>

  </Grid>
</Window>
'@

$Script:AddTenantXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Add Tenant" Width="400" Height="230"
        WindowStyle="ToolWindow" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner"
        ShowInTaskbar="False"
        Background="#1C1C2A" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
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
      <Setter Property="Background"      Value="#242436"/>
      <Setter Property="Foreground"      Value="#E2E2F0"/>
      <Setter Property="BorderBrush"     Value="#3C3C5A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Height"          Value="32"/>
      <Setter Property="Padding"         Value="8,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="CaretBrush"      Value="#E2E2F0"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
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
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#7878A0"/>
      <Setter Property="FontSize"   Value="11"/>
    </Style>
  </Window.Resources>
  <Grid Margin="20,16,20,16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="10"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="10"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="16"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <StackPanel Grid.Row="0">
      <TextBlock Text="Tenant ID" Margin="0,0,0,4"/>
      <TextBox x:Name="DlgTenantId"/>
    </StackPanel>
    <StackPanel Grid.Row="2">
      <TextBlock Text="Display name (optional)" Margin="0,0,0,4"/>
      <TextBox x:Name="DlgDisplayName"/>
    </StackPanel>
    <TextBlock x:Name="DlgStatus" Grid.Row="4" Foreground="#EF4444"
               FontSize="11" TextWrapping="Wrap" Visibility="Collapsed"/>
    <Grid Grid.Row="6">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="8"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <Button x:Name="DlgCancel" Grid.Column="0" Content="Cancel"
              Style="{StaticResource Btn}" Background="#3C3C5A" Padding="0,8"/>
      <Button x:Name="DlgConnect" Grid.Column="2" Content="Connect"
              Style="{StaticResource Btn}" Background="#6366F1" Padding="20,8"/>
    </Grid>
  </Grid>
</Window>
'@

# ── Tenant combo helpers ───────────────────────────────────────────────────────
function Update-TenantCombo {
    $tenants = @(Get-SavedTenants)
    $Script:MainUI.TenantCombo.Items.Clear()
    foreach ($t in $tenants) {
        $label = if ($t.DisplayName) { $t.DisplayName } else { $t.TenantId }
        $t | Add-Member -NotePropertyName 'Label' -NotePropertyValue $label -Force
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $label
        $item.Tag     = $t
        $Script:MainUI.TenantCombo.Items.Add($item) | Out-Null
    }
    $Script:MainUI.TenantCombo.IsEnabled  = $tenants.Count -gt 0
    $Script:MainUI.BtnRemove.IsEnabled    = $tenants.Count -gt 0
}

function Show-AddTenantDialog {
    $reader            = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new((Invoke-ThemeXaml $Script:AddTenantXaml)))
    $Script:DlgWin     = [System.Windows.Markup.XamlReader]::Load($reader)
    $Script:DlgWin.Owner = $Script:MainUI.Window
    $Script:DlgTid     = $Script:DlgWin.FindName('DlgTenantId')
    $Script:DlgName    = $Script:DlgWin.FindName('DlgDisplayName')
    $Script:DlgStat    = $Script:DlgWin.FindName('DlgStatus')
    $Script:DlgOk      = $Script:DlgWin.FindName('DlgConnect')
    $Script:DlgCancel  = $Script:DlgWin.FindName('DlgCancel')

    $Script:DlgCancel.Add_Click({
        try { $Script:DlgWin.Close() }
        catch { Write-Log "DlgCancel click error: $_" 'ERROR' }
    })

    $Script:DlgOk.Add_Click({
        try {
            $tid   = $Script:DlgTid.Text.Trim()
            $dname = $Script:DlgName.Text.Trim()
            Write-Log "DlgConnect: attempting tenant $tid" 'INFO'

            if ([string]::IsNullOrWhiteSpace($tid)) {
                $Script:DlgStat.Text       = 'Tenant ID is required.'
                $Script:DlgStat.Visibility = 'Visible'
                return
            }

            $Script:DlgOk.IsEnabled     = $false
            $Script:DlgCancel.IsEnabled = $false
            $Script:DlgTid.IsEnabled    = $false
            $Script:DlgName.IsEnabled   = $false
            $Script:DlgStat.Visibility  = 'Collapsed'
            Set-MainStatus 'Authenticating...' 'TextDim'

            Start-TenantConnectAsync -TenantId $tid `
                -OnSuccess {
                    Write-Log "DlgConnect: auth succeeded for $($Script:DlgTid.Text.Trim())" 'INFO'
                    Save-Tenant -TenantId $Script:DlgTid.Text.Trim() `
                                -DisplayName $Script:DlgName.Text.Trim()
                    Update-TenantCombo

                    for ($i = 0; $i -lt $Script:MainUI.TenantCombo.Items.Count; $i++) {
                        if ($Script:MainUI.TenantCombo.Items[$i].Tag.TenantId -eq $Script:DlgTid.Text.Trim()) {
                            $Script:MainUI.TenantCombo.SelectedIndex = $i
                            break
                        }
                    }
                    $Script:DlgWin.Close()
                    Invoke-PostConnect
                } `
                -OnFailure {
                    param($err)
                    Write-Log "DlgConnect: auth failed - $err" 'ERROR'
                    $Script:DlgStat.Text        = "Failed: $err"
                    $Script:DlgStat.Visibility  = 'Visible'
                    $Script:DlgOk.IsEnabled     = $true
                    $Script:DlgCancel.IsEnabled = $true
                    $Script:DlgTid.IsEnabled    = $true
                    $Script:DlgName.IsEnabled   = $true
                    Set-MainStatus 'Authentication failed.' 'Danger'
                }
        } catch {
            Write-Log "DlgConnect click error: $_" 'ERROR'
        }
    })

    $Script:DlgWin.Show()
    $Script:DlgTid.Focus() | Out-Null
}

function Invoke-PostConnect {
    # Get real tenant display name from Graph and update header
    try {
        $name = Get-TenantDisplayName
        if ($name) {
            $Script:MainUI.TenantName.Text         = $name
            $Script:MainUI.TenantBadge.Visibility  = 'Visible'
        }
    } catch {}

    $Script:MainUI.BtnDisconnect.IsEnabled = $true
    # Remember the tenant we just connected to so the next launch reconnects to it.
    if (-not $Script:DemoMode -and $Script:CurrentTenantId) {
        try { Set-AppSetting -Name 'LastTenantId' -Value $Script:CurrentTenantId } catch {}
    }
    # Fire all connect callbacks (each tool loads its data)
    foreach ($cb in $Script:ConnectCallbacks) { & $cb }
    Set-MainStatus 'Connected.' 'Success'
}

function Invoke-ResetTools {
    foreach ($cb in $Script:ResetCallbacks) { & $cb }
    $Script:MainUI.TenantBadge.Visibility  = 'Collapsed'
    $Script:MainUI.TenantName.Text         = ''
    $Script:AccessToken                    = $null
    $Script:MainUI.BtnDisconnect.IsEnabled = $false
}

# ── Show-MainWindow ────────────────────────────────────────────────────────────
function Show-MainWindow {
    param([string]$AppVersion = '')

    Write-Log 'MainWindow: loading WPF assemblies' 'DEBUG'
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    Write-Log 'MainWindow: parsing XAML' 'DEBUG'
    $reader = New-Object System.Xml.XmlNodeReader ([xml](Invoke-ThemeXaml $Script:MainXaml))
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $Script:MainUI = @{
        Window           = $window
        TenantCombo      = $window.FindName('TenantCombo')
        BtnAddTenant     = $window.FindName('BtnAddTenant')
        BtnRemove        = $window.FindName('BtnRemoveTenant')
        BtnDisconnect    = $window.FindName('BtnDisconnect')
        TenantBadge      = $window.FindName('TenantBadge')
        TenantName       = $window.FindName('LblTenantName')
        Tabs             = $window.FindName('MainTabs')
        TabPwReset       = $window.FindName('TabPwReset')
        TabPwUser        = $window.FindName('TabPwUser')
        TabLastDevice    = $window.FindName('TabLastDevice')
        TabSignIn        = $window.FindName('TabSignIn')
        TabGroupCopy     = $window.FindName('TabGroupCopy')
        TabTeams         = $window.FindName('TabTeams')
        Status           = $window.FindName('MainStatus')
        Version          = $window.FindName('MainVersion')
        BtnDemo          = $window.FindName('BtnDemo')
        HeaderBorder     = $window.FindName('MainHeaderBorder')
        TenantBarBorder  = $window.FindName('MainTenantBar')
        StatusBarBorder  = $window.FindName('MainStatusBar')
    }

    if ($AppVersion) { $Script:MainUI.Version.Text = "v$AppVersion" }

    Write-Log 'MainWindow: initializing Year Group Passwords tool' 'DEBUG'
    $Script:MainUI.TabPwReset.Content    = Initialize-PasswordResetTool
    Write-Log 'MainWindow: initializing User Password Reset tool' 'DEBUG'
    $Script:MainUI.TabPwUser.Content     = Initialize-UserPasswordResetTool
    Write-Log 'MainWindow: initializing Last Device tool' 'DEBUG'
    $Script:MainUI.TabLastDevice.Content = Initialize-LastDeviceTool
    Write-Log 'MainWindow: initializing Sign-In Logs tool' 'DEBUG'
    $Script:MainUI.TabSignIn.Content     = Initialize-SignInLogsTool
    Write-Log 'MainWindow: initializing Group Copy tool' 'DEBUG'
    $Script:MainUI.TabGroupCopy.Content  = Initialize-GroupCopyTool
    Write-Log 'MainWindow: initializing Teams Provisioning tool' 'DEBUG'
    $Script:MainUI.TabTeams.Content      = Initialize-TeamsProvisioningTool
    Write-Log 'MainWindow: tools initialized' 'INFO'

    # Demo mode button
    $Script:MainUI.BtnDemo.Add_Click({
        try {
            $Script:MainUI.TenantCombo.SelectedIndex = -1
            Write-Log 'Demo mode activated - Contoso Academy' 'INFO'
            $Script:DemoMode = $true
            Invoke-ResetTools
            $Script:AccessToken = 'DEMO'
            Invoke-PostConnect
        } catch {
            Write-Log "BtnDemo click error: $_" 'ERROR'
        }
    })

    # Add Tenant button
    $Script:MainUI.BtnAddTenant.Add_Click({
        try { Show-AddTenantDialog }
        catch { Write-Log "BtnAddTenant click error: $_" 'ERROR' }
    })

    # Remove tenant
    $Script:MainUI.BtnRemove.Add_Click({
        try {
            $sel = $Script:MainUI.TenantCombo.SelectedItem
            if (-not $sel) { return }
            $tid = $sel.Tag.TenantId
            Write-Log "BtnRemove: removing tenant $tid" 'DEBUG'
            $confirm = [System.Windows.MessageBox]::Show(
                "Remove tenant '$($sel.Content)'?",
                'Remove Tenant', 'YesNo', 'Question')
            if ($confirm -ne 'Yes') { return }
            Disconnect-Tenant -TenantId $tid
            Remove-SavedTenant -TenantId $tid
            Invoke-ResetTools
            Update-TenantCombo
            Set-MainStatus 'Tenant removed.' 'TextDim'
        } catch {
            Write-Log "BtnRemove click error: $_" 'ERROR'
        }
    })

    # Disconnect (sign out + clear cached credentials)
    $Script:MainUI.BtnDisconnect.Add_Click({
        try {
            $sel = $Script:MainUI.TenantCombo.SelectedItem
            if (-not $sel) { return }
            $tid = $sel.Tag.TenantId
            Write-Log "BtnDisconnect: signing out of tenant $tid" 'INFO'
            Disconnect-Tenant -TenantId $tid
            Invoke-ResetTools
            Set-MainStatus 'Signed out. Select tenant to reconnect.' 'TextDim'
        } catch {
            Write-Log "BtnDisconnect click error: $_" 'ERROR'
        }
    })

    # Tenant combo selection -> authenticate
    $Script:MainUI.TenantCombo.Add_SelectionChanged({
        try {
            $sel = $Script:MainUI.TenantCombo.SelectedItem
            if (-not $sel) { return }

            Write-Log "TenantCombo: selected '$($sel.Content)'" 'INFO'
            $Script:DemoMode = $false
            Invoke-ResetTools
            $Script:MainUI.TenantCombo.IsEnabled    = $false
            $Script:MainUI.BtnAddTenant.IsEnabled   = $false
            $Script:MainUI.BtnRemove.IsEnabled      = $false
            Set-MainStatus "Connecting to $($sel.Content)..." 'TextDim'

            Start-TenantConnectAsync -TenantId $sel.Tag.TenantId `
                -OnSuccess {
                    Write-Log 'TenantCombo: connect succeeded' 'INFO'
                    $Script:MainUI.TenantCombo.IsEnabled  = $true
                    $Script:MainUI.BtnAddTenant.IsEnabled = $true
                    $Script:MainUI.BtnRemove.IsEnabled    = $true
                    Invoke-PostConnect
                } `
                -OnFailure {
                    param($err)
                    Write-Log "TenantCombo: connect failed - $err" 'ERROR'
                    $Script:MainUI.TenantCombo.IsEnabled  = $true
                    $Script:MainUI.BtnAddTenant.IsEnabled = $true
                    $Script:MainUI.BtnRemove.IsEnabled    = $true
                    Set-MainStatus "Authentication failed: $err" 'Danger'
                }
        } catch {
            Write-Log "TenantCombo SelectionChanged error: $_" 'ERROR'
        }
    })

    # On load: populate tenant combo and auto-connect if credentials are cached
    $window.Add_Loaded({
        try {
            Write-Log 'Window loaded - populating tenant combo' 'INFO'
            Update-TenantCombo
            $tenants = @(Get-SavedTenants)
            Write-Log "Saved tenants: $($tenants.Count)" 'DEBUG'
            if ($tenants.Count -eq 0) {
                Set-MainStatus 'No tenants saved. Click + to add one.' 'TextDim'
                Show-AddTenantDialog
            } else {
                # Auto-select the last-used tenant (falling back to the first) — SelectionChanged
                # fires and attempts silent auth. If credentials are cached the user sees no
                # browser popup and lands straight back where they left off.
                $lastTid = Get-AppSetting -Name 'LastTenantId'
                $idx = 0
                if ($lastTid) {
                    for ($i = 0; $i -lt $Script:MainUI.TenantCombo.Items.Count; $i++) {
                        if ($Script:MainUI.TenantCombo.Items[$i].Tag.TenantId -eq $lastTid) { $idx = $i; break }
                    }
                }
                $Script:MainUI.TenantCombo.SelectedIndex = $idx
            }
        } catch {
            Write-Log "Window Loaded handler error: $_" 'ERROR'
        }
    })

    [void]$window.ShowDialog()
}
