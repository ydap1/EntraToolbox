<#
    Appearance page for Art's Entra Toolbox.
    Dot-sourced by Start.ps1.
    Exposes Initialize-AppearanceTool.

    Lets the user pick a colour theme preset. The choice is persisted via
    Set-AppSetting ('ThemeName') and read by Auth.ps1 at startup.
    Because colours are baked into each panel's XAML at load time, a
    change takes effect on the next launch — Apply & Restart relaunches the app.
#>

$Script:AP_UI       = $null
$Script:AP_SelTheme = $null
$Script:AP_Cards    = @{}   # preset name → card Border

function Set-ApThemeSelection {
    param([string]$Name)
    if (-not $Script:ThemePresets.Contains($Name)) { return }
    $Script:AP_SelTheme = $Name
    foreach ($n in $Script:AP_Cards.Keys) {
        $card   = $Script:AP_Cards[$n]
        $preset = $Script:ThemeBase.Clone()
        foreach ($k in $Script:ThemePresets[$n].Keys) { $preset[$k] = $Script:ThemePresets[$n][$k] }
        if ($n -eq $Name) {
            $card.BorderBrush     = [System.Windows.Media.BrushConverter]::new().ConvertFromString($preset.Accent)
            $card.BorderThickness = [System.Windows.Thickness]::new(2)
        } else {
            $card.BorderBrush     = [System.Windows.Media.BrushConverter]::new().ConvertFromString($preset.Border)
            $card.BorderThickness = [System.Windows.Thickness]::new(1)
        }
    }
}

