<#
    Main shell window for Art's Entra Toolbox.
    Dot-sourced by Start.ps1. Exposes Show-MainWindow.

    Navigation: vertical sidebar with categorised tool entries.
    Each tool's panel is initialised once and swapped into the
    ContentControl on the right as the user clicks nav items.
#>

$Script:MainUI         = $null
$Script:DlgWin         = $null
$Script:DlgTid         = $null
$Script:DlgName        = $null
$Script:DlgStat        = $null
$Script:DlgOk          = $null
$Script:DlgCancel      = $null

# ── Nav state ──────────────────────────────────────────────────────────────────
$Script:NavItems       = [System.Collections.Generic.List[hashtable]]::new()
$Script:NavContents    = @{}
$Script:CurrentNavItem = $null

# ── Helpers ────────────────────────────────────────────────────────────────────
function New-SolidBrush([string]$HexOrSemantic) {
    $hex = Get-ThemeHex $HexOrSemantic
    [System.Windows.Media.BrushConverter]::new().ConvertFromString($hex)
}

function Set-MainStatus {
    param([string]$Text, [string]$Color = 'TextDim')
    $Script:MainUI.Status.Text       = $Text
    $Script:MainUI.Status.Foreground = New-SolidBrush $Color
}

# ── Nav builders ───────────────────────────────────────────────────────────────
function New-NavCategory {
    param([string]$Label)
    $tb            = [System.Windows.Controls.TextBlock]::new()
    $tb.Text       = $Label
    $tb.Foreground = New-SolidBrush 'Muted'
    $tb.FontSize   = 10
    $tb.FontWeight = [System.Windows.FontWeights]::Bold
    $tb.Margin     = [System.Windows.Thickness]::new(17, 20, 12, 4)
    return $tb
}

function New-NavItem {
    param([string]$Name, [string]$Title, [string]$Subtitle)

    $border                 = [System.Windows.Controls.Border]::new()
    $border.Cursor          = [System.Windows.Input.Cursors]::Hand
    $border.Padding         = [System.Windows.Thickness]::new(17, 9, 12, 9)
    $border.Background      = [System.Windows.Media.Brushes]::Transparent
    $border.BorderThickness = [System.Windows.Thickness]::new(3, 0, 0, 0)
    $border.BorderBrush     = [System.Windows.Media.Brushes]::Transparent

    $titleTb             = [System.Windows.Controls.TextBlock]::new()
    $titleTb.Text        = $Title
    $titleTb.Foreground  = New-SolidBrush 'TextDim'
    $titleTb.FontSize    = 13
    $titleTb.FontWeight  = [System.Windows.FontWeights]::SemiBold
    $titleTb.TextWrapping = [System.Windows.TextWrapping]::Wrap

    $subtitleTb              = [System.Windows.Controls.TextBlock]::new()
    $subtitleTb.Text         = $Subtitle
    $subtitleTb.Foreground   = New-SolidBrush 'Muted'
    $subtitleTb.FontSize     = 11
    $subtitleTb.Margin       = [System.Windows.Thickness]::new(0, 3, 0, 0)
    $subtitleTb.TextWrapping = [System.Windows.TextWrapping]::Wrap

    $sp = [System.Windows.Controls.StackPanel]::new()
    [void]$sp.Children.Add($titleTb)
    [void]$sp.Children.Add($subtitleTb)
    $border.Child = $sp

    $item = @{ Name = $Name; Border = $border; TitleTb = $titleTb }

    # Capture locals for event handler closures
    $cn          = $Name
    $ci          = $item
    $hoverBrush  = New-SolidBrush 'SubHeader'

    $border.Add_MouseEnter({
        try { if ($Script:CurrentNavItem -ne $cn) { $ci.Border.Background = $hoverBrush } }
        catch {}
    })
    $border.Add_MouseLeave({
        try { if ($Script:CurrentNavItem -ne $cn) { $ci.Border.Background = [System.Windows.Media.Brushes]::Transparent } }
        catch {}
    })
    # ScrollViewer captures the mouse on MouseLeftButtonDown to enable drag-
    # scrolling, which redirects all subsequent mouse events away from child
    # elements.  Use AddHandler with handledEventsToo=$true so our handler
    # fires even after the ScrollViewer has taken mouse capture.
    $clickHandler = [System.Windows.Input.MouseButtonEventHandler]{
        param($s, $e)
        Write-Host "[NAV] click on '$cn'" -ForegroundColor DarkGray
        try { Set-NavSelection -Name $cn }
        catch {
            Write-Host "[ERROR] NavItem '$cn' click: $_" -ForegroundColor Red
            try { Write-Log "NavItem '$cn' click error: $_" 'ERROR' } catch {}
        }
    }
    $border.AddHandler(
        [System.Windows.UIElement]::MouseLeftButtonDownEvent,
        $clickHandler,
        $true   # handledEventsToo
    )

    return $item
}

