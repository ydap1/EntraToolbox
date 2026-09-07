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
$Script:NavContents    = @{}   # name → built WPF panel (populated lazily)
$Script:CurrentNavItem = $null
$Script:TenantNameTimer = $null # async tenant display-name fetch after connect
$Script:SuppressTenantSelect = $false # guards TenantCombo SelectionChanged during programmatic updates

# Lazy-init maps: populated in Show-MainWindow, consumed in Set-NavSelection.
$Script:NavInitializers = @{}   # name → 'Initialize-*Tool' function name
$Script:NavConnectFns   = @{}   # name → array of connect-load function names
$Script:_LazyPanel      = $null # staging var: Set-NavSelection writes to it via InvokeScript

# ── Helpers ────────────────────────────────────────────────────────────────────
$Script:BrushCache = @{}
function New-SolidBrush([string]$HexOrSemantic) {
    if ($Script:BrushCache.ContainsKey($HexOrSemantic)) { return $Script:BrushCache[$HexOrSemantic] }
    $hex   = Get-ThemeHex $HexOrSemantic
    $brush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($hex)
    $brush.Freeze()
    $Script:BrushCache[$HexOrSemantic] = $brush
    $brush
}

function Set-MainStatus {
    param([string]$Text, [string]$Color = 'TextDim')
    $Script:MainUI.Status.Text       = $Text
    $Script:MainUI.Status.Foreground = New-SolidBrush $Color
}

function Update-EtbModeStatus {
    if (-not $Script:MainUI.ModeStatus) { return }
    $label = 'NOT CONNECTED'; $color = 'TextDim'
    if ($Script:AccessToken) {
        if ($Script:DemoMode) { $label = 'DEMO / OFFLINE'; $color = 'Accent' }
        elseif ($Script:DryMode) { $label = 'DRY RUN / PREVIEW'; $color = 'Warning' }
        else { $label = 'LIVE / CHANGES ENABLED'; $color = 'Danger' }
    }
    $Script:MainUI.ModeStatus.Text = $label
    $Script:MainUI.ModeStatus.Foreground = New-SolidBrush $color
}

# ── Nav builders ───────────────────────────────────────────────────────────────
function New-NavCategory {
    param([string]$Label)
    $tb            = [System.Windows.Controls.TextBlock]::new()
    $tb.Text       = $Label
    $tb.Foreground = New-SolidBrush 'Muted'
    $tb.FontSize   = 10
    $tb.FontWeight = [System.Windows.FontWeights]::Bold
    $tb.Margin     = [System.Windows.Thickness]::new(20, 16, 12, 6)
    return $tb
}

function New-NavItem {
    param([string]$Name, [string]$Title, [string]$Subtitle)
    $button = [System.Windows.Controls.Button]::new()
    $button.Style = $Script:MainUI.Window.FindResource('NavButton')
    $button.Tag = $Name
    $button.ToolTip = $Subtitle
    [System.Windows.Automation.AutomationProperties]::SetName($button, $Title)
    $titleTb = [System.Windows.Controls.TextBlock]::new()
    $titleTb.Text = $Title
    $titleTb.TextTrimming = 'CharacterEllipsis'
    $button.Content = $titleTb
    $button.Add_Click({
        param($navSender, $navEvent)
        try { Set-NavSelection -Name $navSender.Tag }
        catch { Write-Log "Navigation failed: $_" 'ERROR' }
    })
    $button.Add_PreviewKeyDown({
        param($navSender, $navEvent)
        $index = -1
        for ($i = 0; $i -lt $Script:NavItems.Count; $i++) {
            if ($Script:NavItems[$i].Name -eq $navSender.Tag) { $index = $i; break }
        }
        if ($navEvent.Key -eq 'Down') { $index = [math]::Min($index + 1, $Script:NavItems.Count - 1) }
        elseif ($navEvent.Key -eq 'Up') { $index = [math]::Max($index - 1, 0) }
        elseif ($navEvent.Key -eq 'Home') { $index = 0 }
        elseif ($navEvent.Key -eq 'End') { $index = $Script:NavItems.Count - 1 }
        else { return }
        [void]$Script:NavItems[$index].Border.Focus()
        $Script:NavItems[$index].Border.BringIntoView()
        $navEvent.Handled = $true
    })
    return @{ Name = $Name; Border = $button; TitleTb = $titleTb; Title = $Title; Subtitle = $Subtitle }
}

function Set-NavSelection {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return }
    if ($Script:CurrentNavItem -eq $Name) { return }

    # Lazy-initialize the tool panel on first visit
    if (-not $Script:NavContents.ContainsKey($Name)) {
        $fn = $Script:NavInitializers[$Name]
        if (-not $fn) { return }
        Write-Log "Lazy init: $Name" 'DEBUG'
        # Use a staging variable: InvokeScript return-value propagation is unreliable
        # for WPF UIElements, but writing to a $Script: var in the child scope is not.
        $Script:_LazyPanel = $null
        $Script:EtbSessionState.InvokeCommand.InvokeScript(
            "`$Script:_LazyPanel = & $fn", @()
        )
        $panel = $Script:_LazyPanel
        $Script:_LazyPanel = $null
        if (-not ($panel -is [System.Windows.UIElement])) {
            Write-Log "Lazy init '$Name': no panel (got: $(if ($null -ne $panel) { $panel.GetType().Name } else { 'null' }))" 'ERROR'
            return
        }
        $Script:NavContents[$Name] = $panel

        # If a tenant is already connected, trigger the tool's data-load functions
        if ($Script:AccessToken) {
            foreach ($loadFn in $Script:NavConnectFns[$Name]) {
                try { Invoke-EtbCommand $loadFn }
                catch { Write-Log "Lazy-init connect trigger '$loadFn' failed: $_" 'ERROR' }
            }
        }
    }

    $accentBrush = New-SolidBrush 'Accent'
    $selBrush    = New-SolidBrush 'Hover'
    $textBrush   = New-SolidBrush 'Text'
    $dimBrush    = New-SolidBrush 'TextDim'

    foreach ($item in $Script:NavItems) {
        if ($item.Name -eq $Name) {
            $item.Border.Background  = $selBrush
            $item.Border.BorderBrush = $accentBrush
            $item.TitleTb.Foreground = $textBrush
            $Script:MainUI.ToolTitle.Text = $item.Title
            $Script:MainUI.ToolDescription.Text = $item.Subtitle
        } else {
            $item.Border.Background  = [System.Windows.Media.Brushes]::Transparent
            $item.Border.BorderBrush = [System.Windows.Media.Brushes]::Transparent
            $item.TitleTb.Foreground = $dimBrush
        }
    }

    $Script:MainUI.ContentArea.Content = $Script:NavContents[$Name]
    $Script:CurrentNavItem = $Name
    try { Set-AppSetting -Name 'LastTool' -Value $Name }
    catch { Write-Log "Could not save last tool: $_" 'DEBUG' }

    # Quick fade-in so panel switches feel fluid instead of snapping.
    $Script:MainUI.ContentArea.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    if ([System.Windows.SystemParameters]::ClientAreaAnimation) {
        $fade = [System.Windows.Media.Animation.DoubleAnimation]::new(
            0.88, 1.0, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(120)))
        $fade.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
        $Script:MainUI.ContentArea.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    }
}