function Save-ApSettings {
    param([switch]$Restart)
    Set-AppSetting -Name 'ThemeName' -Value $Script:AP_SelTheme
    Write-Log "Appearance: saved theme '$($Script:AP_SelTheme)'" 'INFO'
    if ($Restart) {
        Write-AppLog 'Restarting to apply appearance changes...' 'Accent'
        Start-Process 'pwsh.exe' `
            -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$Global:AppRoot\Start.ps1`"" `
            -WorkingDirectory $Global:AppRoot
        $Script:MainUI.Window.Close()
    } else {
        Write-AppLog "Appearance saved — theme '$($Script:AP_SelTheme)'. Changes apply on next launch." 'Success'
        $Script:AP_UI.Status.Text = 'Saved. Changes apply on next launch.'
    }
}

# ── XAML ───────────────────────────────────────────────────────────────────────
$Script:ApXaml = @'
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
                    CornerRadius="6" Padding="{TemplateBinding Padding}">
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

  </Grid.Resources>

  <ScrollViewer VerticalScrollBarVisibility="Auto">
    <StackPanel Margin="28,22,28,28" MaxWidth="760" HorizontalAlignment="Left">
      <TextBlock Text="Appearance" FontSize="18" FontWeight="Bold" Foreground="#E2E2F0"/>
      <TextBlock Text="Colours are baked in when panels load, so changes apply after a restart."
                 Foreground="#50507A" FontSize="11" Margin="0,4,0,20"/>

      <TextBlock Text="THEME" Foreground="#50507A" FontSize="10" FontWeight="Bold" Margin="0,0,0,8"/>
      <WrapPanel x:Name="ApThemePanel"/>

      <StackPanel Orientation="Horizontal" Margin="0,22,0,0">
        <Button x:Name="ApBtnApply" Content="Apply &amp; Restart" Style="{StaticResource Btn}"
                Background="#6366F1" Padding="18,9" Margin="0,0,10,0"/>
        <Button x:Name="ApBtnSave" Content="Save Only" Style="{StaticResource Btn}"
                Background="#3C3C5A" Padding="14,9"
                ToolTip="Save the selection without restarting — applies on next launch"/>
        <TextBlock x:Name="ApStatus" Foreground="#7878A0" FontSize="12"
                   VerticalAlignment="Center" Margin="14,0,0,0"/>
      </StackPanel>
    </StackPanel>
  </ScrollViewer>
</Grid>
'@

# ── Initialize ─────────────────────────────────────────────────────────────────
function Initialize-AppearanceTool {
    $reader  = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new((Invoke-ThemeXaml $Script:ApXaml)))
    $content = [System.Windows.Markup.XamlReader]::Load($reader)

    $Script:AP_UI = @{
        ThemePanel = $content.FindName('ApThemePanel')
        BtnApply   = $content.FindName('ApBtnApply')
        BtnSave    = $content.FindName('ApBtnSave')
        Status     = $content.FindName('ApStatus')
    }
    $Script:AP_Cards    = @{}
    $Script:AP_SelTheme = $Script:ThemeName

    # ── Theme preset cards (built in code so new presets appear automatically) ──
    $conv = [System.Windows.Media.BrushConverter]::new()
    foreach ($name in $Script:ThemePresets.Keys) {
        $preset = $Script:ThemeBase.Clone()
        foreach ($k in $Script:ThemePresets[$name].Keys) { $preset[$k] = $Script:ThemePresets[$name][$k] }

        $card                 = [System.Windows.Controls.Border]::new()
        $card.Width           = 168
        $card.CornerRadius    = [System.Windows.CornerRadius]::new(8)
        $card.Margin          = [System.Windows.Thickness]::new(0, 0, 12, 12)
        $card.Padding         = [System.Windows.Thickness]::new(14, 12, 14, 12)
        $card.Cursor          = [System.Windows.Input.Cursors]::Hand
        $card.Background      = $conv.ConvertFromString($preset.Bg)
        $card.BorderBrush     = $conv.ConvertFromString($preset.Border)
        $card.BorderThickness = [System.Windows.Thickness]::new(1)
        $card.Tag             = $name

        $sp = [System.Windows.Controls.StackPanel]::new()

        $dots = [System.Windows.Controls.StackPanel]::new()
        $dots.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        foreach ($dotHex in @($preset.Accent, $preset.Card, $preset.Surface)) {
            $dot        = [System.Windows.Shapes.Ellipse]::new()
            $dot.Width  = 14; $dot.Height = 14
            $dot.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
            $dot.Fill   = $conv.ConvertFromString($dotHex)
            [void]$dots.Children.Add($dot)
        }
        [void]$sp.Children.Add($dots)

        $lbl            = [System.Windows.Controls.TextBlock]::new()
        $lbl.Text       = $name
        $lbl.Foreground = $conv.ConvertFromString($preset.Text)
        $lbl.FontSize   = 12
        $lbl.FontWeight = [System.Windows.FontWeights]::SemiBold
        $lbl.Margin     = [System.Windows.Thickness]::new(0, 9, 0, 0)
        [void]$sp.Children.Add($lbl)

        $card.Child = $sp

        # Same typed-delegate pattern as the nav items: read the name from the
        # sender's Tag — closure-captured locals are gone by invocation time.
        $card.AddHandler(
            [System.Windows.UIElement]::MouseLeftButtonDownEvent,
            [System.Windows.Input.MouseButtonEventHandler]{
                param($s, $e)
                try { Set-ApThemeSelection -Name $s.Tag }
                catch { Write-Log "Appearance theme card click error: $_" 'ERROR' }
            },
            $true
        )

        [void]$Script:AP_UI.ThemePanel.Children.Add($card)
        $Script:AP_Cards[$name] = $card
    }
    Set-ApThemeSelection -Name $Script:AP_SelTheme

    $Script:AP_UI.BtnApply.Add_Click({
        try { Save-ApSettings -Restart }
        catch { Write-Log "Appearance apply error: $_" 'ERROR' }
    })
    $Script:AP_UI.BtnSave.Add_Click({
        try { Save-ApSettings }
        catch { Write-Log "Appearance save error: $_" 'ERROR' }
    })

    return $content
}
