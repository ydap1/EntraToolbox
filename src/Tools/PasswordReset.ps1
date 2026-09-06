<#
    Year Group Password Reset tab for Art's Entra Toolbox.
    Dot-sourced by Start.ps1.
    Exposes Initialize-PasswordResetTool.
#>

# ── Word lists (three letters each) ────────────────────────────────────────────
$Script:PwWords1 = 'cat','dog','bat','cow','fox','owl','pig','ram','hen','ant',
                   'bee','elk','ape','eel','jay','koi','yak','doe','cub','pup',
                   'kid','emu','gnu','boa','hog','sow'
$Script:PwWords2 = 'sun','sky','sea','ice','oak','elm','fig','bud','log','mud',
                   'dew','fog','ray','bay','sap','ash','ivy','pod','nut','gem',
                   'ore','tor','fen','bog','hay','wax'
$Script:PwWords3 = 'cup','jar','pen','bag','box','map','key','pad','hat','cap',
                   'mug','bin','net','rug','tin','pot','pan','rod','saw','bow',
                   'oar','jug','van','bus','cab','tag'

function New-Password {
    $a = $Script:PwWords1[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($Script:PwWords1.Count)]
    $b = $Script:PwWords2[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($Script:PwWords2.Count)]
    $c = $Script:PwWords3[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($Script:PwWords3.Count)]
    $n = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32(10, 100)
    "$a.$b.$c$n!"
}

function Get-DeptGroup([string]$d) {
    if ($d -match '^(\d+)')       { return [int]$Matches[1] }
    if ($d -match '^([A-Za-z]+)') { return $Matches[1] }
    return $null
}

# ── Script-level state ─────────────────────────────────────────────────────────
$Script:PwReset_UI         = $null
$Script:PwReset_Rows       = New-Object System.Collections.ObjectModel.ObservableCollection[PSObject]
$Script:PwReset_GraphUsers = @()
$Script:PwReset_Running    = $false

# ── Selection label helper ─────────────────────────────────────────────────────
function Update-PwSelectionLabel {
    $sel   = $Script:PwReset_UI.Grid.SelectedItems.Count
    $total = $Script:PwReset_Rows.Count
    if ($total -gt 0) {
        $Script:PwReset_UI.LblSelection.Text = "$sel of $total selected"
    } else {
        $Script:PwReset_UI.LblSelection.Text = ''
    }
    if (-not $Script:PwReset_Running) {
        $Script:PwReset_UI.BtnRun.IsEnabled = ($sel -gt 0)
    }
}

# ── Log helper ─────────────────────────────────────────────────────────────────
function Write-PwLog {
    param([string]$Msg, [string]$Color = 'TextDim')
    Write-AppLog $Msg $Color
}

# ── Async user load ────────────────────────────────────────────────────────────
$Script:PwResetTimer = $null

function Start-PwUserLoad {
    if ($Script:DemoMode) { Start-PwUserLoadDemo; return }
    $Script:PwReset_UI.CboYear.Items.Clear()
    $Script:PwReset_UI.CboYear.IsEnabled   = $false
    $Script:PwReset_UI.BtnLoad.IsEnabled   = $false
    $Script:PwReset_UI.BtnRun.IsEnabled    = $false
    $Script:PwReset_UI.BtnExport.IsEnabled = $false
    Set-MainStatus 'Loading users...' 'TextDim'
    Write-PwLog 'Fetching users from Entra ID...' 'TextDim'

    Request-EtbUsers -OnReady 'Complete-PwUserLoad'
}