function Set-NavSelection {
    param([string]$Name)
    Write-Host "[NAV] Set-NavSelection called: $Name" -ForegroundColor DarkGray
    if ($Script:CurrentNavItem -eq $Name) { Write-Host "[NAV] already selected, skipping" -ForegroundColor DarkGray; return }

    $accentBrush = New-SolidBrush 'Accent'
    $selBrush    = New-SolidBrush 'Hover'
    $textBrush   = New-SolidBrush 'Text'
    $dimBrush    = New-SolidBrush 'TextDim'

    foreach ($item in $Script:NavItems) {
        if ($item.Name -eq $Name) {
            $item.Border.Background  = $selBrush
            $item.Border.BorderBrush = $accentBrush
            $item.TitleTb.Foreground = $textBrush
        } else {
            $item.Border.Background  = [System.Windows.Media.Brushes]::Transparent
            $item.Border.BorderBrush = [System.Windows.Media.Brushes]::Transparent
            $item.TitleTb.Foreground = $dimBrush
        }
    }

    if ($Script:NavContents.ContainsKey($Name)) {
        $Script:MainUI.ContentArea.Content = $Script:NavContents[$Name]
    }
    $Script:CurrentNavItem = $Name
}

# ── Main window XAML ───────────────────────────────────────────────────────────
$Script:MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Art's Entra Toolbox" Width="1280" Height="800"
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

    <!-- ── Header ──────────────────────────────────────────────────────────── -->
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
            <TextBlock Text="Tenant management toolkit" Foreground="#50507A" FontSize="11"/>
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

    <!-- ── Tenant bar ──────────────────────────────────────────────────────── -->
    <Border Grid.Row="1" x:Name="MainTenantBar" Background="#1C1C2A"
            BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
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

    <!-- ── Navigation sidebar + content area ──────────────────────────────── -->
    <Grid Grid.Row="2">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="230" MinWidth="160"/>
        <ColumnDefinition Width="4"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- Sidebar -->
      <Border Grid.Column="0" Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="0,0,1,0">
        <DockPanel>
          <!-- version label pinned to bottom -->
          <TextBlock x:Name="MainVersion" DockPanel.Dock="Bottom"
                     Foreground="#3C3C5A" FontSize="11"
                     Margin="17,8,12,10" VerticalAlignment="Center"/>
          <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel x:Name="NavPanel" Margin="0,8,0,16"/>
          </ScrollViewer>
        </DockPanel>
      </Border>

      <!-- Splitter -->
      <GridSplitter Grid.Column="1" Width="4" HorizontalAlignment="Stretch"
                    Background="#3C3C5A" Cursor="SizeWE" ResizeBehavior="PreviousAndNext"/>

      <!-- Tool content -->
      <ContentControl x:Name="MainContentArea" Grid.Column="2" Focusable="False"/>
    </Grid>

    <!-- ── Status bar ──────────────────────────────────────────────────────── -->
    <Border Grid.Row="3" x:Name="MainStatusBar" Background="#1C1C2A"
            BorderBrush="#3C3C5A" BorderThickness="0,1,0,0">
      <Grid Margin="14,0">
        <TextBlock x:Name="MainStatus" Text="Ready — select a tenant to begin"
                   Foreground="#50507A" FontSize="11" VerticalAlignment="Center"/>
      </Grid>
    </Border>

  </Grid>
</Window>
'@

