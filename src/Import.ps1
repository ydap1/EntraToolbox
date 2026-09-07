<#
    Shared "bring me this list of people" selector for Art's Entra Toolbox.
    Dot-sourced by Start.ps1.

    Every bulk tool could only pick users by department, office, or one search
    at a time, but the lists that actually arrive come out of the MIS as a CSV
    or a column pasted from a spreadsheet. Show-EtbUpnImport takes either and
    hands back UPNs; Select-EtbUsersByUpn then matches them against whatever
    user list the calling tool already holds.
#>

$Script:ImportXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Import user list" Width="470" Height="430"
        WindowStyle="ToolWindow" ResizeMode="CanResize"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False"
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
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#7878A0"/>
      <Setter Property="FontSize"   Value="11"/>
    </Style>
  </Window.Resources>

  <Grid Margin="20,16,20,16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <TextBlock Grid.Row="0" TextWrapping="Wrap" Margin="0,0,0,8"
               Text="Paste usernames, one per line — or import a CSV and pick the column holding them. Anything that is not a UPN is ignored."/>

    <TextBox x:Name="ImpText" Grid.Row="1"
             AcceptsReturn="True" AcceptsTab="False"
             VerticalScrollBarVisibility="Auto"
             HorizontalScrollBarVisibility="Auto"
             FontFamily="Consolas" FontSize="12"
             Background="#242436" Foreground="#E2E2F0"
             BorderBrush="#3C3C5A" BorderThickness="1"
             CaretBrush="#E2E2F0" Padding="8,6"/>

    <TextBlock x:Name="ImpStatus" Grid.Row="2" Margin="0,8,0,0" TextWrapping="Wrap"/>

    <Grid Grid.Row="3" Margin="0,12,0,0">
      <Button x:Name="ImpCsv" Content="Import CSV…" Style="{StaticResource Btn}"
              Background="#3C3C5A" Padding="14,8" HorizontalAlignment="Left"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="ImpCancel" Content="Cancel" Style="{StaticResource Btn}"
                Background="#3C3C5A" Padding="16,8" Margin="0,0,8,0"/>
        <Button x:Name="ImpOk" Content="Use List" Style="{StaticResource Btn}"
                Background="#6366F1" Padding="18,8"/>
      </StackPanel>
    </Grid>
  </Grid>
</Window>
'@

# Pulls UPN-shaped tokens out of free text. Accepts one per line, and also
# copes with a whole CSV row being pasted by splitting on commas, semicolons,
# tabs and quotes first.
function Get-EtbUpnsFromText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($token in ($Text -split '[\r\n,;\t"'']')) {
        $candidate = $token.Trim()
        # Deliberately loose: Entra accepts far more than RFC 5322, and a UPN
        # that does not match a loaded user is reported rather than silently cut.
        if ($candidate -match '^[^@\s]+@[^@\s]+\.[^@\s]+$') { [void]$seen.Add($candidate) }
    }
    @($seen)
}

# Reads every field of a CSV rather than guessing a column name: schools export
# the UPN under "UPN", "Email", "UserPrincipalName" or something bespoke.
function Get-EtbUpnsFromCsv {
    param([Parameter(Mandatory)][string]$Path)
    $rows = Import-Csv -Path $Path -ErrorAction Stop
    $text = foreach ($row in $rows) {
        foreach ($property in $row.PSObject.Properties) { $property.Value }
    }
    Get-EtbUpnsFromText ($text -join "`n")
}

# Dialog state. Held at script scope, like the add-tenant dialog, because WPF
# event handlers do not reliably see locals of the function that wired them up.
$Script:ImpWin    = $null
$Script:ImpBox    = $null
$Script:ImpStatus = $null
$Script:ImpResult = @()

# Returns the UPNs the operator chose, or an empty array if they cancelled.
function Show-EtbUpnImport {
    $reader = [System.Xml.XmlReader]::Create(
        [System.IO.StringReader]::new((Invoke-ThemeXaml $Script:ImportXaml)))
    $Script:ImpWin    = [System.Windows.Markup.XamlReader]::Load($reader)
    $Script:ImpBox    = $Script:ImpWin.FindName('ImpText')
    $Script:ImpStatus = $Script:ImpWin.FindName('ImpStatus')
    $Script:ImpResult = @()
    if ($Script:MainUI -and $Script:MainUI.Window) {
        $Script:ImpWin.Owner = $Script:MainUI.Window
    }

    $Script:ImpWin.FindName('ImpCsv').Add_Click({
        try {
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
            $dlg.Title  = 'Import user list'
            if (-not $dlg.ShowDialog()) { return }
            $upns = @(Get-EtbUpnsFromCsv -Path $dlg.FileName)
            if ($upns.Count -eq 0) {
                $Script:ImpStatus.Text = 'No usernames found in that file.'
                return
            }
            $Script:ImpBox.Text    = ($upns -join "`r`n")
            $Script:ImpStatus.Text = "Found $($upns.Count) username(s) in $(Split-Path $dlg.FileName -Leaf)."
        } catch {
            Write-Log "Import CSV error: $_" 'ERROR'
            $Script:ImpStatus.Text = "Could not read that file: $($_.Exception.Message)"
        }
    })

    $Script:ImpWin.FindName('ImpCancel').Add_Click({
        try { $Script:ImpWin.Close() }
        catch { Write-Log "Import cancel error: $_" 'ERROR' }
    })

    $Script:ImpWin.FindName('ImpOk').Add_Click({
        try {
            $upns = @(Get-EtbUpnsFromText $Script:ImpBox.Text)
            if ($upns.Count -eq 0) {
                $Script:ImpStatus.Text = 'No usernames recognised. Each one needs to look like name@domain.'
                return
            }
            $Script:ImpResult        = $upns
            $Script:ImpWin.DialogResult = $true
        } catch { Write-Log "Import confirm error: $_" 'ERROR' }
    })

    [void]$Script:ImpWin.ShowDialog()
    return @($Script:ImpResult)
}

# Splits a UPN list against a tool's loaded users. Returning the misses matters
# as much as the hits: a leaver already removed, or a typo in the spreadsheet,
# should be named rather than quietly dropped from the batch.
function Select-EtbUsersByUpn {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Users,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Upns
    )
    $byUpn = @{}
    foreach ($user in $Users) {
        if ($user.userPrincipalName) { $byUpn[$user.userPrincipalName.ToLower()] = $user }
    }
    $matched = [System.Collections.Generic.List[object]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($upn in $Upns) {
        $hit = $byUpn[$upn.ToLower()]
        if ($hit) { $matched.Add($hit) } else { $missing.Add($upn) }
    }
    [pscustomobject]@{ Matched = $matched.ToArray(); Missing = $missing.ToArray() }
}