function Complete-PwUserLoad {
    try {
            if ($Script:UserCache.Error) {
                Write-Log "PwReset: user load failed - $($Script:UserCache.Error)" 'ERROR'
                Write-PwLog "Failed to load users: $($Script:UserCache.Error)" 'Danger'
                Set-MainStatus 'Failed to load users.' 'Danger'
                return
            }

            $Script:PwReset_GraphUsers = @($Script:UserCache.Users |
                Where-Object { $_.accountEnabled -eq $true -and $_.department })
            Write-Log "PwReset: loaded $($Script:PwReset_GraphUsers.Count) users" 'INFO'
            Write-PwLog "Loaded $($Script:PwReset_GraphUsers.Count) enabled users with departments." 'Success'

            # Single-pass group count (replaces O(n²) Where-Object per group)
            $groupCounts = @{}
            foreach ($u in $Script:PwReset_GraphUsers) {
                $g = Get-DeptGroup $u.department
                if ($null -ne $g) { $groupCounts[$g] = ($groupCounts[$g] ?? 0) + 1 }
            }
            $numericGroups = @($groupCounts.Keys | Where-Object { $_ -is [int] }    | Sort-Object)
            $namedGroups   = @($groupCounts.Keys | Where-Object { $_ -is [string] } | Sort-Object)

            $Script:PwReset_UI.CboYear.Items.Clear()
            foreach ($g in ($numericGroups + $namedGroups)) {
                $cnt   = $groupCounts[$g]
                $label = if ($g -is [int]) { "Year $g  -  $cnt students" } else { "$g  -  $cnt students" }
                $item  = New-Object System.Windows.Controls.ComboBoxItem
                $item.Content = $label
                $item.Tag     = $g
                $Script:PwReset_UI.CboYear.Items.Add($item) | Out-Null
            }
            if ($Script:PwReset_UI.CboYear.Items.Count -gt 0) { $Script:PwReset_UI.CboYear.SelectedIndex = 0 }
            $Script:PwReset_UI.CboYear.IsEnabled = $true
            $Script:PwReset_UI.BtnLoad.IsEnabled = $true
            Set-MainStatus "Ready - $($Script:PwReset_GraphUsers.Count) users loaded." 'Success'
    } catch {
        Write-Log "PwReset user-load error: $_" 'ERROR'
    }
}

