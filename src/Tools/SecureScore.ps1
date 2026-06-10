<#
    SecureScore.ps1 — Microsoft Secure Score view for Art's Entra Toolbox.
    Dot-sourced by Start.ps1. Exposes Initialize-SecureScoreTool.

    Fetches the latest score snapshot and all control profiles, then displays:
      - Large percentage headline (green / amber / red by threshold)
      - Points tally and score date
      - Threshold guide with the active band highlighted
      - Per-control breakdown table (Category, Control, Score, Max Score)
#>

$Script:SS_UI        = $null
$Script:SS_LoadTimer = $null

function Write-SsLog([string]$Msg, [string]$Color = 'TextDim') { Write-AppLog $Msg $Color }

function Get-SsScoreKey([double]$Pct) {
    if ($Pct -ge 70) { return 'Success' }
    if ($Pct -ge 40) { return 'Accent' }
    return 'Danger'
}

function Get-SsBandIndex([double]$Pct) {
    if ($Pct -ge 80) { return 0 }
    if ($Pct -ge 70) { return 1 }
    if ($Pct -ge 40) { return 2 }
    return 3
}

# ── Async load ─────────────────────────────────────────────────────────────────
function Start-SsLoad {
    if ($Script:DemoMode) { Start-SsLoadDemo; return }
    if (-not $Script:SS_UI) { return }

    $Script:SS_UI.ScoreLabel.Text       = '—'
    $Script:SS_UI.ScoreLabel.Foreground = New-SolidBrush 'Muted'
    $Script:SS_UI.PointsLabel.Text      = 'Loading...'
    $Script:SS_UI.DateLabel.Text        = ''
    $Script:SS_UI.ControlsGrid.ItemsSource = $null
    $Script:SS_UI.BtnRefresh.IsEnabled  = $false
    Write-SsLog 'Fetching Secure Score...' 'TextDim'

    if ($Script:SS_LoadTimer) { $Script:SS_LoadTimer.Stop() }
    $Script:SS_LoadTimer = Start-AsyncWork `
        -RefSeed @{ Score = $null; Profiles = $null } `
        -Script {
            $r = Invoke-RestMethod `
                -Uri 'https://graph.microsoft.com/v1.0/security/secureScores?$top=1&$orderby=createdDateTime desc' `
                -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
            $Ref['Score'] = if ($r.value.Count -gt 0) { $r.value[0] } else { $null }

            $profiles = [System.Collections.Generic.List[object]]::new()
            $url = 'https://graph.microsoft.com/v1.0/security/secureScoreControlProfiles'
            do {
                $rp = Invoke-RestMethod -Uri $url `
                    -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
                foreach ($p in $rp.value) { $profiles.Add($p) }
                $url = $rp.'@odata.nextLink'
            } while ($url)
            $Ref['Profiles'] = $profiles.ToArray()
        } -OnComplete {
            param($ref)
            try {
                $Script:SS_UI.BtnRefresh.IsEnabled = $true
                if ($ref['Error'] -eq '401') { Write-SsLog 'Session expired — reconnect.' 'Danger'; return }
                if ($ref['Error'])           { Write-SsLog "Secure Score error: $($ref['Error'])" 'Danger'; return }
                Set-SsDisplay -Score $ref['Score'] -Profiles $ref['Profiles']
                Write-SsLog 'Secure Score loaded.' 'Success'
            } catch { Write-Log "SS OnComplete: $_" 'ERROR' }
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
    $pct = if ($max -gt 0) { [Math]::Round($cur / $max * 100, 1) } else { 0.0 }

    $Script:SS_UI.ScoreLabel.Text       = "$pct%"
    $Script:SS_UI.ScoreLabel.Foreground = New-SolidBrush (Get-SsScoreKey $pct)
    $Script:SS_UI.PointsLabel.Text      = "$([int]$cur) / $([int]$max) pts"

    try {
        $dt = [datetime]::Parse($Score.createdDateTime)
        $Script:SS_UI.DateLabel.Text = "Score as of $($dt.ToString('d MMM yyyy'))"
    } catch { $Script:SS_UI.DateLabel.Text = '' }

    # Highlight the active threshold band
    $activeBandIdx = Get-SsBandIndex $pct
    $bandKeys = @('BandLbl0', 'BandLbl1', 'BandLbl2', 'BandLbl3')
    for ($i = 0; $i -lt $bandKeys.Length; $i++) {
        $Script:SS_UI[$bandKeys[$i]].Foreground = New-SolidBrush (if ($i -eq $activeBandIdx) { 'Text' } else { 'Muted' })
    }

    # Build profile lookup: controlId → human-readable title
    $titleMap = @{}
    if ($Profiles) { foreach ($p in $Profiles) { $titleMap[$p.id] = $p.title } }

    # Build rows sorted by category asc, score desc
    $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ($Score.controlScores) {
        $sorted = @($Score.controlScores | Sort-Object { $_.controlCategory }, { -[double]$_.score })
        foreach ($c in $sorted) {
            $title = if ($titleMap.ContainsKey($c.controlName)) { $titleMap[$c.controlName] } else { $c.controlName }
            $rows.Add([PSCustomObject]@{
                Category = $c.controlCategory
                Control  = $title
                Score    = [Math]::Round([double]$c.score, 1)
                MaxScore = [Math]::Round([double]$c.maxScore, 1)
            })
        }
    }
    $Script:SS_UI.ControlsGrid.ItemsSource = $rows
}

# ── Demo stub ──────────────────────────────────────────────────────────────────
function Start-SsLoadDemo {
    $score = [PSCustomObject]@{
        currentScore    = 285.0
        maxScore        = 420.0
        createdDateTime = (Get-Date).ToString('o')
        controlScores   = @(
            [PSCustomObject]@{ controlName = 'MFARegistrationV2';          controlCategory = 'Identity'; score = 35.0; maxScore = 50.0 }
            [PSCustomObject]@{ controlName = 'AdminMFAV2';                  controlCategory = 'Identity'; score = 20.0; maxScore = 20.0 }
            [PSCustomObject]@{ controlName = 'BlockLegacyAuthentication';   controlCategory = 'Identity'; score = 10.0; maxScore = 10.0 }
            [PSCustomObject]@{ controlName = 'SelfServicePasswordReset';    controlCategory = 'Identity'; score = 5.0;  maxScore = 10.0 }
            [PSCustomObject]@{ controlName = 'IntuneMobileDeviceMgmt';      controlCategory = 'Device';   score = 40.0; maxScore = 60.0 }
            [PSCustomObject]@{ controlName = 'BitLockerForWindowsDevices';  controlCategory = 'Device';   score = 20.0; maxScore = 30.0 }
            [PSCustomObject]@{ controlName = 'DLPEnabled';                  controlCategory = 'Data';     score = 30.0; maxScore = 50.0 }
            [PSCustomObject]@{ controlName = 'AppConditionalAccessPolicies';controlCategory = 'Apps';     score = 40.0; maxScore = 60.0 }
            [PSCustomObject]@{ controlName = 'CloudAppSecurityMcas';        controlCategory = 'Apps';     score = 30.0; maxScore = 40.0 }
            [PSCustomObject]@{ controlName = 'RiskyUsers';                  controlCategory = 'Identity'; score = 15.0; maxScore = 20.0 }
            [PSCustomObject]@{ controlName = 'DefenderATPForWindows';       controlCategory = 'Device';   score = 25.0; maxScore = 40.0 }
            [PSCustomObject]@{ controlName = 'SecureDocumentSharingPolicy'; controlCategory = 'Data';     score = 15.0; maxScore = 30.0 }
        )
    }
    $profiles = $score.controlScores | ForEach-Object {
        [PSCustomObject]@{ id = $_.controlName; title = $_.controlName -creplace '(?<=[a-z])(?=[A-Z])', ' ' }
    }
    Set-SsDisplay -Score $score -Profiles $profiles
    Write-SsLog 'Demo: Secure Score loaded (Contoso Academy).' 'Muted'
    $Script:SS_UI.BtnRefresh.IsEnabled = $true
}

# ── XAML ───────────────────────────────────────────────────────────────────────
$Script:SsXaml = @'
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

    <Style x:Key="DgHdr" TargetType="DataGridColumnHeader">
      <Setter Property="Background"      Value="#1C1C2A"/>
      <Setter Property="Foreground"      Value="#7878A0"/>
      <Setter Property="BorderBrush"     Value="#3C3C5A"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="Padding"         Value="12,0"/>
      <Setter Property="Height"          Value="32"/>
      <Setter Property="FontSize"        Value="11"/>
      <Setter Property="FontWeight"      Value="SemiBold"/>
    </Style>

    <Style x:Key="DgCell" TargetType="DataGridCell">
      <Setter Property="Foreground"       Value="#E2E2F0"/>
      <Setter Property="Background"       Value="Transparent"/>
      <Setter Property="BorderThickness"  Value="0"/>
      <Setter Property="Padding"          Value="12,0"/>
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
    <Grid Margin="24,16,24,16">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="20"/>
        <ColumnDefinition Width="1"/>
        <ColumnDefinition Width="20"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>

      <!-- Score percentage -->
      <StackPanel Grid.Column="0" VerticalAlignment="Center">
        <TextBlock x:Name="SsScoreLabel" Text="—" FontSize="56" FontWeight="Bold"
                   Foreground="#50507A" VerticalAlignment="Center"/>
        <TextBlock x:Name="SsPointsLabel" Text="No tenant connected."
                   Foreground="#7878A0" FontSize="13" Margin="2,0,0,2"/>
        <TextBlock x:Name="SsDateLabel" Text=""
                   Foreground="#50507A" FontSize="11" Margin="2,0,0,0"/>
      </StackPanel>

      <!-- Vertical divider -->
      <Border Grid.Column="2" Width="1" Background="#3C3C5A" Margin="0,6"/>

      <!-- Threshold bands -->
      <StackPanel Grid.Column="4" VerticalAlignment="Center">
        <TextBlock Text="THRESHOLD GUIDE" Foreground="#50507A" FontSize="10"
                   FontWeight="Bold" Margin="0,0,0,8"/>
        <TextBlock x:Name="SsBandLbl0" Text="≥ 80%   Excellent"                           Foreground="#50507A" FontSize="12" Margin="0,2"/>
        <TextBlock x:Name="SsBandLbl1" Text="70–79%  Good"                                 Foreground="#50507A" FontSize="12" Margin="0,2"/>
        <TextBlock x:Name="SsBandLbl2" Text="40–69%  Moderate risk"                        Foreground="#50507A" FontSize="12" Margin="0,2"/>
        <TextBlock x:Name="SsBandLbl3" Text="&lt; 40%   High risk — immediate action needed" Foreground="#50507A" FontSize="12" Margin="0,2"/>
      </StackPanel>

      <!-- Refresh button -->
      <Button x:Name="SsBtnRefresh" Grid.Column="5" Content="Refresh"
              Style="{StaticResource Btn}" Background="#3C3C5A"
              Padding="16,8" VerticalAlignment="Top" IsEnabled="False"/>
    </Grid>
  </Border>

  <!-- Controls table -->
  <DataGrid x:Name="SsControlsGrid" Grid.Row="1"
            AutoGenerateColumns="False" IsReadOnly="True"
            CanUserAddRows="False" CanUserDeleteRows="False"
            CanUserReorderColumns="False" CanUserResizeRows="False"
            SelectionMode="Single" HeadersVisibility="Column"
            RowBackground="#12121C" AlternatingRowBackground="#181826"
            GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#1E1E32"
            Background="#12121C" BorderThickness="0" Foreground="#E2E2F0"
            ColumnHeaderStyle="{StaticResource DgHdr}"
            CellStyle="{StaticResource DgCell}"
            RowStyle="{StaticResource DgRow}"
            RowHeight="34">
    <DataGrid.Columns>
      <DataGridTextColumn Header="Category"  Binding="{Binding Category}" Width="130"/>
      <DataGridTextColumn Header="Control"   Binding="{Binding Control}"  Width="*"/>
      <DataGridTextColumn Header="Score"     Binding="{Binding Score}"    Width="80"/>
      <DataGridTextColumn Header="Max Score" Binding="{Binding MaxScore}" Width="90"/>
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
        BandLbl0     = $content.FindName('SsBandLbl0')
        BandLbl1     = $content.FindName('SsBandLbl1')
        BandLbl2     = $content.FindName('SsBandLbl2')
        BandLbl3     = $content.FindName('SsBandLbl3')
        ControlsGrid = $content.FindName('SsControlsGrid')
        BtnRefresh   = $content.FindName('SsBtnRefresh')
    }

    $Script:SS_UI.BtnRefresh.Add_Click({
        try { Start-SsLoad } catch { Write-Log "SS Refresh: $_" 'ERROR' }
    })

    Register-ConnectCallback 'Start-SsLoad'

    $Script:ResetCallbacks.Add({
        $Script:SS_UI.ScoreLabel.Text          = '—'
        $Script:SS_UI.ScoreLabel.Foreground    = New-SolidBrush 'Muted'
        $Script:SS_UI.PointsLabel.Text         = 'No tenant connected.'
        $Script:SS_UI.DateLabel.Text           = ''
        $Script:SS_UI.ControlsGrid.ItemsSource = $null
        $Script:SS_UI.BtnRefresh.IsEnabled     = $false
    })

    Write-SsLog 'Secure Score ready. Connect a tenant to begin.' 'Muted'
    return $content
}
