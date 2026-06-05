<#
    Teams Provisioning tab for Art's Entra Toolbox.
    Dot-sourced by Start.ps1.
    Exposes Initialize-TeamsProvisioningTool.
#>

$Script:TP_UI          = $null
$Script:TP_AllUsers    = @()
$Script:TP_Rows        = New-Object System.Collections.ObjectModel.ObservableCollection[PSObject]
$Script:TP_Creating    = $false
$Script:TP_UserTimer   = $null
$Script:TP_CreateTimer = $null

function Write-TpLog {
    param([string]$Msg, [string]$Color = 'TextDim')
    # Write-RichLog falls back to console when LogBox is $null (e.g. UI not yet built).
    Write-RichLog $Script:TP_UI.LogBox $Msg $Color
}

function Update-TpCreateButton {
    $nameOk  = -not [string]::IsNullOrWhiteSpace($Script:TP_UI.TeamName.Text)
    $hasRows = $Script:TP_Rows.Count -gt 0
    $Script:TP_UI.BtnCreate.IsEnabled = ($nameOk -and $hasRows -and -not $Script:TP_Creating)
}

function Update-TpSelectionLabel {
    $sel   = $Script:TP_UI.Grid.SelectedItems.Count
    $total = $Script:TP_Rows.Count
    $Script:TP_UI.LblSelection.Text = if ($total -gt 0) { "$sel of $total members" } else { '' }
}

function Update-TpSearchFilter {
    $q = $Script:TP_UI.Search.Text.Trim().ToLower()
    $Script:TP_UI.SearchList.Items.Clear()
    if ([string]::IsNullOrWhiteSpace($q) -or $Script:TP_AllUsers.Count -eq 0) { return }

    $existingIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($r in $Script:TP_Rows) { [void]$existingIds.Add($r.Id) }

    $matches = @($Script:TP_AllUsers |
        Where-Object { $_.displayName -like "*$q*" -or $_.userPrincipalName -like "*$q*" } |
        Where-Object { -not $existingIds.Contains($_.id) } |
        Select-Object -First 30)

    foreach ($u in $matches) {
        $lbi         = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Content = "$($u.displayName)  ($($u.userPrincipalName))"
        $lbi.Tag     = $u
        [void]$Script:TP_UI.SearchList.Items.Add($lbi)
    }
}

