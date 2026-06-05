<#
    Immutable ID tab for Art's Entra Toolbox.
    Dot-sourced by Start.ps1.
    Exposes Initialize-ImmutableIdTool.

    Generates and assigns onPremisesImmutableId (Base64 of a fresh GUID) to
    cloud-only users. Cloud-synced accounts are excluded — their ImmutableId is
    managed by Azure AD Connect.

    Common use-case: anchor cloud-only accounts before enabling AD Connect sync,
    so Connect matches on ImmutableId rather than UPN.
#>

$Script:IID_UI         = $null
$Script:IID_AllUsers   = @()
$Script:IID_Rows       = New-Object System.Collections.ObjectModel.ObservableCollection[PSObject]
$Script:IID_LoadRef    = $null
$Script:IID_LoadTimer  = $null
$Script:IID_ApplyRef   = $null
$Script:IID_ApplyTimer = $null

function Write-IidLog {
    param([string]$Msg, [string]$Color = 'TextDim')
    if (-not $Script:IID_UI) { Write-Log $Msg 'DEBUG'; return }
    $ts   = Get-Date -Format 'HH:mm:ss'
    $para = New-Object System.Windows.Documents.Paragraph
    $run  = New-Object System.Windows.Documents.Run "[$ts]  $Msg"
    $run.Foreground = Get-ThemeHex $Color
    $para.Inlines.Add($run)
    $para.Margin = '0'
    $Script:IID_UI.LogBox.Document.Blocks.Add($para)
    $Script:IID_UI.LogBox.ScrollToEnd()
}

function New-ImmutableIdValue {
    [Convert]::ToBase64String([System.Guid]::NewGuid().ToByteArray())
}

function Rebuild-IidRows {
    $emptyOnly = $Script:IID_UI.ChkEmptyOnly.IsChecked -eq $true
    $Script:IID_Rows.Clear()
    foreach ($u in $Script:IID_AllUsers) {
        $hasId = -not [string]::IsNullOrEmpty($u.onPremisesImmutableId)
        if ($emptyOnly -and $hasId) { continue }
        $row = [PSCustomObject]@{
            Id          = $u.id
            Name        = $u.displayName
            Upn         = $u.userPrincipalName
            CurrentId   = if ($hasId) { $u.onPremisesImmutableId } else { '(none)' }
            NewId       = ''
            HasExisting = $hasId
            Status      = 'Pending'
        }
        [void]$Script:IID_Rows.Add($row)
    }
    Update-IidButtons
}

function Invoke-IidGenerate {
    $overwrite = $Script:IID_UI.ChkOverwrite.IsChecked -eq $true
    $generated = 0
    foreach ($r in $Script:IID_Rows) {
        if ($r.Status -ne 'Pending') { continue }
        if ($r.HasExisting -and -not $overwrite) { continue }
        $r.NewId = New-ImmutableIdValue
        $generated++
    }
    $Script:IID_UI.PreviewGrid.Items.Refresh()
    Update-IidButtons
    Write-IidLog "Generated $generated new ImmutableId value(s)." 'Success'
}

function Update-IidButtons {
    $readyCount = ($Script:IID_Rows | Where-Object { $_.Status -eq 'Pending' -and $_.NewId -ne '' }).Count
    $Script:IID_UI.BtnApply.IsEnabled    = $readyCount -gt 0
    $Script:IID_UI.BtnGenerate.IsEnabled = $Script:IID_Rows.Count -gt 0
    $Script:IID_UI.LblCount.Text = if ($Script:IID_Rows.Count -gt 0) {
        "$($Script:IID_Rows.Count) user(s) shown  ·  $readyCount ready to apply"
    } else { '' }
}