# ── Main window XAML ───────────────────────────────────────────────────────────
$Script:MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Art's Entra Toolbox" Width="1280" Height="800"
        MinWidth="900" MinHeight="600"
        Background="#12121C" FontFamily="Segoe UI" FontSize="13"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType"
        WindowStartupLocation="CenterScreen">
  <Window.Resources>

    <Style x:Key="{x:Static SystemParameters.FocusVisualStyleKey}" TargetType="Control">
      <Setter Property="Template">
        <Setter.Value><ControlTemplate>
          <Rectangle Margin="2" Stroke="#6366F1" StrokeThickness="2" StrokeDashArray="2,1"/>
        </ControlTemplate></Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="NavButton" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="3,0,0,0"/>
      <Setter Property="Foreground" Value="#7878A0"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="Medium"/>
      <Setter Property="Margin" Value="8,1"/>
      <Setter Property="Padding" Value="12,9"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Template">
        <Setter.Value><ControlTemplate TargetType="Button">
          <Border x:Name="NavSurface" Background="{TemplateBinding Background}"
                  BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                  CornerRadius="5" Padding="{TemplateBinding Padding}">
            <ContentPresenter VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="NavSurface" Property="Background" Value="#2E2E48"/>
            </Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True">
              <Setter TargetName="NavSurface" Property="BorderBrush" Value="#6366F1"/>
            </Trigger>
            <Trigger Property="IsPressed" Value="True">
              <Setter TargetName="NavSurface" Property="Opacity" Value="0.75"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value>
      </Setter>
    </Style>

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

    <Style TargetType="ListBox">
      <Setter Property="Background"      Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding"         Value="0"/>
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
                    Padding="{TemplateBinding Padding}" CornerRadius="5">
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
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="4"/>
      <RowDefinition Height="32"/>
    </Grid.RowDefinitions>

    <!-- ── Header ──────────────────────────────────────────────────────────── -->
    <Border Grid.Row="0" x:Name="MainHeaderBorder" Background="#1C1C2A">
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
      <WrapPanel VerticalAlignment="Center" Margin="16,8">
        <TextBlock Text="Tenant:" Foreground="#7878A0" VerticalAlignment="Center" Margin="0,0,10,0"/>
        <ComboBox x:Name="TenantCombo" Width="240" IsEnabled="False"/>
        <Button x:Name="BtnAddTenant" Content="+" Style="{StaticResource FlatBtn}"
                Background="#6366F1" Padding="10,6" Margin="8,0,0,0"
                FontSize="16" ToolTip="Add a new tenant" Width="34"/>
        <Button x:Name="BtnRemoveTenant" Content="-" Style="{StaticResource FlatBtn}"
                Background="#3C3C5A" Padding="10,6" Margin="4,0,0,0"
                FontSize="16" ToolTip="Remove selected tenant" Width="34" IsEnabled="False"/>
        <Button x:Name="BtnDisconnect" Content="Disconnect" Style="{StaticResource FlatBtn}"
                Background="#EF4444" Padding="10,6" Margin="12,0,0,0"
                ToolTip="Sign out and clear saved credentials for this tenant" IsEnabled="False"/>
        <Button x:Name="BtnDryRun" Content="Dry Run" Style="{StaticResource FlatBtn}"
                Background="#3C3C5A" Padding="10,6" Margin="12,0,0,0"
                ToolTip="Toggle dry mode — actions are logged but not executed"/>
        <Button x:Name="BtnLog" Content="Log" Style="{StaticResource FlatBtn}"
                Background="#3C3C5A" Padding="10,6" Margin="8,0,0,0"
                ToolTip="Show/hide activity log (Ctrl+L)"/>
        <Button x:Name="BtnDemo" Content="Demo" Style="{StaticResource FlatBtn}"
                Background="#7C3AED" Padding="10,6" Margin="12,0,0,0"
                ToolTip="Run in demo mode with fake Contoso Academy data"/>
        <Button x:Name="BtnSearch" Content="Search   Ctrl+K" Style="{StaticResource FlatBtn}"
                Background="#3C3C5A" Padding="10,6" Margin="12,0,0,0"
                ToolTip="Global user search — find a user and jump to any tool (Ctrl+K)"/>
      </WrapPanel>
    </Border>

    <!-- ── Navigation sidebar + content area ──────────────────────────────── -->
    <Grid Grid.Row="2">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="216" MinWidth="190"/>
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
          <TextBlock x:Name="MainUpdate" DockPanel.Dock="Bottom"
                     Foreground="#6366F1" FontSize="11" FontWeight="SemiBold"
                     Margin="17,0,12,0" Cursor="Hand" Visibility="Collapsed"
                     TextWrapping="Wrap"
                     ToolTip="A newer version is available on GitHub — click to open"/>
          <TextBlock x:Name="MainShortcuts" DockPanel.Dock="Bottom"
                     Text="Keyboard shortcuts  (F1)" Foreground="#50507A" FontSize="11"
                     Margin="17,0,12,2" Cursor="Hand"
                     ToolTip="Show the keyboard shortcut guide"/>
          <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel x:Name="NavPanel" Margin="0,8,0,16"/>
          </ScrollViewer>
        </DockPanel>
      </Border>

      <!-- Splitter -->
      <GridSplitter Grid.Column="1" Width="4" HorizontalAlignment="Stretch"
                    Background="#3C3C5A" Cursor="SizeWE" ResizeBehavior="PreviousAndNext"/>

      <!-- Tool content -->
      <Grid Grid.Column="2">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <Border Background="#12121C" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1" Padding="20,14">
          <StackPanel>
            <TextBlock x:Name="ToolTitle" Foreground="#E2E2F0" FontSize="21" FontWeight="SemiBold"/>
            <TextBlock x:Name="ToolDescription" Foreground="#7878A0" FontSize="12" Margin="0,4,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </Border>
        <ContentControl x:Name="MainContentArea" Grid.Row="1" Focusable="False"/>
      </Grid>
    </Grid>

    <!-- ── Log pane (slide-up) ──────────────────────────────────────────────── -->
    <Grid Grid.Row="3" Visibility="Collapsed">
      <Grid.RowDefinitions>
        <RowDefinition Height="4"/>
        <RowDefinition Height="180" MinHeight="60"/>
      </Grid.RowDefinitions>
      <GridSplitter Grid.Row="0" Height="4" HorizontalAlignment="Stretch"
                    Background="#3C3C5A" Cursor="SizeNS" ResizeBehavior="PreviousAndNext"
                    ShowsPreview="True"/>
      <Border Grid.Row="1" Background="#0F1115" BorderBrush="#3C3C5A" BorderThickness="0,1,0,0">
        <Grid Margin="8,4">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <RichTextBox x:Name="AppLogBox" Grid.Column="0" Background="Transparent"
                       Foreground="#7878A0" BorderThickness="0" IsReadOnly="True"
                       FontFamily="Consolas" FontSize="11" Padding="4,2"
                       VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
          <Button x:Name="BtnClearLog" Grid.Column="1" Content="Clear"
                  Style="{StaticResource FlatBtn}" Background="#3C3C5A"
                  Padding="8,4" FontSize="11" Margin="8,0,0,0"
                  VerticalAlignment="Top" ToolTip="Clear log"/>
        </Grid>
      </Border>
    </Grid>

    <!-- ── Status bar ──────────────────────────────────────────────────────── -->
    <Border Grid.Row="5" x:Name="MainStatusBar" Background="#1C1C2A"
            BorderBrush="#3C3C5A" BorderThickness="0,1,0,0">
      <Grid Margin="14,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock x:Name="ModeStatus" Grid.Column="1" Text="NOT CONNECTED" FontFamily="Consolas"
                   Foreground="#7878A0" FontSize="11" VerticalAlignment="Center" Margin="16,0,0,0"/>
        <TextBlock x:Name="MainStatus" TextTrimming="CharacterEllipsis" Text="Ready — select a tenant to begin"
                   Foreground="#50507A" FontSize="11" VerticalAlignment="Center"/>
      </Grid>
    </Border>

    <!-- ── Global user search overlay (Ctrl+K) ─────────────────────────────── -->
    <Grid x:Name="CmdOverlay" Grid.Row="0" Grid.RowSpan="6" Visibility="Collapsed"
          KeyboardNavigation.TabNavigation="Cycle">
      <Border x:Name="CmdBackdrop" Background="#000000" Opacity="0.55"/>
      <Border Width="580" VerticalAlignment="Top" Margin="0,100,0,0"
              Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="1" CornerRadius="10">
        <Border.Effect>
          <DropShadowEffect BlurRadius="24" ShadowDepth="4" Opacity="0.5" Color="Black"/>
        </Border.Effect>
        <StackPanel Margin="14">
          <TextBox x:Name="CmdSearch" Height="38" FontSize="14"
                   Background="#242436" Foreground="#E2E2F0" BorderBrush="#3C3C5A"
                   BorderThickness="1" Padding="10,8" CaretBrush="#E2E2F0"
                   VerticalContentAlignment="Center"/>
          <ListBox x:Name="CmdResults" MaxHeight="280" Margin="0,10,0,0"
                   VirtualizingPanel.IsVirtualizing="True"
                   ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
          <WrapPanel x:Name="CmdActions" Margin="0,12,0,0" Visibility="Collapsed">
            <TextBlock Text="Open in:" Foreground="#7878A0" FontSize="12"
                       VerticalAlignment="Center" Margin="2,0,10,0"/>
            <Button x:Name="CmdActReset"    Content="Password Reset" Style="{StaticResource FlatBtn}"
                    Background="#6366F1" Padding="12,7" Margin="0,0,8,0" FontSize="12"/>
            <Button x:Name="CmdActDevices"  Content="Devices"  Style="{StaticResource FlatBtn}"
                    Background="#3C3C5A" Padding="12,7" Margin="0,0,8,0" FontSize="12"/>
            <Button x:Name="CmdActSignIns"  Content="Sign-Ins" Style="{StaticResource FlatBtn}"
                    Background="#3C3C5A" Padding="12,7" Margin="0,0,8,0" FontSize="12"/>
            <Button x:Name="CmdActLicences" Content="Licences" Style="{StaticResource FlatBtn}"
                    Background="#3C3C5A" Padding="12,7" Margin="0,0,8,0" FontSize="12"/>
            <Button x:Name="CmdActLeaver"   Content="Leaver"   Style="{StaticResource FlatBtn}"
                    Background="#3C3C5A" Padding="12,7" FontSize="12"/>
          </WrapPanel>
          <TextBlock Text="Type a name or UPN  •  ↑↓ select  •  Enter opens Password Reset  •  Esc closes"
                     Foreground="#50507A" FontSize="11" Margin="2,10,0,0"/>
        </StackPanel>
      </Border>
    </Grid>

    <!-- ── Keyboard shortcut guide overlay (F1) ────────────────────────────── -->
    <Grid x:Name="HelpOverlay" Grid.Row="0" Grid.RowSpan="6" Visibility="Collapsed">
      <Grid.Resources>
        <Style x:Key="KeyChip" TargetType="Border">
          <Setter Property="Background"   Value="#242436"/>
          <Setter Property="BorderBrush"  Value="#3C3C5A"/>
          <Setter Property="BorderThickness" Value="1"/>
          <Setter Property="CornerRadius" Value="4"/>
          <Setter Property="Padding"      Value="9,3"/>
          <Setter Property="HorizontalAlignment" Value="Left"/>
          <Setter Property="VerticalAlignment"   Value="Center"/>
          <Setter Property="Margin"       Value="0,4,14,4"/>
        </Style>
        <Style x:Key="KeyText" TargetType="TextBlock">
          <Setter Property="Foreground" Value="#E2E2F0"/>
          <Setter Property="FontFamily" Value="Consolas"/>
          <Setter Property="FontSize"   Value="12"/>
        </Style>
        <Style x:Key="KeyDesc" TargetType="TextBlock">
          <Setter Property="Foreground" Value="#7878A0"/>
          <Setter Property="FontSize"   Value="12"/>
          <Setter Property="TextWrapping" Value="Wrap"/>
          <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>
      </Grid.Resources>
      <Border x:Name="HelpBackdrop" Background="#000000" Opacity="0.55"/>
      <Border Width="430" VerticalAlignment="Center" HorizontalAlignment="Center"
              Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="1" CornerRadius="10">
        <Border.Effect>
          <DropShadowEffect BlurRadius="24" ShadowDepth="4" Opacity="0.5" Color="Black"/>
        </Border.Effect>
        <StackPanel Margin="24,20">
          <TextBlock Text="Keyboard Shortcuts" Foreground="#E2E2F0" FontSize="15"
                     FontWeight="Bold" Margin="0,0,0,12"/>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="110"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
              <RowDefinition/><RowDefinition/><RowDefinition/>
              <RowDefinition/><RowDefinition/><RowDefinition/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Grid.Column="0" Style="{StaticResource KeyChip}"><TextBlock Style="{StaticResource KeyText}" Text="Ctrl + K"/></Border>
            <TextBlock Grid.Row="0" Grid.Column="1" Style="{StaticResource KeyDesc}" Text="Global user search — jump to any tool for a user"/>
            <Border Grid.Row="1" Grid.Column="0" Style="{StaticResource KeyChip}"><TextBlock Style="{StaticResource KeyText}" Text="Ctrl + L"/></Border>
            <TextBlock Grid.Row="1" Grid.Column="1" Style="{StaticResource KeyDesc}" Text="Show / hide the activity log pane"/>
            <Border Grid.Row="2" Grid.Column="0" Style="{StaticResource KeyChip}"><TextBlock Style="{StaticResource KeyText}" Text="F1"/></Border>
            <TextBlock Grid.Row="2" Grid.Column="1" Style="{StaticResource KeyDesc}" Text="This shortcut guide"/>
            <Border Grid.Row="3" Grid.Column="0" Style="{StaticResource KeyChip}"><TextBlock Style="{StaticResource KeyText}" Text="Esc"/></Border>
            <TextBlock Grid.Row="3" Grid.Column="1" Style="{StaticResource KeyDesc}" Text="Close overlays and cancel dialogs"/>
            <Border Grid.Row="4" Grid.Column="0" Style="{StaticResource KeyChip}"><TextBlock Style="{StaticResource KeyText}" Text="Enter"/></Border>
            <TextBlock Grid.Row="4" Grid.Column="1" Style="{StaticResource KeyDesc}" Text="Confirm dialogs; in search, open Password Reset"/>
            <Border Grid.Row="5" Grid.Column="0" Style="{StaticResource KeyChip}"><TextBlock Style="{StaticResource KeyText}" Text="↑  ↓"/></Border>
            <TextBlock Grid.Row="5" Grid.Column="1" Style="{StaticResource KeyDesc}" Text="Move through search results"/>
          </Grid>
          <TextBlock Text="Press Esc or click outside to close" Foreground="#50507A"
                     FontSize="11" Margin="0,14,0,0"/>
        </StackPanel>
      </Border>
    </Grid>

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
      <TextBlock Text="Tenant ID, domain, or admin UPN" Margin="0,0,0,4"/>
      <TextBox x:Name="DlgTenantId" ToolTip="e.g. a tenant GUID, contoso.com, or admin@contoso.com"/>
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
      <Button x:Name="DlgCancel" Grid.Column="0" Content="Cancel" IsCancel="True"
              Style="{StaticResource Btn}" Background="#3C3C5A" Padding="0,8"/>
      <Button x:Name="DlgConnect" Grid.Column="2" Content="Connect" IsDefault="True"
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
    if ($Script:DlgWin -and $Script:DlgWin.IsVisible) { [void]$Script:DlgWin.Activate(); return }
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
            $tid = $Script:DlgTid.Text.Trim()
            Write-Log "DlgConnect: attempting tenant '$tid'" 'INFO'

            if ([string]::IsNullOrWhiteSpace($tid)) {
                $Script:DlgStat.Text       = 'Enter a tenant ID, verified domain, or admin UPN.'
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
                    # Auth resolved domain/UPN input to the tenant GUID — save that,
                    # not the raw input, so the cache and dedupe stay canonical.
                    $entered = $Script:DlgTid.Text.Trim()
                    $dname   = $Script:DlgName.Text.Trim()
                    if (-not $dname -and $entered -ne $Script:CurrentTenantId) {
                        # Domain/UPN input makes a friendlier default label than a GUID.
                        $dname = if ($entered -like '*@*') { ($entered -split '@')[-1] } else { $entered }
                    }
                    Write-Log "DlgConnect: auth succeeded for '$entered' (tenant $($Script:CurrentTenantId))" 'INFO'
                    Save-Tenant -TenantId $Script:CurrentTenantId -DisplayName $dname

                    # We're already authenticated — sync the combo without letting its
                    # SelectionChanged handler start a second, redundant connect.
                    $Script:SuppressTenantSelect = $true
                    try {
                        Update-TenantCombo
                        for ($i = 0; $i -lt $Script:MainUI.TenantCombo.Items.Count; $i++) {
                            if ($Script:MainUI.TenantCombo.Items[$i].Tag.TenantId -eq $Script:CurrentTenantId) {
                                $Script:MainUI.TenantCombo.SelectedIndex = $i
                                break
                            }
                        }
                    } finally {
                        $Script:SuppressTenantSelect = $false
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
            $Script:DlgWin.Tag = $Script:SessionGeneration
        } catch {
            Write-Log "DlgConnect click error: $_" 'ERROR'
        }
    })

    $Script:DlgWin.Add_Closed({
        if ($Script:AuthPS -and $Script:AuthTimer.IsEnabled -and $this.Tag -eq $Script:SessionGeneration) {
            Invoke-ResetTools
            Set-MainStatus 'Sign-in canceled.' 'TextDim'
        }
    })
    $Script:DlgWin.Show()
    $Script:DlgTid.Focus() | Out-Null
}