# ── XAML ───────────────────────────────────────────────────────────────────────
$Script:PwResetXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
      Background="#12121C">
  <Grid.Resources>

    <SolidColorBrush x:Key="Bg"       Color="#12121C"/>
    <SolidColorBrush x:Key="Surface"  Color="#1C1C2A"/>
    <SolidColorBrush x:Key="Card"     Color="#242436"/>
    <SolidColorBrush x:Key="Border"   Color="#3C3C5A"/>
    <SolidColorBrush x:Key="Accent"   Color="#6366F1"/>
    <SolidColorBrush x:Key="Danger"   Color="#EF4444"/>
    <SolidColorBrush x:Key="Success"  Color="#22C55E"/>
    <SolidColorBrush x:Key="Text"     Color="#E2E2F0"/>
    <SolidColorBrush x:Key="TextDim"  Color="#7878A0"/>
    <SolidColorBrush x:Key="Muted"    Color="#50507A"/>

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

    <Style x:Key="SectionLbl" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#50507A"/>
      <Setter Property="FontSize"   Value="10"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Margin"     Value="0,0,0,6"/>
    </Style>

    <Style TargetType="ComboBox">
      <Setter Property="Background"    Value="#242436"/>
      <Setter Property="Foreground"    Value="#E2E2F0"/>
      <Setter Property="BorderBrush"   Value="#3C3C5A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Height"        Value="32"/>
      <Setter Property="Padding"       Value="8,0"/>
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
                     IsOpen="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}}"
                     Placement="Bottom" PopupAnimation="Slide">
                <Border Background="#242436" BorderBrush="#3C3C5A" BorderThickness="1"
                        CornerRadius="0,0,4,4"
                        MaxHeight="{TemplateBinding MaxDropDownHeight}">
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

    <Style TargetType="RadioButton">
      <Setter Property="Foreground"  Value="#E2E2F0"/>
      <Setter Property="Background"  Value="Transparent"/>
      <Setter Property="Cursor"      Value="Hand"/>
      <Setter Property="Margin"      Value="0,4,0,0"/>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E2E2F0"/>
      <Setter Property="Cursor"     Value="Hand"/>
    </Style>

    <Style TargetType="DataGrid">
      <Setter Property="Background"              Value="#12121C"/>
      <Setter Property="Foreground"              Value="#E2E2F0"/>
      <Setter Property="BorderThickness"         Value="0"/>
      <Setter Property="GridLinesVisibility"     Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#1E1E32"/>
      <Setter Property="RowBackground"           Value="#12121C"/>
      <Setter Property="AlternatingRowBackground" Value="#181826"/>
      <Setter Property="ColumnHeaderHeight"      Value="34"/>
      <Setter Property="RowHeight"               Value="28"/>
      <Setter Property="AutoGenerateColumns"     Value="False"/>
      <Setter Property="CanUserAddRows"          Value="False"/>
      <Setter Property="CanUserDeleteRows"       Value="False"/>
      <Setter Property="IsReadOnly"              Value="True"/>
      <Setter Property="SelectionMode"           Value="Extended"/>
      <Setter Property="SelectionUnit"           Value="FullRow"/>
      <Setter Property="CanUserSortColumns"      Value="True"/>
      <Setter Property="FontSize"                Value="12"/>
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
            <Border x:Name="bd" Padding="{TemplateBinding Padding}" Cursor="Hand">
              <Border x:Name="ind" BorderThickness="0,0,0,2" BorderBrush="Transparent" Padding="0,0,0,3">
                <ContentPresenter ContentSource="Header"/>
              </Border>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected"  Value="True">
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

  <!-- ── Sidebar ──────────────────────────────────────────────────── -->
  <Border Grid.Column="0" Background="#1C1C2A">
    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <StackPanel Margin="16,20,16,16">

        <TextBlock Text="YEAR GROUP" Style="{StaticResource SectionLbl}"/>
        <ComboBox x:Name="PwCboYear" IsEnabled="False"/>
        <Button x:Name="PwBtnLoad" Content="Load Students" IsEnabled="False"
                Style="{StaticResource PrimaryBtn}" Background="#242436"
                Foreground="#7878A0" Padding="0,10" Margin="0,8,0,0"/>

        <!-- Selection controls -->
        <Grid Margin="0,6,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="4"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="4"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="PwLblSelection" Grid.Column="0"
                     Foreground="#50507A" FontSize="11" VerticalAlignment="Center"/>
          <Button x:Name="PwBtnSelectAll" Grid.Column="2" Content="All"
                  Style="{StaticResource PrimaryBtn}" Background="#242436"
                  Foreground="#7878A0" Padding="8,4" FontSize="11" IsEnabled="False"/>
          <Button x:Name="PwBtnSelectNone" Grid.Column="4" Content="None"
                  Style="{StaticResource PrimaryBtn}" Background="#242436"
                  Foreground="#7878A0" Padding="8,4" FontSize="11" IsEnabled="False"/>
        </Grid>

        <Border Background="#3C3C5A" Height="1" Margin="0,14"/>

        <TextBlock Text="RUN MODE" Style="{StaticResource SectionLbl}"/>
        <RadioButton x:Name="PwRbDry"  Content="Dry Run  (preview only)"  IsChecked="True" GroupName="pwmode"/>
        <RadioButton x:Name="PwRbLive" Content="Live Run  (reset passwords)"
                     Foreground="#EF4444" GroupName="pwmode"/>

        <Border x:Name="PwPnlWarn" CornerRadius="6" Background="#1A1A2C"
                BorderBrush="#EF4444" BorderThickness="1"
                Padding="10,8" Margin="0,8,0,0" Visibility="Collapsed">
          <StackPanel>
            <TextBlock Text="Warning" Foreground="#EF4444" FontWeight="Bold" FontSize="12"/>
            <TextBlock Text="Passwords will be changed in Entra ID immediately."
                       Foreground="#CC6666" FontSize="11" TextWrapping="Wrap" Margin="0,4,0,0"/>
          </StackPanel>
        </Border>

        <Border Background="#3C3C5A" Height="1" Margin="0,14"/>

        <TextBlock Text="SIGN-IN PROMPT AFTER RESET" Style="{StaticResource SectionLbl}"/>
        <CheckBox x:Name="PwChkForce" Margin="0,4,0,0"
                  Content="Force password change on next sign-in"/>
        <TextBlock Text="When checked, each student must set a new password on their next login."
                   Foreground="#50507A" FontSize="11" TextWrapping="Wrap" Margin="0,6,0,0"/>

        <Border Background="#3C3C5A" Height="1" Margin="0,14"/>

        <TextBlock Text="ACTIONS" Style="{StaticResource SectionLbl}"/>
        <Button x:Name="PwBtnRun" Content="Generate Passwords" IsEnabled="False"
                Style="{StaticResource PrimaryBtn}" Background="#6366F1" Padding="0,10"/>
        <Button x:Name="PwBtnExport" Content="Export CSV" IsEnabled="False"
                Style="{StaticResource PrimaryBtn}" Background="#242436"
                Foreground="#7878A0" Padding="0,10" Margin="0,8,0,0"/>

        <Border x:Name="PwPnlStats" CornerRadius="6" Background="#242436"
                Padding="14,12" Margin="0,14,0,0" Visibility="Collapsed">
          <StackPanel>
            <TextBlock x:Name="PwLblTotal"  Text="Total  -" Foreground="#7878A0"
                       FontFamily="Consolas" FontSize="12"/>
            <TextBlock x:Name="PwLblOK"     Text="OK     -" Foreground="#22C55E"
                       FontFamily="Consolas" FontSize="12" Margin="0,4,0,0"/>
            <TextBlock x:Name="PwLblFailed" Text="Failed -" Foreground="#7878A0"
                       FontFamily="Consolas" FontSize="12" Margin="0,4,0,0"/>
          </StackPanel>
        </Border>

      </StackPanel>
    </ScrollViewer>
  </Border>

  <!-- ── Right: tabs ──────────────────────────────────────────────── -->
  <TabControl Grid.Column="2">
    <TabControl.Template>
      <ControlTemplate TargetType="TabControl">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Border Grid.Row="0" Background="#1C1C2A" BorderBrush="#3C3C5A"
                  BorderThickness="0,0,0,1">
            <TabPanel IsItemsHost="True" Margin="8,0"/>
          </Border>
          <ContentPresenter Grid.Row="1" ContentSource="SelectedContent"/>
        </Grid>
      </ControlTemplate>
    </TabControl.Template>

    <!-- Passwords tab -->
    <TabItem Header="Passwords">
      <Grid Background="#12121C">
        <Grid.RowDefinitions>
          <RowDefinition Height="*"/>
          <RowDefinition Height="3"/>
        </Grid.RowDefinitions>
        <DataGrid x:Name="PwGrid" Grid.Row="0"
                  VirtualizingPanel.IsVirtualizing="True"
                  VirtualizingPanel.VirtualizationMode="Recycling">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Display Name"    Binding="{Binding DisplayName}" Width="*"    SortMemberPath="DisplayName"/>
            <DataGridTextColumn Header="Username (UPN)"  Binding="{Binding UPN}"         Width="1.4*" SortMemberPath="UPN"/>
            <DataGridTextColumn Header="Form"            Binding="{Binding Department}"  Width="70"   SortMemberPath="Department"/>
            <DataGridTemplateColumn Header="Generated Password" Width="*" SortMemberPath="Password">
              <DataGridTemplateColumn.CellTemplate>
                <DataTemplate>
                  <TextBlock Text="{Binding Password}" FontFamily="Consolas" FontSize="12"
                             Foreground="#22C55E" VerticalAlignment="Center" Padding="12,0"/>
                </DataTemplate>
              </DataGridTemplateColumn.CellTemplate>
            </DataGridTemplateColumn>
            <DataGridTemplateColumn Header="Status" Width="90" SortMemberPath="Status">
              <DataGridTemplateColumn.CellTemplate>
                <DataTemplate>
                  <Border CornerRadius="4" Padding="6,2" HorizontalAlignment="Left"
                          VerticalAlignment="Center" Margin="12,0">
                    <Border.Style>
                      <Style TargetType="Border">
                        <Style.Triggers>
                          <DataTrigger Binding="{Binding Status}" Value="OK">
                            <Setter Property="Background" Value="#0D2B1A"/>
                          </DataTrigger>
                          <DataTrigger Binding="{Binding Status}" Value="Failed">
                            <Setter Property="Background" Value="#2B0D0D"/>
                          </DataTrigger>
                          <DataTrigger Binding="{Binding Status}" Value="Pending">
                            <Setter Property="Background" Value="#242436"/>
                          </DataTrigger>
                        </Style.Triggers>
                      </Style>
                    </Border.Style>
                    <TextBlock Text="{Binding Status}" FontSize="11" FontWeight="SemiBold">
                      <TextBlock.Style>
                        <Style TargetType="TextBlock">
                          <Style.Triggers>
                            <DataTrigger Binding="{Binding Status}" Value="OK">
                              <Setter Property="Foreground" Value="#22C55E"/>
                            </DataTrigger>
                            <DataTrigger Binding="{Binding Status}" Value="Failed">
                              <Setter Property="Foreground" Value="#EF4444"/>
                            </DataTrigger>
                            <DataTrigger Binding="{Binding Status}" Value="Pending">
                              <Setter Property="Foreground" Value="#50507A"/>
                            </DataTrigger>
                          </Style.Triggers>
                        </Style>
                      </TextBlock.Style>
                    </TextBlock>
                  </Border>
                </DataTemplate>
              </DataGridTemplateColumn.CellTemplate>
            </DataGridTemplateColumn>
          </DataGrid.Columns>
        </DataGrid>
        <ProgressBar x:Name="PwProgress" Grid.Row="1" Height="3"
                     Background="#1C1C2A" Foreground="#6366F1"
                     BorderThickness="0" Visibility="Collapsed" Value="0"/>
      </Grid>
    </TabItem>

    <!-- Log tab removed — use the global Log pane at the bottom of the window -->
  </TabControl>