# ── Async load ─────────────────────────────────────────────────────────────────
function Start-IidLoad {
    if ($Script:DemoMode) { Start-IidLoadDemo; return }

    $Script:IID_UI.BtnGenerate.IsEnabled = $false
    $Script:IID_UI.BtnApply.IsEnabled    = $false
    $Script:IID_UI.LblCount.Text         = 'Loading...'
    Write-IidLog 'Loading cloud-only users...' 'TextDim'

    $Script:IID_LoadRef = [hashtable]::Synchronized(@{
        Done  = $false
        Users = $null
        Error = $null
    })
    $token = $Script:AccessToken

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Ref',   $Script:IID_LoadRef)
    $rs.SessionStateProxy.SetVariable('Token', $token)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        try {
            $users = [System.Collections.Generic.List[object]]::new()
            $url   = 'https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName,onPremisesImmutableId,onPremisesSyncEnabled&$top=999&$filter=accountEnabled eq true'
            do {
                $resp = Invoke-RestMethod -Uri $url `
                    -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
                foreach ($u in $resp.value) {
                    if (-not $u.onPremisesSyncEnabled) { $users.Add($u) }
                }
                $url = $resp.'@odata.nextLink'
            } while ($url)
            $Ref['Users'] = $users.ToArray()
        } catch {
            $sc = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode.value__ } else { 0 }
            $Ref['Error'] = if ($sc -eq 401) { '401' } else { $_.Exception.Message }
        } finally { $Ref['Done'] = $true }
    })
    $ps.BeginInvoke() | Out-Null

    if ($Script:IID_LoadTimer) { $Script:IID_LoadTimer.Stop() }
    $Script:IID_LoadTimer          = [System.Windows.Threading.DispatcherTimer]::new()
    $Script:IID_LoadTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $Script:IID_LoadTimer.Add_Tick({
        try {
            if (-not $Script:IID_LoadRef['Done']) { return }
            $Script:IID_LoadTimer.Stop()

            if ($Script:IID_LoadRef['Error'] -eq '401') {
                Write-IidLog 'Session expired — reconnect.' 'Danger'
                Set-MainStatus 'Session expired.' 'Danger'
                $Script:IID_UI.LblCount.Text = ''
                return
            }
            if ($Script:IID_LoadRef['Error']) {
                Write-IidLog "Load error: $($Script:IID_LoadRef['Error'])" 'Danger'
                $Script:IID_UI.LblCount.Text = ''
                return
            }

            $Script:IID_AllUsers = @($Script:IID_LoadRef['Users'] | Sort-Object { $_.displayName })
            $withId    = ($Script:IID_AllUsers | Where-Object { $_.onPremisesImmutableId }).Count
            $withoutId = $Script:IID_AllUsers.Count - $withId
            Rebuild-IidRows

            Write-IidLog "Loaded $($Script:IID_AllUsers.Count) cloud-only user(s): $withId already have an ImmutableId, $withoutId do not." 'Success'
            Set-MainStatus "IID: $($Script:IID_AllUsers.Count) users loaded." 'Success'
        } catch {
            Write-Log "IID load-timer error: $_" 'ERROR'
        }
    })
    $Script:IID_LoadTimer.Start()
}

# ── Async apply ─────────────────────────────────────────────────────────────────
function Start-IidApply {
    $ready = @($Script:IID_Rows | Where-Object { $_.Status -eq 'Pending' -and $_.NewId -ne '' })
    $token = $Script:AccessToken

    $Script:IID_UI.BtnApply.IsEnabled    = $false
    $Script:IID_UI.BtnGenerate.IsEnabled = $false
    Write-IidLog "Assigning ImmutableId to $($ready.Count) user(s)..." 'TextDim'

    $Script:IID_ApplyRef = [hashtable]::Synchronized(@{
        Done    = $false
        Results = [System.Collections.Generic.List[hashtable]]::new()
    })

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Ref',   $Script:IID_ApplyRef)
    $rs.SessionStateProxy.SetVariable('Token', $token)
    $rs.SessionStateProxy.SetVariable('Ready', $ready)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        foreach ($r in $Ready) {
            $res = @{ Id = $r.Id; Upn = $r.Upn; NewId = $r.NewId; Ok = $false; Err = '' }
            try {
                $escaped = $r.NewId -replace '\\','\\' -replace '"','\"'
                $body    = "{`"onPremisesImmutableId`":`"$escaped`"}"
                Invoke-RestMethod `
                    -Uri "https://graph.microsoft.com/v1.0/users/$($r.Id)" `
                    -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } `
                    -Method PATCH -Body $body -ErrorAction Stop
                $res['Ok'] = $true
            } catch {
                $res['Err'] = $_.Exception.Message
            }
            $Ref['Results'].Add($res)
        }
        $Ref['Done'] = $true
    })
    $ps.BeginInvoke() | Out-Null

    if ($Script:IID_ApplyTimer) { $Script:IID_ApplyTimer.Stop() }
    $Script:IID_ApplyTimer          = [System.Windows.Threading.DispatcherTimer]::new()
    $Script:IID_ApplyTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $Script:IID_ApplyTimer.Add_Tick({
        try {
            if (-not $Script:IID_ApplyRef['Done']) { return }
            $Script:IID_ApplyTimer.Stop()

            $ok = 0; $fail = 0
            foreach ($res in $Script:IID_ApplyRef['Results']) {
                $row = $Script:IID_Rows | Where-Object { $_.Id -eq $res['Id'] } | Select-Object -First 1
                if ($res['Ok']) {
                    $ok++
                    Write-IidLog "Assigned: $($res['Upn'])  =  $($res['NewId'])" 'Success'
                    if ($row) { $row.Status = 'Done'; $row.CurrentId = $row.NewId; $row.NewId = '' }
                } else {
                    $fail++
                    Write-IidLog "Failed: $($res['Upn']) — $($res['Err'])" 'Danger'
                    if ($row) { $row.Status = 'Error' }
                }
            }
            $Script:IID_UI.PreviewGrid.Items.Refresh()
            $summary = "Done — assigned: $ok  failed: $fail"
            Write-IidLog $summary 'Text'
            Set-MainStatus $summary (if ($fail -gt 0) { 'Warning' } else { 'Success' })
            $Script:IID_UI.BtnGenerate.IsEnabled = $true
            Update-IidButtons
        } catch {
            Write-Log "IID apply-timer error: $_" 'ERROR'
        }
    })
    $Script:IID_ApplyTimer.Start()
}

# ── Demo stubs ─────────────────────────────────────────────────────────────────
function Start-IidLoadDemo {
    $Script:IID_AllUsers = @(
        [PSCustomObject]@{ id='d1'; displayName='Alice Smith';  userPrincipalName='alice@contoso.edu';  onPremisesImmutableId=$null;          onPremisesSyncEnabled=$false }
        [PSCustomObject]@{ id='d2'; displayName='Bob Jones';    userPrincipalName='bob@contoso.edu';    onPremisesImmutableId='AAAA+mocked1='; onPremisesSyncEnabled=$false }
        [PSCustomObject]@{ id='d3'; displayName='Carol White';  userPrincipalName='carol@contoso.edu';  onPremisesImmutableId=$null;          onPremisesSyncEnabled=$false }
        [PSCustomObject]@{ id='d4'; displayName='Dave Black';   userPrincipalName='dave@contoso.edu';   onPremisesImmutableId=$null;          onPremisesSyncEnabled=$false }
        [PSCustomObject]@{ id='d5'; displayName='Eve Green';    userPrincipalName='eve@contoso.edu';    onPremisesImmutableId='BBBB+mocked2='; onPremisesSyncEnabled=$false }
    )
    Rebuild-IidRows
    Write-IidLog "Demo: loaded $($Script:IID_AllUsers.Count) users (2 have existing ImmutableId)." 'Success'
}

function Start-IidApplyDemo {
    $ready = @($Script:IID_Rows | Where-Object { $_.Status -eq 'Pending' -and $_.NewId -ne '' })
    Write-IidLog "Demo: simulating ImmutableId assignment for $($ready.Count) user(s)..." 'TextDim'
    foreach ($r in $ready) {
        Write-IidLog "Demo assigned: $($r.Upn)  =  $($r.NewId)" 'Success'
        $r.Status = 'Done'; $r.CurrentId = $r.NewId; $r.NewId = ''
    }
    $Script:IID_UI.PreviewGrid.Items.Refresh()
    Write-IidLog 'Demo complete.' 'Text'
    $Script:IID_UI.BtnGenerate.IsEnabled = $true
    Update-IidButtons
}

# ── XAML ───────────────────────────────────────────────────────────────────────
$Script:IidXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
      Background="#12121C">
  <Grid.Resources>

    <SolidColorBrush x:Key="Bg"      Color="#12121C"/>
    <SolidColorBrush x:Key="Surface" Color="#1C1C2A"/>
    <SolidColorBrush x:Key="Card"    Color="#242436"/>
    <SolidColorBrush x:Key="Border"  Color="#3C3C5A"/>
    <SolidColorBrush x:Key="Accent"  Color="#6366F1"/>
    <SolidColorBrush x:Key="Text"    Color="#E2E2F0"/>
    <SolidColorBrush x:Key="TextDim" Color="#7878A0"/>
    <SolidColorBrush x:Key="Muted"   Color="#50507A"/>

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

    <Style TargetType="CheckBox">
      <Setter Property="Foreground"  Value="#E2E2F0"/>
      <Setter Property="FontSize"    Value="12"/>
      <Setter Property="Cursor"      Value="Hand"/>
      <Setter Property="Margin"      Value="0,0,20,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>

    <Style TargetType="DataGrid">
      <Setter Property="Background"               Value="#12121C"/>
      <Setter Property="Foreground"               Value="#E2E2F0"/>
      <Setter Property="BorderThickness"          Value="0"/>
      <Setter Property="GridLinesVisibility"      Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#1E1E32"/>
      <Setter Property="RowBackground"            Value="#12121C"/>
      <Setter Property="AlternatingRowBackground" Value="#181826"/>
      <Setter Property="ColumnHeaderHeight"       Value="34"/>
      <Setter Property="RowHeight"                Value="28"/>
      <Setter Property="AutoGenerateColumns"      Value="False"/>
      <Setter Property="CanUserAddRows"           Value="False"/>
      <Setter Property="CanUserDeleteRows"        Value="False"/>
      <Setter Property="IsReadOnly"               Value="True"/>
      <Setter Property="SelectionMode"            Value="Extended"/>
      <Setter Property="SelectionUnit"            Value="FullRow"/>
      <Setter Property="CanUserSortColumns"       Value="True"/>
      <Setter Property="FontSize"                 Value="12"/>
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

  </Grid.Resources>

  <Grid.RowDefinitions>
    <RowDefinition Height="Auto"/>
    <RowDefinition Height="*"/>
    <RowDefinition Height="170"/>
  </Grid.RowDefinitions>

  <!-- ── Toolbar ──────────────────────────────────────────────────────────── -->
  <Border Grid.Row="0" Background="#1C1C2A" BorderBrush="#3C3C5A"
          BorderThickness="0,0,0,1" Padding="16,14">
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="8"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>

      <!-- Filter options and count label -->
      <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
        <CheckBox x:Name="IidChkEmptyOnly" IsChecked="True"
                  ToolTip="Only show users who have no ImmutableId yet">
          <TextBlock Text="Skip users with an existing ImmutableId" Foreground="#E2E2F0" FontSize="12"/>
        </CheckBox>
        <CheckBox x:Name="IidChkOverwrite" IsChecked="False" Margin="0,0,24,0"
                  ToolTip="Also generate new IDs for users that already have one">
          <TextBlock Text="Overwrite existing ImmutableIds" Foreground="#FBBF24" FontSize="12"/>
        </CheckBox>
        <TextBlock x:Name="IidLblCount" Foreground="#50507A" FontSize="11"
                   VerticalAlignment="Center"/>
      </StackPanel>

      <Button x:Name="IidBtnGenerate" Grid.Column="1" Content="Generate IDs"
              Style="{StaticResource PrimaryBtn}" Background="#6366F1"
              Padding="16,8" IsEnabled="False"
              ToolTip="Fill the New ImmutableId column with fresh Base64(GUID) values"/>
      <Button x:Name="IidBtnApply" Grid.Column="3" Content="Assign ImmutableIds"
              Style="{StaticResource PrimaryBtn}" Background="#F59E0B"
              Padding="18,8" IsEnabled="False"
              ToolTip="Write the generated IDs to Entra ID for all ready rows"/>
    </Grid>
  </Border>

  <!-- ── DataGrid ────────────────────────────────────────────────────────── -->
  <DataGrid x:Name="IidPreviewGrid" Grid.Row="1" Margin="0">
    <DataGrid.Columns>
      <DataGridTextColumn Header="Display Name"        Binding="{Binding Name}"      Width="180"/>
      <DataGridTextColumn Header="UPN"                 Binding="{Binding Upn}"       Width="*"/>
      <DataGridTextColumn Header="Current ImmutableId" Binding="{Binding CurrentId}" Width="200"/>
      <DataGridTextColumn Header="New ImmutableId"     Binding="{Binding NewId}"     Width="200"/>
      <DataGridTextColumn Header="Status"              Binding="{Binding Status}"    Width="70"/>
    </DataGrid.Columns>
  </DataGrid>

  <!-- ── Log ─────────────────────────────────────────────────────────────── -->
  <Border Grid.Row="2" BorderBrush="#3C3C5A" BorderThickness="0,1,0,0">
    <RichTextBox x:Name="IidLogBox" Background="#0F1115" Foreground="#7878A0"
                 BorderThickness="0" IsReadOnly="True" FontFamily="Consolas" FontSize="12"
                 Padding="12" VerticalScrollBarVisibility="Auto"/>
  </Border>

</Grid>
'@

# ── Initialize ─────────────────────────────────────────────────────────────────
function Initialize-ImmutableIdTool {
    $reader  = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new((Invoke-ThemeXaml $Script:IidXaml)))
    $content = [System.Windows.Markup.XamlReader]::Load($reader)

    $Script:IID_UI = @{
        ChkEmptyOnly = $content.FindName('IidChkEmptyOnly')
        ChkOverwrite = $content.FindName('IidChkOverwrite')
        LblCount     = $content.FindName('IidLblCount')
        BtnGenerate  = $content.FindName('IidBtnGenerate')
        BtnApply     = $content.FindName('IidBtnApply')
        PreviewGrid  = $content.FindName('IidPreviewGrid')
        LogBox       = $content.FindName('IidLogBox')
    }

    $Script:IID_UI.PreviewGrid.ItemsSource = $Script:IID_Rows

    $Script:IID_UI.ChkEmptyOnly.Add_Checked({
        try { Rebuild-IidRows }
        catch { Write-Log "IID ChkEmptyOnly Checked error: $_" 'ERROR' }
    })
    $Script:IID_UI.ChkEmptyOnly.Add_Unchecked({
        try { Rebuild-IidRows }
        catch { Write-Log "IID ChkEmptyOnly Unchecked error: $_" 'ERROR' }
    })

    $Script:IID_UI.BtnGenerate.Add_Click({
        try { Invoke-IidGenerate }
        catch { Write-Log "IID BtnGenerate click error: $_" 'ERROR' }
    })

    $Script:IID_UI.BtnApply.Add_Click({
        try {
            $ready = @($Script:IID_Rows | Where-Object { $_.Status -eq 'Pending' -and $_.NewId -ne '' })
            if ($ready.Count -eq 0) { return }

            $overwriting = @($ready | Where-Object { $_.HasExisting })
            $overwriteWarn = if ($overwriting.Count -gt 0) {
                "`n`nWarning: $($overwriting.Count) user(s) already have an ImmutableId — these will be overwritten."
            } else { '' }

            $msg = "You are about to assign onPremisesImmutableId to $($ready.Count) user(s).$overwriteWarn`n`n" +
                   "Consequences:`n" +
                   "  • Once set, ImmutableId cannot be removed without support escalation`n" +
                   "  • Changing a value on an account already linked via AD Connect will break sync`n" +
                   "  • Use this only to anchor cloud-only accounts before enabling AD Connect`n`n" +
                   "Proceed?"
            $result = [System.Windows.MessageBox]::Show(
                $msg, 'Confirm ImmutableId Assignment',
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning)
            if ($result -ne [System.Windows.MessageBoxResult]::Yes) { return }

            if ($Script:DemoMode) { Start-IidApplyDemo; return }
            Start-IidApply
        } catch { Write-Log "IID BtnApply click error: $_" 'ERROR' }
    })

    $Script:ConnectCallbacks.Add({ Start-IidLoad })
    $Script:ResetCallbacks.Add({
        $Script:IID_AllUsers = @()
        $Script:IID_Rows.Clear()
        $Script:IID_UI.LblCount.Text         = ''
        $Script:IID_UI.BtnGenerate.IsEnabled = $false
        $Script:IID_UI.BtnApply.IsEnabled    = $false
    })

    Write-IidLog 'Immutable ID ready. Connect to a tenant to begin.' 'Muted'
    return $content
}