function Invoke-PostConnect {
    # Resolve the tenant display name off the UI thread — a synchronous Graph call
    # here froze the window for the duration of the request on every connect.
    if ($Script:DemoMode) {
        $Script:MainUI.TenantName.Text        = 'Contoso Academy'
        $Script:MainUI.TenantBadge.Visibility = 'Visible'
        $Script:MainUI.TenantBadge.ToolTip    = 'Demo mode — no real tenant'
    } else {
        $hint = try { Get-TenantAccountHint -TenantId $Script:CurrentTenantId } catch { $null }
        $Script:MainUI.TenantBadge.ToolTip =
            "Tenant: $($Script:CurrentTenantId)$(if ($hint) { "`nSigned in as: $hint" })"
        if ($Script:TenantNameTimer) { $Script:TenantNameTimer.Stop() }
        $Script:TenantNameTimer = Start-AsyncWork -RefSeed @{ Name = '' } -Script {
            $r = Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/organization?$select=displayName' `
                -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
            if ($r.value -and $r.value.Count -gt 0) { $Ref['Name'] = $r.value[0].displayName }
        } -OnComplete {
            param($ref)
            try {
                if (-not $ref['Error'] -and $ref['Name']) {
                    $Script:MainUI.TenantName.Text        = $ref['Name']
                    $Script:MainUI.TenantBadge.Visibility = 'Visible'
                }
            } catch {}
        }
    }

    Update-EtbModeStatus
    $Script:MainUI.BtnDisconnect.IsEnabled = -not $Script:DemoMode
    if (-not $Script:DemoMode -and $Script:CurrentTenantId) {
        try { Set-AppSetting -Name 'LastTenantId' -Value $Script:CurrentTenantId } catch {}
    }
    Invoke-ConnectCallbacks
}