</Grid>
'@

# ── Initialize ─────────────────────────────────────────────────────────────────
function Initialize-PasswordResetTool {
    $reader  = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new((Invoke-ThemeXaml $Script:PwResetXaml)))
    $content = [System.Windows.Markup.XamlReader]::Load($reader)

    $Script:PwReset_UI = @{
        CboYear        = $content.FindName('PwCboYear')
        BtnLoad        = $content.FindName('PwBtnLoad')
        LblSelection   = $content.FindName('PwLblSelection')
        BtnSelectAll   = $content.FindName('PwBtnSelectAll')
        BtnSelectNone  = $content.FindName('PwBtnSelectNone')
        RbDry          = $content.FindName('PwRbDry')
        RbLive         = $content.FindName('PwRbLive')
        PnlWarn        = $content.FindName('PwPnlWarn')
        ChkForce       = $content.FindName('PwChkForce')
        BtnRun         = $content.FindName('PwBtnRun')
        BtnExport      = $content.FindName('PwBtnExport')
        Grid           = $content.FindName('PwGrid')
        Progress       = $content.FindName('PwProgress')
        # LogBox removed — use Write-AppLog to the global Log pane
        PnlStats       = $content.FindName('PwPnlStats')
        LblTotal       = $content.FindName('PwLblTotal')
        LblOK          = $content.FindName('PwLblOK')
        LblFailed      = $content.FindName('PwLblFailed')
    }

    $Script:PwReset_UI.Grid.ItemsSource = $Script:PwReset_Rows

    # Selection changed -> update label and BtnRun
    $Script:PwReset_UI.Grid.Add_SelectionChanged({
        try { Update-PwSelectionLabel } catch { Write-Log "PwReset SelectionChanged error: $_" 'ERROR' }
    })

    # Select All / None
    $Script:PwReset_UI.BtnSelectAll.Add_Click({
        try {
            $Script:PwReset_UI.Grid.SelectAll()
        } catch { Write-Log "BtnSelectAll click error: $_" 'ERROR' }
    })
    $Script:PwReset_UI.BtnSelectNone.Add_Click({
        try {
            $Script:PwReset_UI.Grid.UnselectAll()
        } catch { Write-Log "BtnSelectNone click error: $_" 'ERROR' }
    })

    # Run-mode toggle
    $Script:PwReset_UI.RbLive.Add_Checked({
        try {
            Write-Log 'PwReset: mode -> Live' 'WARN'
            $Script:PwReset_UI.PnlWarn.Visibility = 'Visible'
            if ($Script:PwReset_UI.BtnRun.IsEnabled) {
                $Script:PwReset_UI.BtnRun.Content    = 'Reset Passwords Now'
                $Script:PwReset_UI.BtnRun.Background = (Get-ThemeHex 'Danger')
            }
        } catch { Write-Log "RbLive Checked error: $_" 'ERROR' }
    })
    $Script:PwReset_UI.RbDry.Add_Checked({
        try {
            Write-Log 'PwReset: mode -> Dry Run' 'DEBUG'
            $Script:PwReset_UI.PnlWarn.Visibility = 'Collapsed'
            if ($Script:PwReset_UI.BtnRun.IsEnabled) {
                $Script:PwReset_UI.BtnRun.Content    = 'Generate Passwords'
                $Script:PwReset_UI.BtnRun.Background = (Get-ThemeHex 'Accent')
            }
        } catch { Write-Log "RbDry Checked error: $_" 'ERROR' }
    })

    # Load Students
    $Script:PwReset_UI.BtnLoad.Add_Click({
        try {
            $selItem = $Script:PwReset_UI.CboYear.SelectedItem
            if (-not $selItem) { return }
            $selGroup = $selItem.Tag
            Write-Log "PwReset: loading students for group $selGroup" 'INFO'

            $Script:PwReset_Rows.Clear()
            $students = @($Script:PwReset_GraphUsers | Where-Object { (Get-DeptGroup $_.department) -eq $selGroup })

            foreach ($u in $students) {
                $Script:PwReset_Rows.Add([PSCustomObject]@{
                    Id          = $u.id
                    DisplayName = $u.displayName
                    UPN         = $u.userPrincipalName
                    Department  = $u.department
                    Password    = ''
                    Status      = 'Pending'
                })
            }

            # Auto-select all loaded rows
            $Script:PwReset_UI.Grid.SelectAll()

            Write-Log "PwReset: $($students.Count) students loaded for group $selGroup" 'INFO'
            $Script:PwReset_UI.BtnSelectAll.IsEnabled  = $true
            $Script:PwReset_UI.BtnSelectNone.IsEnabled = $true
            $Script:PwReset_UI.BtnExport.IsEnabled     = $false
            $Script:PwReset_UI.PnlStats.Visibility     = 'Collapsed'
            if ($Script:PwReset_UI.RbLive.IsChecked) {
                $Script:PwReset_UI.BtnRun.Content    = 'Reset Passwords Now'
                $Script:PwReset_UI.BtnRun.Background = (Get-ThemeHex 'Danger')
            } else {
                $Script:PwReset_UI.BtnRun.Content    = 'Generate Passwords'
                $Script:PwReset_UI.BtnRun.Background = (Get-ThemeHex 'Accent')
            }
            Write-PwLog "Loaded $($students.Count) students for group: $selGroup" 'Text'
            Set-MainStatus "Group $selGroup - $($students.Count) students loaded." 'Text'
        } catch {
            Write-Log "BtnLoad click error: $_" 'ERROR'
        }
    })

    # Generate / Reset
    $Script:PwReset_UI.BtnRun.Add_Click({
        try {
            $selected = @($Script:PwReset_UI.Grid.SelectedItems)
            if ($selected.Count -eq 0) { return }

            $isLive = $Script:PwReset_UI.RbLive.IsChecked -and -not $Script:DryMode
            $force  = [bool]$Script:PwReset_UI.ChkForce.IsChecked
            $mode   = if ($isLive) { 'Live' } elseif ($Script:DryMode) { 'Dry (global)' } else { 'Dry' }
            Write-Log "PwReset: starting $mode run for $($selected.Count) selected rows (forceChange=$force)" 'INFO'

            if ($isLive) {
                $confirm = [System.Windows.MessageBox]::Show(
                    "Reset passwords for $($selected.Count) selected student(s)?`n`nThis cannot be undone.",
                    'Confirm Live Run', 'YesNo', 'Warning')
                if ($confirm -ne 'Yes') { Write-Log 'PwReset: live run cancelled' 'INFO'; return }
            }

            # Pre-generate all passwords on the UI thread (New-Password unavailable in bg runspace)
            $work = @($selected | ForEach-Object {
                $pw = New-Password
                $_.Password = $pw
                @{ Id = $_.Id; DisplayName = $_.DisplayName; Upn = $_.UPN; Password = $pw }
            })
            $Script:PwReset_UI.Grid.Items.Refresh()

            if (-not $isLive) {
                # Dry run — instant, no network calls
                foreach ($row in $selected) { $row.Status = 'OK' }
                $Script:PwReset_UI.Grid.Items.Refresh()
                $forceLabel = if ($force) { 'will prompt on next sign-in' } else { 'no prompt required' }
                foreach ($item in $work) { Write-PwLog "[DRY RUN] $($item.DisplayName) — password generated ($forceLabel)" 'TextDim' }
                $Script:PwReset_UI.BtnExport.IsEnabled     = $true
                $Script:PwReset_UI.PnlStats.Visibility     = 'Visible'
                $Script:PwReset_UI.LblTotal.Text           = "Total  $($selected.Count)"
                $Script:PwReset_UI.LblOK.Text              = "OK     $($selected.Count)"
                $Script:PwReset_UI.LblFailed.Text          = "Failed 0"
                $Script:PwReset_UI.LblFailed.Foreground    = Get-ThemeHex 'TextDim'
                Update-PwSelectionLabel
                Write-PwLog "Dry run complete — $($selected.Count) passwords generated." 'Success'
                Set-MainStatus "Dry run complete — $($selected.Count) passwords generated." 'Success'
                return
            }

            # Live run — lock UI
            $Script:PwReset_Running                    = $true
            $Script:PwReset_UI.BtnRun.IsEnabled        = $false
            $Script:PwReset_UI.BtnLoad.IsEnabled       = $false
            $Script:PwReset_UI.BtnExport.IsEnabled     = $false
            $Script:PwReset_UI.BtnSelectAll.IsEnabled  = $false
            $Script:PwReset_UI.BtnSelectNone.IsEnabled = $false
            $Script:PwReset_UI.Progress.Visibility     = 'Visible'
            $Script:PwReset_UI.Progress.Maximum        = $work.Count
            $Script:PwReset_UI.Progress.Value          = 0

            if ($Script:DemoMode) {
                # Demo live run — instant simulation, no async needed
                foreach ($item in $work) {
                    $row = $Script:PwReset_Rows | Where-Object { $_.Id -eq $item.Id } | Select-Object -First 1
                    if ($row) { $row.Status = 'OK' }
                    Write-PwLog "OK: $($item.DisplayName)  ($($item.Upn))  [DEMO]" 'Success'
                }
                $Script:PwReset_UI.Grid.Items.Refresh()
                $ok = $work.Count
                $Script:PwReset_Running                    = $false
                $Script:PwReset_UI.Progress.Visibility     = 'Collapsed'
                $Script:PwReset_UI.BtnLoad.IsEnabled       = $true
                $Script:PwReset_UI.BtnExport.IsEnabled     = $true
                $Script:PwReset_UI.BtnSelectAll.IsEnabled  = $true
                $Script:PwReset_UI.BtnSelectNone.IsEnabled = $true
                $Script:PwReset_UI.PnlStats.Visibility     = 'Visible'
                $Script:PwReset_UI.LblTotal.Text           = "Total  $ok"
                $Script:PwReset_UI.LblOK.Text              = "OK     $ok"
                $Script:PwReset_UI.LblFailed.Text          = "Failed 0"
                $Script:PwReset_UI.LblFailed.Foreground    = Get-ThemeHex 'TextDim'
                Update-PwSelectionLabel
                Write-PwLog "Demo live run complete — $ok OK." 'Success'
                Set-MainStatus "Demo live run complete — $ok OK." 'Success'
                return
            }

            # Real live run — async so the UI stays responsive
            if ($Script:PwResetTimer) { $Script:PwResetTimer.Stop() }
            $Script:PwResetTimer = Start-AsyncWork `
                -RefSeed @{ Ok = 0; Fail = 0; Queue = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new() } `
                -Vars @{ Work = $work; Force = $force } `
                -IntervalMs 300 `
                -Script {
                    foreach ($item in $Work) {
                        $r = @{ Id = $item.Id; Name = $item.DisplayName; Upn = $item.Upn; Ok = $false; Err = '' }
                        try {
                            $body = @{ passwordProfile = @{ password = $item.Password; forceChangePasswordNextSignIn = $Force } } | ConvertTo-Json
                            Invoke-RestMethod `
                                -Uri "https://graph.microsoft.com/v1.0/users/$($item.Id)" `
                                -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } `
                                -Method PATCH `
                                -Body $body `
                                -ErrorAction Stop
                            $r.Ok = $true
                            $Ref['Ok']++
                        } catch {
                            $r.Err = $_.Exception.Message
                            $Ref['Fail']++
                        }
                        $Ref['Queue'].Enqueue($r)
                    }
                } `
                -OnProgress {
                    param($ref)
                    $item = $null
                    while ($ref['Queue'].TryDequeue([ref]$item)) {
                        $row = $Script:PwReset_Rows | Where-Object { $_.Id -eq $item.Id } | Select-Object -First 1
                        if ($row) { $row.Status = if ($item.Ok) { 'OK' } else { 'Failed' } }
                        $logMsg = if ($item.Ok) { "OK: $($item.Name)  ($($item.Upn))" } else { "FAILED: $($item.Name) — $($item.Err)" }
                        Write-AppLog $logMsg $(if ($item.Ok) { 'Success' } else { 'Danger' })
                    }
                    $Script:PwReset_UI.Grid.Items.Refresh()
                    $Script:PwReset_UI.Progress.Value = $ref['Ok'] + $ref['Fail']
                } `
                -OnComplete {
                    param($ref)
                    try {
                        # Drain any items that arrived after the last OnProgress tick
                        $item = $null
                        while ($ref['Queue'].TryDequeue([ref]$item)) {
                            $row = $Script:PwReset_Rows | Where-Object { $_.Id -eq $item.Id } | Select-Object -First 1
                            if ($row) { $row.Status = if ($item.Ok) { 'OK' } else { 'Failed' } }
                            $logMsg = if ($item.Ok) { "OK: $($item.Name)  ($($item.Upn))" } else { "FAILED: $($item.Name) — $($item.Err)" }
                            Write-AppLog $logMsg $(if ($item.Ok) { 'Success' } else { 'Danger' })
                        }
                        $Script:PwReset_UI.Grid.Items.Refresh()
                        $ok   = $ref['Ok']
                        $fail = $ref['Fail']
                        $Script:PwReset_Running                    = $false
                        $Script:PwReset_UI.Progress.Visibility     = 'Collapsed'
                        $Script:PwReset_UI.BtnLoad.IsEnabled       = $true
                        $Script:PwReset_UI.BtnExport.IsEnabled     = $true
                        $Script:PwReset_UI.BtnSelectAll.IsEnabled  = $true
                        $Script:PwReset_UI.BtnSelectNone.IsEnabled = $true
                        $Script:PwReset_UI.PnlStats.Visibility     = 'Visible'
                        $Script:PwReset_UI.LblTotal.Text           = "Total  $($ok + $fail)"
                        $Script:PwReset_UI.LblOK.Text              = "OK     $ok"
                        $Script:PwReset_UI.LblFailed.Text          = "Failed $fail"
                        $Script:PwReset_UI.LblFailed.Foreground    = if ($fail -gt 0) { Get-ThemeHex 'Danger' } else { Get-ThemeHex 'TextDim' }
                        Update-PwSelectionLabel
                        $col = if ($fail -gt 0) { 'Warning' } else { 'Success' }
                        Write-PwLog "Live run complete — $ok OK, $fail failed." $col
                        Set-MainStatus "Live run complete — $ok OK, $fail failed." $col
                    } catch {
                        Write-Log "PwReset OnComplete error: $_" 'ERROR'
                    }
                }
        } catch {
            $Script:PwReset_Running = $false
            Write-Log "BtnRun click error: $_" 'ERROR'
        }
    })

    # Export CSV
    $Script:PwReset_UI.BtnExport.Add_Click({
        try {
            $dlg = New-Object Microsoft.Win32.SaveFileDialog
            $dlg.Filter   = 'CSV files (*.csv)|*.csv'
            $dlg.FileName = "PasswordReset_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
            if (-not $dlg.ShowDialog()) { return }
            Write-Log "PwReset: exporting CSV to $($dlg.FileName)" 'INFO'
            $Script:PwReset_Rows | Select-Object DisplayName, UPN, Department, Password, Status |
                ConvertTo-EtbCsvRow | Export-Csv -Path $dlg.FileName -NoTypeInformation -Encoding UTF8
            Write-PwLog "CSV exported: $($dlg.FileName)" 'Success'
            Set-MainStatus "Saved: $($dlg.FileName)" 'Success'
            [System.Windows.MessageBox]::Show("Saved to:`n$($dlg.FileName)", 'Export Complete', 'OK', 'Information') | Out-Null
        } catch {
            Write-Log "BtnExport click error: $_" 'ERROR'
        }
    })

    # Register with the global connect/reset hooks
    Register-ConnectCallback 'Start-PwUserLoad'
    $Script:ResetCallbacks.Add({
        if ($Script:PwResetTimer) { $Script:PwResetTimer.Stop(); $Script:PwResetTimer = $null }
        $Script:PwReset_Rows.Clear()
        $Script:PwReset_GraphUsers = @()
        $Script:PwReset_UI.CboYear.Items.Clear()
        $Script:PwReset_UI.CboYear.IsEnabled        = $false
        $Script:PwReset_UI.BtnLoad.IsEnabled        = $false
        $Script:PwReset_UI.BtnRun.IsEnabled         = $false
        $Script:PwReset_UI.BtnExport.IsEnabled      = $false
        $Script:PwReset_UI.BtnSelectAll.IsEnabled   = $false
        $Script:PwReset_UI.BtnSelectNone.IsEnabled  = $false
        $Script:PwReset_UI.LblSelection.Text        = ''
        $Script:PwReset_UI.PnlStats.Visibility      = 'Collapsed'
    })

    Write-PwLog 'Password Reset ready. Select a tenant to begin.' 'Muted'
    return $content
}