$Script:TpXaml = @'
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

    <Style x:Key="SectionLbl" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#50507A"/>
      <Setter Property="FontSize"   Value="10"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Margin"     Value="0,0,0,6"/>
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
                     IsOpen="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}}"
                     Placement="Bottom" PopupAnimation="Slide">
                <Border Background="#242436" BorderBrush="#3C3C5A" BorderThickness="1"
                        CornerRadius="0,0,4,4" MaxHeight="{TemplateBinding MaxDropDownHeight}">
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

    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="#E2E2F0"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Cursor"     Value="Hand"/>
      <Setter Property="Margin"     Value="0,4,0,0"/>
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
      <Setter Property="IsReadOnly"               Value="False"/>
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
              <Trigger Property="IsSelected" Value="True">
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

        <TextBlock Text="TEAM NAME" Style="{StaticResource SectionLbl}"/>
        <TextBox x:Name="TpTeamName" Background="#242436" Foreground="#E2E2F0"
                 BorderBrush="#3C3C5A" BorderThickness="1" Height="32"
                 Padding="8,0" VerticalContentAlignment="Center" CaretBrush="#E2E2F0"
                 Margin="0,0,0,14"/>

        <TextBlock Text="TEAM TYPE" Style="{StaticResource SectionLbl}"/>
        <RadioButton x:Name="TpRbClass"    Content="Class Team"    GroupName="tptype" IsChecked="True"/>
        <RadioButton x:Name="TpRbStandard" Content="Standard Team" GroupName="tptype"/>

        <Border Background="#3C3C5A" Height="1" Margin="0,14"/>

        <TextBlock Text="POPULATION" Style="{StaticResource SectionLbl}"/>
        <RadioButton x:Name="TpRbYearGroup" Content="Year Group"   GroupName="tppop" IsChecked="True"/>
        <RadioButton x:Name="TpRbDirect"    Content="Direct Users" GroupName="tppop" Margin="0,4,0,8"/>

        <StackPanel x:Name="TpPnlYearGroup">
          <ComboBox x:Name="TpCboYear" IsEnabled="False"/>
          <Button x:Name="TpBtnLoad" Content="Load Students" IsEnabled="False"
                  Style="{StaticResource PrimaryBtn}" Background="#242436"
                  Foreground="#7878A0" Padding="0,10" Margin="0,8,0,0"/>
        </StackPanel>

        <StackPanel x:Name="TpPnlDirect" Visibility="Collapsed">
          <TextBox x:Name="TpSearch" Background="#242436" Foreground="#E2E2F0"
                   BorderBrush="#3C3C5A" BorderThickness="1" Height="32"
                   Padding="8,0" VerticalContentAlignment="Center" CaretBrush="#E2E2F0"/>
          <Border Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="1"
                  CornerRadius="0,0,4,4" Margin="0,1,0,0" MaxHeight="160">
            <ListBox x:Name="TpSearchList" Background="Transparent" BorderThickness="0"
                     Foreground="#E2E2F0" ScrollViewer.VerticalScrollBarVisibility="Auto">
              <ListBox.ItemContainerStyle>
                <Style TargetType="ListBoxItem">
                  <Setter Property="Foreground" Value="#E2E2F0"/>
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
              </ListBox.ItemContainerStyle>
            </ListBox>
          </Border>
        </StackPanel>

        <Border Background="#3C3C5A" Height="1" Margin="0,14"/>

        <TextBlock Text="SELECTION" Style="{StaticResource SectionLbl}"/>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="4"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="4"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="TpLblSelection" Grid.Column="0"
                     Foreground="#50507A" FontSize="11" VerticalAlignment="Center"/>
          <Button x:Name="TpBtnSelectAll" Grid.Column="2" Content="All"
                  Style="{StaticResource PrimaryBtn}" Background="#242436"
                  Foreground="#7878A0" Padding="8,4" FontSize="11" IsEnabled="False"/>
          <Button x:Name="TpBtnSelectNone" Grid.Column="4" Content="None"
                  Style="{StaticResource PrimaryBtn}" Background="#242436"
                  Foreground="#7878A0" Padding="8,4" FontSize="11" IsEnabled="False"/>
        </Grid>

        <Border Background="#3C3C5A" Height="1" Margin="0,14"/>

        <TextBlock Text="ACTIONS" Style="{StaticResource SectionLbl}"/>
        <Button x:Name="TpBtnCreate" Content="Create Team" IsEnabled="False"
                Style="{StaticResource PrimaryBtn}" Background="#6366F1" Padding="0,10"/>

        <Border x:Name="TpPnlStats" CornerRadius="6" Background="#242436"
                Padding="14,12" Margin="0,14,0,0" Visibility="Collapsed">
          <StackPanel>
            <TextBlock x:Name="TpLblTeamStatus"    Text="Team   -" Foreground="#7878A0"
                       FontFamily="Consolas" FontSize="12"/>
            <TextBlock x:Name="TpLblMembersAdded"  Text="Added  -" Foreground="#22C55E"
                       FontFamily="Consolas" FontSize="12" Margin="0,4,0,0"/>
            <TextBlock x:Name="TpLblMembersFailed" Text="Failed -" Foreground="#7878A0"
                       FontFamily="Consolas" FontSize="12" Margin="0,4,0,0"/>
          </StackPanel>
        </Border>

      </StackPanel>
    </ScrollViewer>
  </Border>

  <!-- ── Right panel ─────────────────────────────────────────────── -->
  <TabControl Grid.Column="2">
    <TabControl.Template>
      <ControlTemplate TargetType="TabControl">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Border Grid.Row="0" Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
            <TabPanel IsItemsHost="True" Margin="8,0"/>
          </Border>
          <ContentPresenter Grid.Row="1" ContentSource="SelectedContent"/>
        </Grid>
      </ControlTemplate>
    </TabControl.Template>

    <TabItem Header="Members">
      <DataGrid x:Name="TpGrid"
                VirtualizingPanel.IsVirtualizing="True"
                VirtualizingPanel.VirtualizationMode="Recycling">
        <DataGrid.Columns>
          <DataGridTextColumn Header="Display Name"   Binding="{Binding DisplayName}" Width="*"    IsReadOnly="True" SortMemberPath="DisplayName"/>
          <DataGridTextColumn Header="Username (UPN)" Binding="{Binding UPN}"         Width="1.4*" IsReadOnly="True" SortMemberPath="UPN"/>
          <DataGridTextColumn Header="Department"     Binding="{Binding Department}"  Width="80"   IsReadOnly="True" SortMemberPath="Department"/>
          <DataGridCheckBoxColumn Header="Owner" Binding="{Binding IsOwner}" Width="70"/>
        </DataGrid.Columns>
      </DataGrid>
    </TabItem>

    <TabItem Header="Log">
      <RichTextBox x:Name="TpLogBox" Background="#12121C" Foreground="#7878A0"
                   BorderThickness="0" IsReadOnly="True" FontFamily="Consolas"
                   FontSize="12" Padding="12" VerticalScrollBarVisibility="Auto"
                   HorizontalScrollBarVisibility="Auto"/>
    </TabItem>
  </TabControl>