# ── Global user search (Ctrl+K) ────────────────────────────────────────────────
function Show-CmdPalette {
    if (-not $Script:AccessToken) {
        Set-MainStatus 'Connect a tenant to use global user search.' 'TextDim'
        return
    }
    if ($Script:MainUI.CmdOverlay.Visibility -eq 'Visible') { return }
    $Script:CmdPreviousFocus = [System.Windows.Input.Keyboard]::FocusedElement
    $Script:MainUI.CmdOverlay.Visibility = 'Visible'
    $Script:MainUI.CmdSearch.Text        = ''
    $Script:MainUI.CmdResults.Items.Clear()
    $Script:MainUI.CmdActions.Visibility = 'Collapsed'
    if (-not $Script:DemoMode) { Request-EtbUsers -OnReady 'Update-CmdResults' }  # warm the cache
    $Script:MainUI.CmdSearch.Focus() | Out-Null
}

function Hide-CmdPalette {
    $Script:MainUI.CmdOverlay.Visibility = 'Collapsed'
    if ($Script:CmdPreviousFocus) { [void][System.Windows.Input.Keyboard]::Focus($Script:CmdPreviousFocus) }
    $Script:CmdPreviousFocus = $null
}

function Update-CmdResults {
    if ($Script:MainUI.CmdOverlay.Visibility -ne 'Visible') { return }
    $q = $Script:MainUI.CmdSearch.Text.Trim()
    $Script:MainUI.CmdResults.Items.Clear()
    $Script:MainUI.CmdActions.Visibility = 'Collapsed'
    if ([string]::IsNullOrWhiteSpace($q)) { return }
    $users = if ($Script:DemoMode) { $Script:Demo_Users } else { $Script:UserCache.Users }
    if (-not $users) { return }
    $hits = @($users | Where-Object {
        $_.displayName -like "*$q*" -or $_.userPrincipalName -like "*$q*"
    } | Sort-Object { $_.displayName } | Select-Object -First 30)
    foreach ($u in $hits) {
        $lbi         = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Content = "$($u.displayName)   —   $($u.userPrincipalName)"
        $lbi.Tag     = $u
        [void]$Script:MainUI.CmdResults.Items.Add($lbi)
    }
    if ($Script:MainUI.CmdResults.Items.Count -gt 0) {
        $Script:MainUI.CmdResults.SelectedIndex = 0
    }
}

