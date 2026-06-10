<#
    Secure Score tab for Art's Entra Toolbox.
    Dot-sourced by Start.ps1.
    Exposes Initialize-SecureScoreTool.

    Read-only view of the tenant's Microsoft Secure Score.
    Fetches: GET /v1.0/security/secureScores?$top=1&$orderby=createdDateTime desc
             GET /v1.0/security/secureScoreControlProfiles
    Joins controlScores[].controlName to profiles[].id to get human-readable titles.
#>

$Script:SS_UI        = $null
$Script:SS_LoadTimer = $null

# ── Log ────────────────────────────────────────────────────────────────────────
function Write-SsLog {
    param([string]$Msg, [string]$Color = 'TextDim')
    Write-AppLog $Msg $Color
}

# ── Score colour helper ────────────────────────────────────────────────────────
function Get-SsScoreColor([double]$Pct) {
    if ($Pct -ge 70) { return '#22C55E' }
    if ($Pct -ge 40) { return '#F59E0B' }
    return '#EF4444'
}

# ── Threshold band helpers ─────────────────────────────────────────────────────
# Returns index 0=Excellent, 1=Good, 2=Moderate, 3=High risk
function Get-SsBandIndex([double]$Pct) {
    if ($Pct -ge 80) { return 0 }
    if ($Pct -ge 70) { return 1 }
    if ($Pct -ge 40) { return 2 }
    return 3
}