</Grid>
'@

function Start-TpUserLoad {
    if ($Script:DemoMode) { Start-TpUserLoadDemo; return }

    $Script:TP_UI.CboYear.Items.Clear()
    $Script:TP_UI.CboYear.IsEnabled = $false
    $Script:TP_UI.BtnLoad.IsEnabled = $false
    Set-MainStatus 'Teams: loading users...' 'TextDim'
    Write-TpLog 'Fetching users from Entra ID...' 'TextDim'

    if ($Script:TP_UserTimer) { $Script:TP_UserTimer.Stop() }
    $Script:TP_UserTimer = Start-AsyncWork -RefSeed @{ Users = $null } -Script {
        $users = [System.Collections.Generic.List[object]]::new()
        $url   = 'https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName,department&$filter=accountEnabled eq true&$top=999'
        do {
            $resp = Invoke-RestMethod -Uri $url `
                -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
            foreach ($u in $resp.value) { $users.Add($u) }
            $url = $resp.'@odata.nextLink'
        } while ($url)
        $Ref['Users'] = $users.ToArray()
    } -OnComplete {
        param($ref)
        try {
            if ($ref['Error']) {
                Write-Log "TP: user load failed - $($ref['Error'])" 'ERROR'
                Write-TpLog "Failed to load users: $($ref['Error'])" 'Danger'
                Set-MainStatus 'Teams: failed to load users.' 'Danger'
                return
            }

            $Script:TP_AllUsers = $ref['Users']
            Write-Log "TP: loaded $($Script:TP_AllUsers.Count) users" 'INFO'
            Write-TpLog "Loaded $($Script:TP_AllUsers.Count) enabled users." 'Success'

            $allGroups     = $Script:TP_AllUsers | ForEach-Object { Get-DeptGroup $_.department } |
                             Where-Object { $_ -ne $null } | Sort-Object -Unique
            $numericGroups = @($allGroups | Where-Object { $_ -is [int] }    | Sort-Object)
            $namedGroups   = @($allGroups | Where-Object { $_ -is [string] } | Sort-Object)

            $Script:TP_UI.CboYear.Items.Clear()
            foreach ($g in ($numericGroups + $namedGroups)) {
                $cnt   = ($Script:TP_AllUsers | Where-Object { (Get-DeptGroup $_.department) -eq $g }).Count
                $label = if ($g -is [int]) { "Year $g  -  $cnt users" } else { "$g  -  $cnt users" }
                $item  = New-Object System.Windows.Controls.ComboBoxItem
                $item.Content = $label
                $item.Tag     = $g
                $Script:TP_UI.CboYear.Items.Add($item) | Out-Null
            }
            if ($Script:TP_UI.CboYear.Items.Count -gt 0) { $Script:TP_UI.CboYear.SelectedIndex = 0 }
            $Script:TP_UI.CboYear.IsEnabled = $true
            $Script:TP_UI.BtnLoad.IsEnabled = $true
            Set-MainStatus "Teams: $($Script:TP_AllUsers.Count) users loaded." 'Success'
        } catch {
            Write-Log "TP user-load timer error: $_" 'ERROR'
        }
    }
}

function Start-TpCreateTeam {
    if ($Script:DemoMode) { Start-TpCreateDemo; return }

    # Commit any pending DataGrid edit (e.g. Owner checkbox still active)
    $Script:TP_UI.Grid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true) | Out-Null

    $teamName   = $Script:TP_UI.TeamName.Text.Trim()
    $isClass    = $Script:TP_UI.RbClass.IsChecked
    $template   = if ($isClass) { 'educationClass' } else { 'standard' }
    $adminUpn   = Get-TenantAccountHint -TenantId $Script:CurrentTenantId
    if (-not $adminUpn) {
        Write-TpLog 'Cannot create team: admin UPN not available. Disconnect and reconnect to refresh.' 'Danger'
        Set-MainStatus 'Team creation failed: admin UPN unavailable.' 'Danger'
        $Script:TP_Creating = $false
        Update-TpCreateButton
        return
    }
    $memberSnap = @($Script:TP_Rows | ForEach-Object {
        @{ Id = $_.Id; UPN = $_.UPN; DisplayName = $_.DisplayName; IsOwner = [bool]$_.IsOwner }
    })

    $Script:TP_Creating                    = $true
    $Script:TP_UI.BtnCreate.IsEnabled      = $false
    $Script:TP_UI.BtnLoad.IsEnabled        = $false
    $Script:TP_UI.BtnSelectAll.IsEnabled   = $false
    $Script:TP_UI.BtnSelectNone.IsEnabled  = $false
    $Script:TP_UI.PnlStats.Visibility      = 'Collapsed'
    Set-MainStatus "Creating team '$teamName'..." 'TextDim'
    Write-TpLog "Creating $template team: '$teamName'  ($($memberSnap.Count) members)" 'TextDim'

    if ($Script:TP_CreateTimer) { $Script:TP_CreateTimer.Stop() }
    $Script:TP_CreateTimer = Start-AsyncWork `
        -IntervalMs 500 `
        -Vars @{
            TeamName   = $teamName
            Template   = $template
            AdminUpn   = $adminUpn
            MemberSnap = $memberSnap
        } `
        -RefSeed @{
            TeamId      = $null
            MembersOk   = 0
            MembersFail = 0
            Log         = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        } `
        -Script {
            $headers = @{
                Authorization  = "Bearer $Token"
                'Content-Type' = 'application/json'
            }

            # Step 1 — POST /teams (returns 202 with Location header)
            $body = @{
                'template@odata.bind' = "https://graph.microsoft.com/v1.0/teamsTemplates('$Template')"
                displayName           = $TeamName
                members               = @(
                    @{
                        '@odata.type'     = '#microsoft.graph.aadUserConversationMember'
                        roles             = @('owner')
                        'user@odata.bind' = "https://graph.microsoft.com/v1.0/users('$AdminUpn')"
                    }
                )
            } | ConvertTo-Json -Depth 10

            $resp     = Invoke-WebRequest -Uri 'https://graph.microsoft.com/v1.0/teams' `
                            -Headers $headers -Method POST -Body $body -ErrorAction Stop
            $location = @($resp.Headers['Location'])[0]
            if (-not $location) { throw 'No Location header in 202 response' }
            if ($location -notmatch '^https?://') {
                if ($location -notmatch '^/v\d') { $location = "/v1.0$location" }
                $location = "https://graph.microsoft.com$location"
            }
            $Ref['Log'].Enqueue('Team provisioning started — polling for completion...')

            # Step 2 — Poll operation URL every 3 s (max 90 s)
            $teamId  = $null
            $polls   = 0
            do {
                Start-Sleep -Seconds 3
                $polls++
                $op = Invoke-RestMethod -Uri $location -Headers $headers -Method GET -ErrorAction Stop
                if ($op.status -eq 'succeeded') {
                    $teamId = $op.targetResourceId
                    $Ref['Log'].Enqueue("Team created. ID: $teamId")
                    break
                }
                if ($op.status -eq 'failed') {
                    throw "Provisioning failed: $($op.error.message)"
                }
                $Ref['Log'].Enqueue("Provisioning status: $($op.status) ($polls/30)")
            } while ($polls -lt 30)

            if (-not $teamId) { throw 'Timed out waiting for team provisioning (90 s). Check Teams admin centre.' }
            $Ref['TeamId'] = $teamId

            # Step 3 — Add members one by one
            $membersUrl = "https://graph.microsoft.com/v1.0/teams/$teamId/members"
            foreach ($m in $MemberSnap) {
                try {
                    $mBody = @{
                        '@odata.type'     = '#microsoft.graph.aadUserConversationMember'
                        roles             = @(if ($m.IsOwner) { 'owner' } else { })
                        'user@odata.bind' = "https://graph.microsoft.com/v1.0/users('$($m.UPN)')"
                    } | ConvertTo-Json -Depth 5
                    Invoke-RestMethod -Uri $membersUrl -Headers $headers `
                        -Method POST -Body $mBody -ErrorAction Stop | Out-Null
                    $Ref['MembersOk']++
                    $role = if ($m.IsOwner) { 'Owner' } else { 'Member' }
                    $Ref['Log'].Enqueue("Added: $($m.DisplayName)  [$role]")
                } catch {
                    $Ref['MembersFail']++
                    $Ref['Log'].Enqueue("FAILED: $($m.DisplayName) - $($_.Exception.Message)")
                }
            }
        } -OnProgress {
            param($ref)
            # Real-time drain: surface each enqueued message as the worker produces them.
            $msg = $null
            while ($ref['Log'].TryDequeue([ref]$msg)) {
                $color = if ($msg -like 'FAILED:*') { 'Danger' } elseif ($msg -like 'Added:*') { 'Success' } else { 'TextDim' }
                Write-TpLog $msg $color
            }
        } -OnComplete {
            param($ref)
            try {
                $Script:TP_Creating = $false

                if ($ref['Error']) {
                    Write-Log "TP: creation failed - $($ref['Error'])" 'ERROR'
                    Write-TpLog "ERROR: $($ref['Error'])" 'Danger'
                    Set-MainStatus 'Team creation failed.' 'Danger'
                    $Script:TP_UI.LblTeamStatus.Text       = 'Team   FAILED'
                    $Script:TP_UI.LblTeamStatus.Foreground = (Get-ThemeHex 'Danger')
                } else {
                    $ok   = $ref['MembersOk']
                    $fail = $ref['MembersFail']
                    $col  = if ($fail -gt 0) { 'Warning' } else { 'Success' }
                    Write-Log "TP: done - $ok added, $fail failed" 'INFO'
                    Write-TpLog "Done — $ok members added, $fail failed." $col
                    Set-MainStatus "Team created: $ok added, $fail failed." $col
                    $Script:TP_UI.LblTeamStatus.Text       = 'Team   Created'
                    $Script:TP_UI.LblTeamStatus.Foreground = (Get-ThemeHex 'Success')
                    $Script:TP_UI.LblAdded.Text            = "Added  $ok"
                    $Script:TP_UI.LblFailed.Text           = "Failed $fail"
                    $Script:TP_UI.LblFailed.Foreground     = if ($fail -gt 0) { (Get-ThemeHex 'Danger') } else { (Get-ThemeHex 'TextDim') }
                }

                $Script:TP_UI.PnlStats.Visibility     = 'Visible'
                $Script:TP_UI.BtnLoad.IsEnabled       = $true
                $Script:TP_UI.BtnSelectAll.IsEnabled  = $true
                $Script:TP_UI.BtnSelectNone.IsEnabled = $true
                Update-TpCreateButton
            } catch {
                Write-Log "TP create timer error: $_" 'ERROR'
            }
        }
}

function Initialize-TeamsProvisioningTool {
    $reader  = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new((Invoke-ThemeXaml $Script:TpXaml)))
    $content = [System.Windows.Markup.XamlReader]::Load($reader)

    $Script:TP_UI = @{
        TeamName      = $content.FindName('TpTeamName')
        RbClass       = $content.FindName('TpRbClass')
        RbStandard    = $content.FindName('TpRbStandard')
        RbYearGroup   = $content.FindName('TpRbYearGroup')
        RbDirect      = $content.FindName('TpRbDirect')
        PnlYearGroup  = $content.FindName('TpPnlYearGroup')
        PnlDirect     = $content.FindName('TpPnlDirect')
        CboYear       = $content.FindName('TpCboYear')
        BtnLoad       = $content.FindName('TpBtnLoad')
        Search        = $content.FindName('TpSearch')
        SearchList    = $content.FindName('TpSearchList')
        LblSelection  = $content.FindName('TpLblSelection')
        BtnSelectAll  = $content.FindName('TpBtnSelectAll')
        BtnSelectNone = $content.FindName('TpBtnSelectNone')
        BtnCreate     = $content.FindName('TpBtnCreate')
        PnlStats      = $content.FindName('TpPnlStats')
        LblTeamStatus = $content.FindName('TpLblTeamStatus')
        LblAdded      = $content.FindName('TpLblMembersAdded')
        LblFailed     = $content.FindName('TpLblMembersFailed')
        Grid          = $content.FindName('TpGrid')
        LogBox        = $content.FindName('TpLogBox')
    }

    $Script:TP_UI.Grid.ItemsSource = $Script:TP_Rows

    # Team name change -> re-evaluate Create button
    $Script:TP_UI.TeamName.Add_TextChanged({
        try { Update-TpCreateButton } catch { Write-Log "TP TeamName TextChanged error: $_" 'ERROR' }
    })

    # Population mode: Year Group
    $Script:TP_UI.RbYearGroup.Add_Checked({
        try {
            $Script:TP_UI.PnlYearGroup.Visibility = 'Visible'
            $Script:TP_UI.PnlDirect.Visibility    = 'Collapsed'
        } catch { Write-Log "TP RbYearGroup Checked error: $_" 'ERROR' }
    })

    # Population mode: Direct Users
    $Script:TP_UI.RbDirect.Add_Checked({
        try {
            $Script:TP_UI.PnlDirect.Visibility    = 'Visible'
            $Script:TP_UI.PnlYearGroup.Visibility = 'Collapsed'
        } catch { Write-Log "TP RbDirect Checked error: $_" 'ERROR' }
    })

    # Load Students (year group mode)
    $Script:TP_UI.BtnLoad.Add_Click({
        try {
            $selItem = $Script:TP_UI.CboYear.SelectedItem
            if (-not $selItem) { return }
            $selGroup = $selItem.Tag
            Write-Log "TP: loading users for group $selGroup" 'INFO'

            $Script:TP_Rows.Clear()
            $members = @($Script:TP_AllUsers | Where-Object { (Get-DeptGroup $_.department) -eq $selGroup })
            foreach ($u in $members) {
                $Script:TP_Rows.Add([PSCustomObject]@{
                    Id          = $u.id
                    DisplayName = $u.displayName
                    UPN         = $u.userPrincipalName
                    Department  = $u.department
                    IsOwner     = $false
                })
            }
            $Script:TP_UI.Grid.SelectAll()
            $Script:TP_UI.BtnSelectAll.IsEnabled  = $true
            $Script:TP_UI.BtnSelectNone.IsEnabled = $true
            $Script:TP_UI.PnlStats.Visibility     = 'Collapsed'
            Update-TpSelectionLabel
            Update-TpCreateButton
            Write-TpLog "Loaded $($members.Count) users for group: $selGroup" 'TextDim'
            Set-MainStatus "Group $selGroup - $($members.Count) users loaded." 'TextDim'
        } catch { Write-Log "TP BtnLoad click error: $_" 'ERROR' }
    })

    # Direct user search — filter as user types
    $Script:TP_UI.Search.Add_TextChanged({
        try { Update-TpSearchFilter } catch { Write-Log "TP Search TextChanged error: $_" 'ERROR' }
    })

    # Double-click a search result to add it to the grid
    $Script:TP_UI.SearchList.Add_MouseDoubleClick({
        try {
            $sel = $Script:TP_UI.SearchList.SelectedItem
            if (-not $sel) { return }
            $u = $sel.Tag

            $existingIds = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($r in $Script:TP_Rows) { [void]$existingIds.Add($r.Id) }
            if ($existingIds.Contains($u.id)) { return }

            $Script:TP_Rows.Add([PSCustomObject]@{
                Id          = $u.id
                DisplayName = $u.displayName
                UPN         = $u.userPrincipalName
                Department  = $u.department
                IsOwner     = $false
            })
            $Script:TP_UI.BtnSelectAll.IsEnabled  = $true
            $Script:TP_UI.BtnSelectNone.IsEnabled = $true
            Update-TpSelectionLabel
            Update-TpCreateButton
            Update-TpSearchFilter
            Write-TpLog "Added: $($u.displayName)  ($($u.userPrincipalName))" 'TextDim'
        } catch { Write-Log "TP SearchList DoubleClick error: $_" 'ERROR' }
    })

    # Create Team button
    $Script:TP_UI.BtnCreate.Add_Click({
        try { Start-TpCreateTeam } catch { Write-Log "TP BtnCreate click error: $_" 'ERROR' }
    })

    # Select All / None
    $Script:TP_UI.BtnSelectAll.Add_Click({
        try { $Script:TP_UI.Grid.SelectAll() } catch { Write-Log "TP BtnSelectAll error: $_" 'ERROR' }
    })
    $Script:TP_UI.BtnSelectNone.Add_Click({
        try { $Script:TP_UI.Grid.UnselectAll() } catch { Write-Log "TP BtnSelectNone error: $_" 'ERROR' }
    })

    # Grid selection -> update label
    $Script:TP_UI.Grid.Add_SelectionChanged({
        try { Update-TpSelectionLabel } catch { Write-Log "TP Grid SelectionChanged error: $_" 'ERROR' }
    })

    # Connect / reset callbacks
    Register-ConnectCallback 'Start-TpUserLoad'
    $Script:ResetCallbacks.Add({
        if ($Script:TP_UserTimer)  { $Script:TP_UserTimer.Stop() }
        if ($Script:TP_CreateTimer) { $Script:TP_CreateTimer.Stop() }
        $Script:TP_Rows.Clear()
        $Script:TP_AllUsers                    = @()
        $Script:TP_Creating                    = $false
        $Script:TP_UI.TeamName.Text            = ''
        $Script:TP_UI.CboYear.Items.Clear()
        $Script:TP_UI.CboYear.IsEnabled        = $false
        $Script:TP_UI.BtnLoad.IsEnabled        = $false
        $Script:TP_UI.BtnCreate.IsEnabled      = $false
        $Script:TP_UI.BtnSelectAll.IsEnabled   = $false
        $Script:TP_UI.BtnSelectNone.IsEnabled  = $false
        $Script:TP_UI.LblSelection.Text        = ''
        $Script:TP_UI.PnlStats.Visibility      = 'Collapsed'
        $Script:TP_UI.Search.Text              = ''
        $Script:TP_UI.SearchList.Items.Clear()
        $Script:TP_UI.RbYearGroup.IsChecked    = $true
    })

    Write-TpLog 'Teams Provisioning ready. Select a tenant to begin.' 'Muted'
    return $content
}