# Jump from the palette into a tool: navigate there and pre-filter its user list
# to the chosen UPN (the tool's own search box does the filtering).
function Open-CmdUserInTool {
    param([string]$Tool)
    $sel = $Script:MainUI.CmdResults.SelectedItem
    if (-not $sel) { return }
    $upn = $sel.Tag.userPrincipalName
    Hide-CmdPalette
    Set-NavSelection -Name $Tool
    $box = switch ($Tool) {
        'UserReset'  { $Script:UPR_UI.UserSearch }
        'LastDevice' { $Script:LD_UI.UserSearch }
        'SignIn'     { $Script:SL_UI.UserSearch }
        'Licence'    { $Script:LA_UI.UserSearch }
        'Leaver'     { $Script:LW_UI.UserSearch }
    }
    if ($box) {
        $box.Text = $upn
        $box.Focus() | Out-Null
        Set-MainStatus "Filtered to $upn." 'TextDim'
    }
}

# ── Keyboard shortcut guide (F1) ────────────────────────────────────────────────
function Show-HelpOverlay {
    $Script:MainUI.HelpOverlay.Visibility = 'Visible'
}

function Hide-HelpOverlay {
    $Script:MainUI.HelpOverlay.Visibility = 'Collapsed'
}

# ── Update checker ──────────────────────────────────────────────────────────────
# Compares version.txt on GitHub main against the running version; shows a
# clickable label in the sidebar when a newer release exists. Fails silently.
$Script:UpdateCheckTimer = $null
function Start-UpdateCheck {
    if ($Script:UpdateCheckTimer) { return }
    $Script:UpdateCheckTimer = Start-AsyncWork -NoToken -SessionIndependent -RefSeed @{ Remote = '' } -Script {
        try {
            $Ref['Remote'] = ([string](Invoke-RestMethod `
                -Uri 'https://raw.githubusercontent.com/ydap1/EntraToolbox/main/version.txt' `
                -TimeoutSec 10 -ErrorAction Stop)).Trim()
        } catch { }
    } -OnComplete {
        param($ref)
        try {
            $remote = $ref['Remote']
            if (-not $remote -or -not $Global:AppVersion) { return }
            $rv = $null; $lv = $null
            if (-not [version]::TryParse($remote, [ref]$rv)) { return }
            if (-not [version]::TryParse($Global:AppVersion, [ref]$lv)) { return }
            if ($rv -gt $lv) {
                $Script:MainUI.UpdateLabel.Text       = "Update available: v$remote"
                $Script:MainUI.UpdateLabel.Visibility = 'Visible'
                Write-Log "Update check: v$remote available on GitHub (running v$Global:AppVersion)" 'INFO'
            } else {
                Write-Log "Update check: up to date (local v$Global:AppVersion, remote v$remote)" 'DEBUG'
            }
        } catch {}
    }
}