# ── Async score load ───────────────────────────────────────────────────────────
function Start-SsLoad {
    if ($Script:DemoMode) { Start-SsLoadDemo; return }
    if (-not $Script:SS_UI) { return }

    $Script:SS_UI.ScoreLabel.Text       = '—'
    $Script:SS_UI.ScoreLabel.Foreground = [System.Windows.Media.Brushes]::Gray
    $Script:SS_UI.PointsLabel.Text      = 'Loading...'
    $Script:SS_UI.DateLabel.Text        = ''
    $Script:SS_UI.ControlsGrid.ItemsSource = $null
    $Script:SS_UI.BtnRefresh.IsEnabled  = $false
    Write-SsLog 'Fetching Secure Score...' 'TextDim'

    if ($Script:SS_LoadTimer) { $Script:SS_LoadTimer.Stop() }
    $Script:SS_LoadTimer = Start-AsyncWork `
        -RefSeed @{ Score = $null; Profiles = $null } `
        -Script {
            $scoreResp = Invoke-RestMethod `
                -Uri "https://graph.microsoft.com/v1.0/security/secureScores?`$top=1&`$orderby=createdDateTime desc" `
                -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
            $Ref['Score'] = if ($scoreResp.value.Count -gt 0) { $scoreResp.value[0] } else { $null }

            $profiles = [System.Collections.Generic.List[object]]::new()
            $url = 'https://graph.microsoft.com/v1.0/security/secureScoreControlProfiles'
            do {
                $resp = Invoke-RestMethod -Uri $url `
                    -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
                foreach ($p in $resp.value) { $profiles.Add($p) }
                $url = $resp.'@odata.nextLink'
            } while ($url)
            $Ref['Profiles'] = $profiles.ToArray()
        } -OnComplete {
            param($ref)
            try {
                $Script:SS_UI.BtnRefresh.IsEnabled = $true
                if ($ref['Error'] -eq '401') { Write-SsLog 'Session expired — reconnect.' 'Danger'; return }
                if ($ref['Error']) { Write-SsLog "Error loading Secure Score: $($ref['Error'])" 'Danger'; return }

                Set-SsDisplay -Score $ref['Score'] -Profiles $ref['Profiles']
                Write-SsLog 'Secure Score loaded.' 'Success'
            } catch { Write-Log "SS load error: $_" 'ERROR' }
        }
}

function Set-SsDisplay {
    param($Score, $Profiles)
    if (-not $Score) {
        $Script:SS_UI.ScoreLabel.Text  = 'N/A'
        $Script:SS_UI.PointsLabel.Text = 'No score data available.'
        return
    }

    $cur = [double]$Score.currentScore
    $max = [double]$Score.maxScore
    $pct = if ($max -gt 0) { [Math]::Round($cur / $max * 100, 1) } else { 0 }

    $colorHex = Get-SsScoreColor $pct
    $colorBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($colorHex)

    $Script:SS_UI.ScoreLabel.Text       = "$pct%"
    $Script:SS_UI.ScoreLabel.Foreground = $colorBrush
    $Script:SS_UI.PointsLabel.Text      = "$([int]$cur) / $([int]$max) pts"
    try {
        $dt = [datetime]::Parse($Score.createdDateTime)
        $Script:SS_UI.DateLabel.Text = "Score as of $($dt.ToString('d MMM yyyy'))"
    } catch { $Script:SS_UI.DateLabel.Text = '' }

    # Update threshold band borders
    $activeBandIdx = Get-SsBandIndex $pct
    $activeBrush   = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E6E9EF')
    $mutedBrush    = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#5B6472')
    for ($i = 0; $i -lt $Script:SS_UI.BandLabels.Count; $i++) {
        $Script:SS_UI.BandLabels[$i].Foreground = if ($i -eq $activeBandIdx) { $activeBrush } else { $mutedBrush }
    }

    # Build profile lookup map: id → title
    $profileMap = @{}
    if ($Profiles) {
        foreach ($p in $Profiles) { $profileMap[$p.id] = $p.title }
    }

    # Build controls rows sorted by category asc, score desc
    $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ($Score.controlScores) {
        $sorted = @($Score.controlScores | Sort-Object { $_.controlCategory }, { -[double]$_.score })
        foreach ($c in $sorted) {
            $title = if ($profileMap.ContainsKey($c.controlName)) { $profileMap[$c.controlName] } else { $c.controlName }
            $rows.Add([PSCustomObject]@{
                Category    = $c.controlCategory
                ControlName = $title
                Score       = [Math]::Round([double]$c.score, 1)
                MaxScore    = [Math]::Round([double]$c.maxScore, 1)
            })
        }
    }
    $Script:SS_UI.ControlsGrid.ItemsSource = $rows
}

# ── Demo stub ──────────────────────────────────────────────────────────────────
function Start-SsLoadDemo {
    $demoScore = [PSCustomObject]@{
        currentScore  = 285.0
        maxScore      = 420.0
        createdDateTime = (Get-Date).ToString('o')
        controlScores = @(
            [PSCustomObject]@{ controlName = 'MFARegistrationV2';          controlCategory = 'Identity'; score = 35.0; maxScore = 50.0 }
            [PSCustomObject]@{ controlName = 'AdminMFAV2';                  controlCategory = 'Identity'; score = 20.0; maxScore = 20.0 }
            [PSCustomObject]@{ controlName = 'BlockLegacyAuthentication';   controlCategory = 'Identity'; score = 10.0; maxScore = 10.0 }
            [PSCustomObject]@{ controlName = 'SelfServicePasswordReset';    controlCategory = 'Identity'; score = 5.0;  maxScore = 10.0 }
            [PSCustomObject]@{ controlName = 'RiskyUsers';                  controlCategory = 'Identity'; score = 15.0; maxScore = 20.0 }
            [PSCustomObject]@{ controlName = 'IntuneMobileDeviceMgmt';      controlCategory = 'Device';   score = 40.0; maxScore = 60.0 }
            [PSCustomObject]@{ controlName = 'DefenderATPForWindows';       controlCategory = 'Device';   score = 25.0; maxScore = 40.0 }
            [PSCustomObject]@{ controlName = 'BitLockerForWindowsDevices';  controlCategory = 'Device';   score = 20.0; maxScore = 30.0 }
            [PSCustomObject]@{ controlName = 'DLPEnabled';                  controlCategory = 'Data';     score = 30.0; maxScore = 50.0 }
            [PSCustomObject]@{ controlName = 'SecureDocumentSharingPolicy'; controlCategory = 'Data';     score = 15.0; maxScore = 30.0 }
            [PSCustomObject]@{ controlName = 'AppConditionalAccessPolicies';controlCategory = 'Apps';     score = 40.0; maxScore = 60.0 }
            [PSCustomObject]@{ controlName = 'CloudAppSecurityMcas';        controlCategory = 'Apps';     score = 30.0; maxScore = 40.0 }
        )
    }
    $demoProfiles = $demoScore.controlScores | ForEach-Object {
        [PSCustomObject]@{ id = $_.controlName; title = $_.controlName -creplace '(?<=[a-z])(?=[A-Z])', ' ' }
    }
    Set-SsDisplay -Score $demoScore -Profiles $demoProfiles
    Write-SsLog 'Demo: Secure Score loaded (Contoso Academy).' 'Muted'
    $Script:SS_UI.BtnRefresh.IsEnabled = $true
}

# ── XAML ───────────────────────────────────────────────────────────────────────
$Script:SsXaml = @'
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

    <Style x:Key="DgHdr" TargetType="DataGridColumnHeader">
      <Setter Property="Background"      Value="#1C1C2A"/>
      <Setter Property="Foreground"      Value="#7878A0"/>
      <Setter Property="BorderBrush"     Value="#3C3C5A"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="Padding"         Value="10,0"/>
      <Setter Property="Height"          Value="32"/>
      <Setter Property="FontSize"        Value="11"/>
      <Setter Property="FontWeight"      Value="SemiBold"/>
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

  <Grid.RowDefinitions>
    <RowDefinition Height="Auto"/>
    <RowDefinition Height="*"/>
  </Grid.RowDefinitions>

  <!-- Header panel -->
  <Border Grid.Row="0" Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
    <Grid Margin="24,16">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="24"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>

      <!-- Big score percentage -->
      <StackPanel Grid.Column="0" VerticalAlignment="Center">
        <TextBlock x:Name="SsScoreLabel" Text="—" FontSize="52" FontWeight="Bold"
                   Foreground="#5B6472" VerticalAlignment="Center"/>
        <TextBlock x:Name="SsPointsLabel" Text="No tenant connected."
                   Foreground="#8A93A3" FontSize="13" Margin="2,0,0,0"/>
        <TextBlock x:Name="SsDateLabel" Text=""
                   Foreground="#5B6472" FontSize="11" Margin="2,4,0,0"/>
      </StackPanel>

      <!-- Vertical divider -->
      <Border Grid.Column="1" Width="1" Background="#323943" Margin="0,4"/>

      <!-- Threshold bands -->
      <StackPanel Grid.Column="2" VerticalAlignment="Center" Margin="8,0">
        <TextBlock Text="THRESHOLD GUIDE" Foreground="#5B6472" FontSize="10" FontWeight="Bold" Margin="0,0,0,8"/>
        <Border x:Name="SsBand0" Padding="8,4" Margin="0,1">
          <TextBlock x:Name="SsBandLbl0" Text="≥ 80%   Excellent" Foreground="#5B6472" FontSize="12"/>
        </Border>
        <Border x:Name="SsBand1" Padding="8,4" Margin="0,1">
          <TextBlock x:Name="SsBandLbl1" Text="70–79%  Good" Foreground="#5B6472" FontSize="12"/>
        </Border>
        <Border x:Name="SsBand2" Padding="8,4" Margin="0,1">
          <TextBlock x:Name="SsBandLbl2" Text="40–69%  Moderate risk" Foreground="#5B6472" FontSize="12"/>
        </Border>
        <Border x:Name="SsBand3" Padding="8,4" Margin="0,1">
          <TextBlock x:Name="SsBandLbl3" Text="&lt; 40%   High risk — immediate action needed" Foreground="#5B6472" FontSize="12"/>
        </Border>
      </StackPanel>

      <!-- Refresh button -->
      <Button x:Name="SsBtnRefresh" Grid.Column="3" Content="Refresh"
              Style="{StaticResource PrimaryBtn}" Background="#3C3C5A"
              Padding="14,8" FontSize="12" VerticalAlignment="Top"
              IsEnabled="False"/>
    </Grid>
  </Border>

  <!-- Controls table -->
  <DataGrid x:Name="SsControlsGrid" Grid.Row="1"
            AutoGenerateColumns="False" IsReadOnly="True"
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
      <DataGridTextColumn Header="Category"     Binding="{Binding Category}"    Width="120"/>
      <DataGridTextColumn Header="Control"      Binding="{Binding ControlName}" Width="*"/>
      <DataGridTextColumn Header="Score"        Binding="{Binding Score}"       Width="80"/>
      <DataGridTextColumn Header="Max Score"    Binding="{Binding MaxScore}"    Width="90"/>
    </DataGrid.Columns>
  </DataGrid>

</Grid>
'@

# ── Initialize ─────────────────────────────────────────────────────────────────
function Initialize-SecureScoreTool {
    $reader  = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new((Invoke-ThemeXaml $Script:SsXaml)))
    $content = [System.Windows.Markup.XamlReader]::Load($reader)

    $Script:SS_UI = @{
        ScoreLabel   = $content.FindName('SsScoreLabel')
        PointsLabel  = $content.FindName('SsPointsLabel')
        DateLabel    = $content.FindName('SsDateLabel')
        BandLabels   = @(
            $content.FindName('SsBandLbl0')
            $content.FindName('SsBandLbl1')
            $content.FindName('SsBandLbl2')
            $content.FindName('SsBandLbl3')
        )
        ControlsGrid = $content.FindName('SsControlsGrid')
        BtnRefresh   = $content.FindName('SsBtnRefresh')
    }

    $Script:SS_UI.BtnRefresh.Add_Click({
        try { Start-SsLoad }
        catch { Write-Log "SS BtnRefresh click error: $_" 'ERROR' }
    })

    Register-ConnectCallback 'Start-SsLoad'
    $Script:ResetCallbacks.Add({
        $Script:SS_UI.ScoreLabel.Text       = '—'
        $Script:SS_UI.ScoreLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#5B6472')
        $Script:SS_UI.PointsLabel.Text      = 'No tenant connected.'
        $Script:SS_UI.DateLabel.Text        = ''
        $Script:SS_UI.ControlsGrid.ItemsSource = $null
        $Script:SS_UI.BtnRefresh.IsEnabled  = $false
    })

    Write-SsLog 'Secure Score ready. Select a tenant to begin.' 'Muted'
    return $content
}