# ── Add-tenant dialog XAML (unchanged) ─────────────────────────────────────────
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
        $item         = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $label
        $item.Tag     = $t
        $Script:MainUI.TenantCombo.Items.Add($item) | Out-Null
    }
    $Script:MainUI.TenantCombo.IsEnabled = $tenants.Count -gt 0
    $Script:MainUI.BtnRemove.IsEnabled   = $tenants.Count -gt 0
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
    try {
        $name = Get-TenantDisplayName
        if ($name) {
            $Script:MainUI.TenantName.Text        = $name
            $Script:MainUI.TenantBadge.Visibility = 'Visible'
        }
    } catch {}

    $Script:MainUI.BtnDisconnect.IsEnabled = $true
    if (-not $Script:DemoMode -and $Script:CurrentTenantId) {
        try { Set-AppSetting -Name 'LastTenantId' -Value $Script:CurrentTenantId } catch {}
    }
    Invoke-ConnectCallbacks
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
        Window          = $window
        TenantCombo     = $window.FindName('TenantCombo')
        BtnAddTenant    = $window.FindName('BtnAddTenant')
        BtnRemove       = $window.FindName('BtnRemoveTenant')
        BtnDisconnect   = $window.FindName('BtnDisconnect')
        TenantBadge     = $window.FindName('TenantBadge')
        TenantName      = $window.FindName('LblTenantName')
        NavPanel        = $window.FindName('NavPanel')
        ContentArea     = $window.FindName('MainContentArea')
        Status          = $window.FindName('MainStatus')
        Version         = $window.FindName('MainVersion')
        BtnDemo         = $window.FindName('BtnDemo')
        HeaderBorder    = $window.FindName('MainHeaderBorder')
        TenantBarBorder = $window.FindName('MainTenantBar')
        StatusBarBorder = $window.FindName('MainStatusBar')
    }

    if ($AppVersion) { $Script:MainUI.Version.Text = "v$AppVersion" }

    # ── Initialise all tools and store their panels ───────────────────────────
    Write-Log 'MainWindow: initialising tools' 'DEBUG'
    $Script:NavContents['YearGroup']   = Initialize-PasswordResetTool
    $Script:NavContents['UserReset']   = Initialize-UserPasswordResetTool
    $Script:NavContents['BulkUpn']     = Initialize-BulkUpnChangeTool
    $Script:NavContents['ImmutableId'] = Initialize-ImmutableIdTool
    $Script:NavContents['LastDevice']  = Initialize-LastDeviceTool
    $Script:NavContents['SignIn']      = Initialize-SignInLogsTool
    $Script:NavContents['GroupCopy']   = Initialize-GroupCopyTool
    $Script:NavContents['Teams']       = Initialize-TeamsProvisioningTool
    Write-Log 'MainWindow: tools initialised' 'INFO'

    # ── Build nav sidebar ─────────────────────────────────────────────────────
    $navDef = @(
        @{ Type = 'cat';  Label = 'USERS' }
        @{ Type = 'tool'; Name = 'YearGroup';   Title = 'Year Group Passwords'; Desc = 'Reset passwords for an entire year group' }
        @{ Type = 'tool'; Name = 'UserReset';   Title = 'User Password Reset';  Desc = 'Reset a single account password' }
        @{ Type = 'tool'; Name = 'BulkUpn';     Title = 'Bulk UPN Change';      Desc = 'Move users to a different verified domain' }
        @{ Type = 'tool'; Name = 'ImmutableId'; Title = 'Immutable ID';         Desc = 'Assign AD Connect anchor IDs' }
        @{ Type = 'cat';  Label = 'DEVICES' }
        @{ Type = 'tool'; Name = 'LastDevice';  Title = 'Last Device';          Desc = 'Login history and stale device detection' }
        @{ Type = 'cat';  Label = 'AUDIT' }
        @{ Type = 'tool'; Name = 'SignIn';       Title = 'Sign-In Logs';        Desc = 'Browse Entra ID sign-in events' }
        @{ Type = 'cat';  Label = 'GROUPS & TEAMS' }
        @{ Type = 'tool'; Name = 'GroupCopy';   Title = 'Group Copy';           Desc = 'Copy memberships from one user to another' }
        @{ Type = 'tool'; Name = 'Teams';        Title = 'Teams Provisioning';  Desc = 'Create and populate Microsoft Teams' }
    )

    foreach ($def in $navDef) {
        if ($def.Type -eq 'cat') {
            [void]$Script:MainUI.NavPanel.Children.Add((New-NavCategory -Label $def.Label))
        } else {
            $item = New-NavItem -Name $def.Name -Title $def.Title -Subtitle $def.Desc
            [void]$Script:MainUI.NavPanel.Children.Add($item.Border)
            $Script:NavItems.Add($item)
        }
    }

    # Select first tool by default
    Set-NavSelection -Name 'YearGroup'

    # ── Demo button ───────────────────────────────────────────────────────────
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

    # ── Add tenant ────────────────────────────────────────────────────────────
    $Script:MainUI.BtnAddTenant.Add_Click({
        try { Show-AddTenantDialog }
        catch { Write-Log "BtnAddTenant click error: $_" 'ERROR' }
    })

    # ── Remove tenant ─────────────────────────────────────────────────────────
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

    # ── Disconnect ────────────────────────────────────────────────────────────
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

    # ── Tenant combo → authenticate ───────────────────────────────────────────
    $Script:MainUI.TenantCombo.Add_SelectionChanged({
        try {
            $sel = $Script:MainUI.TenantCombo.SelectedItem
            if (-not $sel) { return }

            Write-Log "TenantCombo: selected '$($sel.Content)'" 'INFO'
            $Script:DemoMode = $false
            Invoke-ResetTools
            $Script:MainUI.TenantCombo.IsEnabled  = $false
            $Script:MainUI.BtnAddTenant.IsEnabled = $false
            $Script:MainUI.BtnRemove.IsEnabled    = $false
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

    # ── Window loaded → populate combo and auto-connect ───────────────────────
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