function Invoke-LogPaneToggle {
    if ($Script:MainUI.LogPaneGrid.Visibility -eq 'Visible') {
        $Script:MainUI.LogPaneGrid.Visibility = 'Collapsed'
        $Script:MainUI.BtnLog.Background = New-SolidBrush 'Border'
    } else {
        $Script:MainUI.LogPaneGrid.Visibility = 'Visible'
        $Script:MainUI.BtnLog.Background = New-SolidBrush 'Accent'
    }
}

function Invoke-ResetTools {
    Reset-EtbSessionWork
    Clear-EtbUserCache
    foreach ($cb in $Script:ResetCallbacks) {
        try { & $cb } catch { Write-Log "Tool reset failed: $_" 'ERROR' }
    }
    $Script:MainUI.TenantBadge.Visibility  = 'Collapsed'
    $Script:MainUI.TenantName.Text         = ''
    $Script:AccessToken                    = $null
    $Script:MainUI.BtnDisconnect.IsEnabled = $false
    $Script:MainUI.BtnAddTenant.IsEnabled = $true
    $Script:MainUI.TenantCombo.IsEnabled = $Script:MainUI.TenantCombo.Items.Count -gt 0
    $Script:MainUI.BtnRemove.IsEnabled = $Script:MainUI.TenantCombo.Items.Count -gt 0
    Update-EtbModeStatus
}

# ── Show-MainWindow ────────────────────────────────────────────────────────────
function Show-MainWindow {
    param([string]$AppVersion = '', [switch]$InitializeOnly)

    Write-Log 'MainWindow: loading WPF assemblies' 'DEBUG'
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    Write-Log 'MainWindow: parsing XAML' 'DEBUG'
    $reader = New-Object System.Xml.XmlNodeReader ([xml](Invoke-ThemeXaml $Script:MainXaml))
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $Script:MainUI = @{
        Window          = $window
        ToolTitle       = $window.FindName('ToolTitle')
        ToolDescription = $window.FindName('ToolDescription')
        ModeStatus      = $window.FindName('ModeStatus')
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
        BtnDryRun       = $window.FindName('BtnDryRun')
        BtnLog          = $window.FindName('BtnLog')
        BtnClearLog     = $window.FindName('BtnClearLog')
        LogPane         = $window.FindName('AppLogBox')
        LogPaneGrid     = $window.FindName('AppLogBox').Parent.Parent.Parent  # Grid containing the log pane
        HeaderBorder    = $window.FindName('MainHeaderBorder')
        TenantBarBorder = $window.FindName('MainTenantBar')
        StatusBarBorder = $window.FindName('MainStatusBar')
        UpdateLabel     = $window.FindName('MainUpdate')
        CmdOverlay      = $window.FindName('CmdOverlay')
        CmdBackdrop     = $window.FindName('CmdBackdrop')
        CmdSearch       = $window.FindName('CmdSearch')
        CmdResults      = $window.FindName('CmdResults')
        CmdActions      = $window.FindName('CmdActions')
        CmdActReset     = $window.FindName('CmdActReset')
        CmdActDevices   = $window.FindName('CmdActDevices')
        CmdActSignIns   = $window.FindName('CmdActSignIns')
        CmdActLicences  = $window.FindName('CmdActLicences')
        CmdActLeaver    = $window.FindName('CmdActLeaver')
        BtnSearch       = $window.FindName('BtnSearch')
        HelpOverlay     = $window.FindName('HelpOverlay')
        HelpBackdrop    = $window.FindName('HelpBackdrop')
        ShortcutsLabel  = $window.FindName('MainShortcuts')
    }

    $Script:AppLogBox = $Script:MainUI.LogPane
    # LogPaneGrid is the parent Grid of the RichTextBox (LogPane → Grid → Grid → Grid)
    # Walk up: LogPane.Parent = Grid (inner), .Parent = Border, .Parent = Grid (outer)
    $Script:MainUI.LogPaneGrid = $Script:MainUI.LogPane.Parent.Parent.Parent

    if ($AppVersion) {
        $Script:MainUI.Version.Text = "v$AppVersion"
        $window.Title = "Art's Entra Toolbox — v$AppVersion"
    }

    # ── Register lazy-init maps (panels built on first nav click) ────────────
    $Script:NavInitializers = @{
        'YearGroup'   = 'Initialize-PasswordResetTool'
        'UserReset'   = 'Initialize-UserPasswordResetTool'
        'Leaver'      = 'Initialize-LeaverWorkflowTool'
        'Licence'     = 'Initialize-LicenceAssignmentTool'
        'BulkUpn'     = 'Initialize-BulkUpnChangeTool'
        'ImmutableId' = 'Initialize-ImmutableIdTool'
        'LastDevice'  = 'Initialize-LastDeviceTool'
        'DevComp'     = 'Initialize-DeviceComplianceTool'
        'SignIn'      = 'Initialize-SignInLogsTool'
        'GroupCopy'   = 'Initialize-GroupCopyTool'
        'Teams'       = 'Initialize-TeamsProvisioningTool'
        'Changelog'   = 'Initialize-UpdateHistoryTool'
        'Appearance'  = 'Initialize-AppearanceTool'
        'SecureScore' = 'Initialize-SecureScoreTool'
    }
    $Script:NavConnectFns = @{
        'YearGroup'   = @('Start-PwUserLoad')
        'UserReset'   = @('Start-UprUserLoad')
        'Leaver'      = @('Start-LwUserLoad')
        'Licence'     = @('Start-LaUserLoad', 'Start-LaSkuLoad')
        'BulkUpn'     = @('Start-BucLoad')
        'ImmutableId' = @('Invoke-IidOnConnect')
        'LastDevice'  = @('Start-LdUserLoad', 'Start-LdAllDevicesLoad')
        'DevComp'     = @('Start-DcLoad')
        'SignIn'      = @('Start-SlUserLoad')
        'GroupCopy'   = @('Start-GcUserLoad')
        'Teams'       = @('Start-TpUserLoad')
        'Changelog'   = @()
        'Appearance'  = @()
        'SecureScore' = @('Start-SsLoad')
    }
    Write-Log 'MainWindow: lazy-init maps registered' 'DEBUG'

    # ── Build nav sidebar ─────────────────────────────────────────────────────
    $navDef = @(
        @{ Type = 'cat';  Label = 'USERS' }
        @{ Type = 'tool'; Name = 'YearGroup';   Title = 'Year Group Passwords'; Desc = 'Reset passwords for an entire year group' }
        @{ Type = 'tool'; Name = 'UserReset';   Title = 'User Password Reset';  Desc = 'Reset a single account password' }
        @{ Type = 'tool'; Name = 'Leaver';      Title = 'Leaver Workflow';      Desc = 'Disable, revoke sessions, remove from groups' }
        @{ Type = 'tool'; Name = 'Licence';     Title = 'Licence Assignment';   Desc = 'View and assign Microsoft 365 licences' }
        @{ Type = 'tool'; Name = 'BulkUpn';     Title = 'Bulk UPN Change';      Desc = 'Move users to a different verified domain' }
        @{ Type = 'tool'; Name = 'ImmutableId'; Title = 'Immutable ID';         Desc = 'Assign immutable ID to user' }
        @{ Type = 'cat';  Label = 'DEVICES' }
        @{ Type = 'tool'; Name = 'LastDevice';  Title = 'Last Device';          Desc = 'Login history and stale device detection' }
        @{ Type = 'tool'; Name = 'DevComp';     Title = 'Device Compliance';    Desc = 'Compliance overview with failure reasons' }
        @{ Type = 'cat';  Label = 'AUDIT' }
        @{ Type = 'tool'; Name = 'SignIn';       Title = 'Sign-In Logs';        Desc = 'Browse Entra ID sign-in events' }
        @{ Type = 'cat';  Label = 'GROUPS & TEAMS' }
        @{ Type = 'tool'; Name = 'GroupCopy';   Title = 'Group Copy';           Desc = 'Copy memberships from one user to another' }
        @{ Type = 'tool'; Name = 'Teams';        Title = 'Teams Provisioning';  Desc = 'Create and populate Microsoft Teams' }
        @{ Type = 'cat';  Label = 'SECURITY' }
        @{ Type = 'tool'; Name = 'SecureScore'; Title = 'Secure Score';         Desc = 'Microsoft Secure Score with control breakdown' }
        @{ Type = 'cat';  Label = 'APP' }
        @{ Type = 'tool'; Name = 'Appearance';  Title = 'Appearance';           Desc = 'Theme and font settings' }
        @{ Type = 'tool'; Name = 'Changelog';   Title = 'Update History';       Desc = 'Version changelog and release notes' }
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

    # Reopen on the tool last used, so relaunching lands where work stopped.
    $startTool = Get-AppSetting -Name 'LastTool'
    if (-not $startTool -or -not $Script:NavInitializers.ContainsKey([string]$startTool)) {
        $startTool = 'YearGroup'
    }
    Set-NavSelection -Name ([string]$startTool)

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

    # ── Dry Run toggle ───────────────────────────────────────────────────────
    $Script:MainUI.BtnDryRun.Add_Click({
        try {
            $Script:DryMode = -not $Script:DryMode
            if ($Script:DryMode) {
                $Script:MainUI.BtnDryRun.Background = New-SolidBrush 'Warning'
                $Script:MainUI.BtnDryRun.Content     = 'Dry Run ON'
                $Script:MainUI.HeaderBorder.Background = New-SolidBrush 'DangerBg'
                Write-AppLog 'Dry run enabled for new actions. Already submitted changes cannot be undone.' 'Warning'
                Set-MainStatus 'Dry run active for new actions.' 'Warning'
            } else {
                $Script:MainUI.BtnDryRun.Background = New-SolidBrush 'Border'
                $Script:MainUI.BtnDryRun.Content     = 'Dry Run'
                $Script:MainUI.HeaderBorder.Background = New-SolidBrush 'Surface'
                Write-AppLog 'Dry mode DISABLED — actions will execute normally.' 'Success'
                Set-MainStatus 'Ready.' 'TextDim'
            }
            Update-EtbModeStatus
        } catch {
            Write-Log "BtnDryRun click error: $_" 'ERROR'
        }
    })

    # ── Log pane toggle (button + Ctrl+L) ────────────────────────────────────
    $Script:MainUI.BtnLog.Add_Click({
        try { Invoke-LogPaneToggle }
        catch { Write-Log "BtnLog click error: $_" 'ERROR' }
    })
    $window.Add_PreviewKeyDown({
        param($s, $e)
        try {
            $ctrl = [System.Windows.Input.Keyboard]::Modifiers -eq [System.Windows.Input.ModifierKeys]::Control
            if ($e.Key -eq 'L' -and $ctrl) { Invoke-LogPaneToggle; $e.Handled = $true; return }
            if ($e.Key -eq 'K' -and $ctrl) { Show-CmdPalette;      $e.Handled = $true; return }
            if ($e.Key -eq 'F1') {
                if ($Script:MainUI.HelpOverlay.Visibility -eq 'Visible') { Hide-HelpOverlay }
                else { Show-HelpOverlay }
                $e.Handled = $true
                return
            }
            if ($e.Key -eq 'Escape') {
                if ($Script:MainUI.HelpOverlay.Visibility -eq 'Visible') {
                    Hide-HelpOverlay
                    $e.Handled = $true
                } elseif ($Script:MainUI.CmdOverlay.Visibility -eq 'Visible') {
                    Hide-CmdPalette
                    $e.Handled = $true
                }
            }
        } catch {}
    })

    # ── Global user search wiring ────────────────────────────────────────────
    $Script:MainUI.CmdBackdrop.Add_MouseLeftButtonDown({
        try { Hide-CmdPalette } catch {}
    })
    $Script:MainUI.CmdSearch.Add_TextChanged({
        try { Invoke-EtbDebounced -Key 'CmdPalette' -Command 'Update-CmdResults' -Ms 150 }
        catch { Write-Log "CmdSearch TextChanged error: $_" 'ERROR' }
    })
    $Script:MainUI.CmdSearch.Add_PreviewKeyDown({
        param($s, $e)
        try {
            $r = $Script:MainUI.CmdResults
            if ($e.Key -eq 'Down' -and $r.Items.Count -gt 0) {
                $r.SelectedIndex = [Math]::Min($r.SelectedIndex + 1, $r.Items.Count - 1)
                $r.ScrollIntoView($r.SelectedItem)
                $e.Handled = $true
            } elseif ($e.Key -eq 'Up' -and $r.Items.Count -gt 0) {
                $r.SelectedIndex = [Math]::Max($r.SelectedIndex - 1, 0)
                $r.ScrollIntoView($r.SelectedItem)
                $e.Handled = $true
            } elseif ($e.Key -eq 'Return') {
                Open-CmdUserInTool 'UserReset'
                $e.Handled = $true
            }
        } catch {}
    })
    $Script:MainUI.CmdResults.Add_SelectionChanged({
        try {
            $Script:MainUI.CmdActions.Visibility =
                if ($Script:MainUI.CmdResults.SelectedItem) { 'Visible' } else { 'Collapsed' }
        } catch {}
    })
    $Script:MainUI.CmdResults.Add_MouseDoubleClick({
        try { Open-CmdUserInTool 'UserReset' } catch {}
    })
    $Script:MainUI.CmdActReset.Add_Click({    try { Open-CmdUserInTool 'UserReset' }  catch { Write-Log "CmdActReset error: $_" 'ERROR' } })
    $Script:MainUI.CmdActDevices.Add_Click({  try { Open-CmdUserInTool 'LastDevice' } catch { Write-Log "CmdActDevices error: $_" 'ERROR' } })
    $Script:MainUI.CmdActSignIns.Add_Click({  try { Open-CmdUserInTool 'SignIn' }     catch { Write-Log "CmdActSignIns error: $_" 'ERROR' } })
    $Script:MainUI.CmdActLicences.Add_Click({ try { Open-CmdUserInTool 'Licence' }    catch { Write-Log "CmdActLicences error: $_" 'ERROR' } })
    $Script:MainUI.CmdActLeaver.Add_Click({   try { Open-CmdUserInTool 'Leaver' }     catch { Write-Log "CmdActLeaver error: $_" 'ERROR' } })

    # ── Update-available label ───────────────────────────────────────────────
    $Script:MainUI.UpdateLabel.Add_MouseLeftButtonDown({
        try { Start-Process 'https://github.com/ydap1/EntraToolbox' }
        catch { Write-Log "UpdateLabel click error: $_" 'ERROR' }
    })

    # ── Search button + shortcut guide ───────────────────────────────────────
    $Script:MainUI.BtnSearch.Add_Click({
        try { Show-CmdPalette }
        catch { Write-Log "BtnSearch click error: $_" 'ERROR' }
    })
    $Script:MainUI.ShortcutsLabel.Add_MouseLeftButtonDown({
        try { Show-HelpOverlay }
        catch { Write-Log "ShortcutsLabel click error: $_" 'ERROR' }
    })
    $Script:MainUI.HelpBackdrop.Add_MouseLeftButtonDown({
        try { Hide-HelpOverlay } catch {}
    })

    # ── Clear log ─────────────────────────────────────────────────────────────
    $Script:MainUI.BtnClearLog.Add_Click({
        try {
            $Script:MainUI.LogPane.Document.Blocks.Clear()
        } catch {
            Write-Log "BtnClearLog click error: $_" 'ERROR'
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
            if ($Script:SuppressTenantSelect) { return }
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
            Start-UpdateCheck
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

    $window.Add_Closed({
        Reset-EtbSessionWork
        foreach ($job in $Script:AsyncJobs.ToArray()) { Stop-EtbAsyncWork $job }
        if ($Script:TokenRefreshTimer) { $Script:TokenRefreshTimer.Stop() }
    })
    if ($InitializeOnly) { return $window }
    [void]$window.ShowDialog()
    # The dispatcher no longer runs after close; finish releasing canceled workers.
    foreach ($job in $Script:AsyncJobs.ToArray()) {
        if ($job.Tag.StopAsync) { $job.Tag.StopAsync.AsyncWaitHandle.WaitOne() | Out-Null }
        Complete-EtbAsyncWork $job
    }
}
