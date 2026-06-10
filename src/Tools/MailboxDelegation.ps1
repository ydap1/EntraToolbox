<#
    Mailbox Delegation tab for Art's Entra Toolbox.
    Dot-sourced by Start.ps1.
    Exposes Initialize-MailboxDelegationTool.

    Three sections:
      A. Send As    — static advisory (Exchange-only permission, link to EAC)
      B. Send on Behalf — Graph publicDelegates
      C. Read and Manage — EWS SOAP GetDelegate / AddDelegate / RemoveDelegate
#>

$Script:MD_UI           = $null
$Script:MD_AllUsers     = @()
$Script:MD_SelectedUser = $null

$Script:MD_UserTimer    = $null
$Script:MD_SobTimer     = $null
$Script:MD_EwsTimer     = $null
$Script:MD_ActionTimer  = $null

# Permission level display colour keys
$Script:MD_LevelColors = @{
    'None'     = '#50507A'
    'Reviewer' = '#9898B8'
    'Editor'   = '#6366F1'
    'Author'   = '#F59E0B'
    'Owner'    = '#22C55E'
}

# ── EWS SOAP helper ────────────────────────────────────────────────────────────
function Invoke-EwsRequest {
    param([string]$Token, [string]$Action, [string]$BodyXml)
    $envelope = @"
<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
  xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"
  xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
  <soap:Header>
    <t:RequestServerVersion Version="Exchange2016"/>
  </soap:Header>
  <soap:Body>
$BodyXml
  </soap:Body>
</soap:Envelope>
"@
    $resp = Invoke-WebRequest `
        -Uri 'https://outlook.office365.com/EWS/Exchange.asmx' `
        -Method POST `
        -Headers @{
            Authorization = "Bearer $Token"
            SOAPAction    = """http://schemas.microsoft.com/exchange/services/2006/messages/$Action"""
        } `
        -ContentType 'text/xml; charset=utf-8' `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($envelope))
    $xml = $resp.Content
    if ($xml -match '<faultstring>([^<]*)') { throw "EWS: $($Matches[1])" }
    return $xml
}

function Get-MdLevelHex([string]$Level) {
    if ($Script:MD_LevelColors.ContainsKey($Level)) { return $Script:MD_LevelColors[$Level] }
    return '#50507A'
}

# ── Log ────────────────────────────────────────────────────────────────────────
function Write-MdLog {
    param([string]$Msg, [string]$Color = 'TextDim')
    Write-AppLog $Msg $Color
}

# ── User load ──────────────────────────────────────────────────────────────────
function Start-MdUserLoad {
    if ($Script:DemoMode) { Start-MdUserLoadDemo; return }
    if (-not $Script:MD_UI) { return }

    $Script:MD_UI.UserSearch.IsEnabled = $false
    $Script:MD_UI.UserList.IsEnabled   = $false
    Write-MdLog 'Loading users...' 'TextDim'

    if ($Script:MD_UserTimer) { $Script:MD_UserTimer.Stop() }
    $Script:MD_UserTimer = Start-AsyncWork -RefSeed @{ Users = $null } -Script {
        $users = [System.Collections.Generic.List[object]]::new()
        $url   = 'https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName&$top=999&$filter=accountEnabled eq true'
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
            if ($ref['Error'] -eq '401') { Write-MdLog 'Session expired — reconnect.' 'Danger'; return }
            if ($ref['Error']) { Write-MdLog "Error loading users: $($ref['Error'])" 'Danger'; return }
            $Script:MD_AllUsers = @($ref['Users'] | Sort-Object { $_.displayName })
            Update-MdUserFilter
            $Script:MD_UI.UserSearch.IsEnabled = $true
            $Script:MD_UI.UserList.IsEnabled   = $true
            Write-MdLog "Loaded $($Script:MD_AllUsers.Count) users." 'Success'
        } catch { Write-Log "MD user-load error: $_" 'ERROR' }
    }
}

function Update-MdUserFilter {
    $filter = $Script:MD_UI.UserSearch.Text.Trim()
    $Script:MD_UI.UserList.Items.Clear()
    $list = if ([string]::IsNullOrWhiteSpace($filter)) { $Script:MD_AllUsers } else {
        $Script:MD_AllUsers | Where-Object {
            $_.displayName -like "*$filter*" -or $_.userPrincipalName -like "*$filter*"
        }
    }
    foreach ($u in $list) {
        $lbi         = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Content = $u.displayName
        $lbi.Tag     = $u
        $lbi.ToolTip = $u.userPrincipalName
        [void]$Script:MD_UI.UserList.Items.Add($lbi)
    }
}

# ── Section B: Send on Behalf (publicDelegates) ────────────────────────────────
function Start-MdSendOnBehalfLoad {
    param([string]$UserId)
    if ($Script:DemoMode) { Start-MdSendOnBehalfLoadDemo; return }

    $Script:MD_UI.SobGrid.ItemsSource    = $null
    $Script:MD_UI.SobStatus.Text         = 'Loading...'

    if ($Script:MD_SobTimer) { $Script:MD_SobTimer.Stop() }
    $Script:MD_SobTimer = Start-AsyncWork `
        -Vars    @{ UserId = $UserId } `
        -RefSeed @{ Delegates = $null; NotFound = $false } `
        -Script {
            try {
                $resp = Invoke-RestMethod `
                    -Uri "https://graph.microsoft.com/v1.0/users/$UserId/publicDelegates" `
                    -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
                $Ref['Delegates'] = $resp.value
            } catch {
                if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 404) {
                    $Ref['NotFound']  = $true
                    $Ref['Delegates'] = @()
                } else { throw }
            }
        } -OnComplete {
            param($ref)
            try {
                if ($ref['Error']) { $Script:MD_UI.SobStatus.Text = "Error: $($ref['Error'])"; return }
                $delegates = @($ref['Delegates'])
                if ($ref['NotFound'] -or $delegates.Count -eq 0) {
                    $Script:MD_UI.SobStatus.Text = 'No Send on Behalf delegates.'
                    $Script:MD_UI.SobGrid.ItemsSource = $null
                    return
                }
                $items = $delegates | ForEach-Object {
                    [PSCustomObject]@{
                        DisplayName = $_.displayName
                        UPN         = $_.userPrincipalName
                        DelegateId  = $_.id
                    }
                }
                $Script:MD_UI.SobGrid.ItemsSource = @($items)
                $Script:MD_UI.SobStatus.Text      = ''
            } catch { Write-Log "MD SOB load error: $_" 'ERROR' }
        }
}

function Start-MdSobAdd {
    param([string]$DelegateId)
    if (-not $Script:MD_SelectedUser) { return }
    $userId = $Script:MD_SelectedUser.id
    if ($Script:DryMode) {
        Write-MdLog "[DRY] Would add Send on Behalf delegate $DelegateId to $($Script:MD_SelectedUser.displayName)" 'Warning'
        return
    }
    Write-MdLog "Adding Send on Behalf delegate..." 'TextDim'
    if ($Script:MD_ActionTimer) { $Script:MD_ActionTimer.Stop() }
    $Script:MD_ActionTimer = Start-AsyncWork `
        -Vars    @{ UserId = $userId; DelegateId = $DelegateId } `
        -RefSeed @{ Ok = $false } `
        -Script {
            $body = '{"@odata.id":"https://graph.microsoft.com/v1.0/users/' + $DelegateId + '"}'
            Invoke-RestMethod `
                -Uri "https://graph.microsoft.com/v1.0/users/$UserId/publicDelegates/`$ref" `
                -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } `
                -Method POST -Body $body -ErrorAction Stop
            $Ref['Ok'] = $true
        } -OnComplete {
            param($ref)
            try {
                if ($ref['Error']) { Write-MdLog "Add failed: $($ref['Error'])" 'Danger'; return }
                Write-MdLog "Send on Behalf delegate added." 'Success'
                $Script:MD_UI.SobAddSearch.Text = ''
                $Script:MD_UI.SobAddResults.Visibility = 'Collapsed'
                Start-MdSendOnBehalfLoad -UserId $Script:MD_SelectedUser.id
            } catch { Write-Log "MD SOB add error: $_" 'ERROR' }
        }
}

function Start-MdSobRemove {
    param([string]$DelegateId)
    if (-not $Script:MD_SelectedUser) { return }
    $userId = $Script:MD_SelectedUser.id
    if ($Script:DryMode) {
        Write-MdLog "[DRY] Would remove Send on Behalf delegate $DelegateId" 'Warning'
        return
    }
    Write-MdLog "Removing Send on Behalf delegate..." 'TextDim'
    if ($Script:MD_ActionTimer) { $Script:MD_ActionTimer.Stop() }
    $Script:MD_ActionTimer = Start-AsyncWork `
        -Vars    @{ UserId = $userId; DelegateId = $DelegateId } `
        -RefSeed @{ Ok = $false } `
        -Script {
            Invoke-RestMethod `
                -Uri "https://graph.microsoft.com/v1.0/users/$UserId/publicDelegates/$DelegateId/`$ref" `
                -Headers @{ Authorization = "Bearer $Token" } `
                -Method DELETE -ErrorAction Stop
            $Ref['Ok'] = $true
        } -OnComplete {
            param($ref)
            try {
                if ($ref['Error']) { Write-MdLog "Remove failed: $($ref['Error'])" 'Danger'; return }
                Write-MdLog "Send on Behalf delegate removed." 'Success'
                Start-MdSendOnBehalfLoad -UserId $Script:MD_SelectedUser.id
            } catch { Write-Log "MD SOB remove error: $_" 'ERROR' }
        }
}

function Update-MdSobAddFilter {
    $q = $Script:MD_UI.SobAddSearch.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($q)) {
        $Script:MD_UI.SobAddResults.Visibility = 'Collapsed'
        return
    }
    $matches = @($Script:MD_AllUsers | Where-Object {
        $_.displayName -like "*$q*" -or $_.userPrincipalName -like "*$q*"
    } | Select-Object -First 8)

    $Script:MD_UI.SobAddResults.Items.Clear()
    if ($matches.Count -eq 0) { $Script:MD_UI.SobAddResults.Visibility = 'Collapsed'; return }
    foreach ($u in $matches) {
        $lbi         = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Content = "$($u.displayName)  ($($u.userPrincipalName))"
        $lbi.Tag     = $u
        [void]$Script:MD_UI.SobAddResults.Items.Add($lbi)
    }
    $Script:MD_UI.SobAddResults.Visibility = 'Visible'
}

# ── Section C: Read and Manage (EWS) ──────────────────────────────────────────
function Start-MdEwsLoad {
    param([string]$OwnerUpn)
    if ($Script:DemoMode) { Start-MdEwsLoadDemo; return }

    $Script:MD_UI.EwsGrid.ItemsSource = $null
    $Script:MD_UI.EwsStatus.Text      = 'Loading… (may open browser for Exchange consent on first use)'

    if ($Script:MD_EwsTimer) { $Script:MD_EwsTimer.Stop() }
    $Script:MD_EwsTimer = Start-AsyncWork `
        -Vars    @{ OwnerUpn = $OwnerUpn } `
        -RefSeed @{ Token = $null; Xml = $null } `
        -NoToken `
        -Script {
            $ewsToken = Get-ExchangeToken
            $Ref['Token'] = $ewsToken
            $body = @"
    <m:GetDelegate IncludePermissions="true">
      <m:Mailbox><t:EmailAddress>$OwnerUpn</t:EmailAddress></m:Mailbox>
    </m:GetDelegate>
"@
            $Ref['Xml'] = Invoke-EwsRequest -Token $ewsToken -Action 'GetDelegate' -BodyXml $body
        } -OnComplete {
            param($ref)
            try {
                if ($ref['Error']) {
                    $Script:MD_UI.EwsStatus.Text = "Error: $($ref['Error'])"
                    return
                }
                $xml = $ref['Xml']
                $delegates = [System.Collections.Generic.List[PSCustomObject]]::new()
                $blocks = [regex]::Matches($xml, '<t:DelegateUser>(.*?)</t:DelegateUser>', 'Singleline')
                foreach ($block in $blocks) {
                    $b       = $block.Groups[1].Value
                    $email   = if ($b -match '<t:PrimarySmtpAddress>([^<]+)') { $Matches[1] } else { '' }
                    $name    = if ($b -match '<t:DisplayName>([^<]+)')        { $Matches[1] } else { $email }
                    $inbox   = if ($b -match '<t:InboxFolderPermissionLevel>([^<]+)')    { $Matches[1] } else { 'None' }
                    $cal     = if ($b -match '<t:CalendarFolderPermissionLevel>([^<]+)') { $Matches[1] } else { 'None' }
                    $cont    = if ($b -match '<t:ContactsFolderPermissionLevel>([^<]+)') { $Matches[1] } else { 'None' }
                    $tasks   = if ($b -match '<t:TasksFolderPermissionLevel>([^<]+)')    { $Matches[1] } else { 'None' }
                    $delegates.Add([PSCustomObject]@{
                        DisplayName = $name
                        Email       = $email
                        Inbox       = $inbox
                        Calendar    = $cal
                        Contacts    = $cont
                        Tasks       = $tasks
                    })
                }
                $Script:MD_UI.EwsGrid.ItemsSource = $delegates
                $Script:MD_UI.EwsStatus.Text = if ($delegates.Count -eq 0) { 'No full-access delegates.' } else { '' }
                # Store EWS token for later add/remove actions
                $Script:MD_UI._EwsToken = $ref['Token']
            } catch { Write-Log "MD EWS load error: $_" 'ERROR' }
        }
}

function Start-MdEwsAdd {
    param([string]$DelegateEmail)
    if (-not $Script:MD_SelectedUser -or [string]::IsNullOrWhiteSpace($DelegateEmail)) { return }
    $ownerUpn = $Script:MD_SelectedUser.userPrincipalName
    if ($Script:DryMode) {
        Write-MdLog "[DRY] Would add EWS delegate $DelegateEmail to $ownerUpn" 'Warning'
        return
    }
    Write-MdLog "Adding full-access delegate $DelegateEmail..." 'TextDim'
    if ($Script:MD_ActionTimer) { $Script:MD_ActionTimer.Stop() }
    $Script:MD_ActionTimer = Start-AsyncWork `
        -Vars    @{ OwnerUpn = $ownerUpn; DelegateEmail = $DelegateEmail } `
        -RefSeed @{ Ok = $false } `
        -NoToken `
        -Script {
            $ewsToken = Get-ExchangeToken
            $body = @"
    <m:AddDelegate>
      <m:Mailbox><t:EmailAddress>$OwnerUpn</t:EmailAddress></m:Mailbox>
      <m:DelegateUsers>
        <t:DelegateUser>
          <t:UserId><t:PrimarySmtpAddress>$DelegateEmail</t:PrimarySmtpAddress></t:UserId>
          <t:DelegatePermissions>
            <t:CalendarFolderPermissionLevel>Editor</t:CalendarFolderPermissionLevel>
            <t:InboxFolderPermissionLevel>Editor</t:InboxFolderPermissionLevel>
            <t:ContactsFolderPermissionLevel>Reviewer</t:ContactsFolderPermissionLevel>
            <t:TasksFolderPermissionLevel>None</t:TasksFolderPermissionLevel>
            <t:NotesFolderPermissionLevel>None</t:NotesFolderPermissionLevel>
            <t:JournalFolderPermissionLevel>None</t:JournalFolderPermissionLevel>
          </t:DelegatePermissions>
          <t:ReceiveCopiesOfMeetingMessages>false</t:ReceiveCopiesOfMeetingMessages>
          <t:ViewPrivateItems>false</t:ViewPrivateItems>
        </t:DelegateUser>
      </m:DelegateUsers>
    </m:AddDelegate>
"@
            Invoke-EwsRequest -Token $ewsToken -Action 'AddDelegate' -BodyXml $body | Out-Null
            $Ref['Ok'] = $true
        } -OnComplete {
            param($ref)
            try {
                if ($ref['Error']) { Write-MdLog "Add delegate failed: $($ref['Error'])" 'Danger'; return }
                Write-MdLog "Full-access delegate added." 'Success'
                $Script:MD_UI.EwsAddEmail.Text = ''
                Start-MdEwsLoad -OwnerUpn $Script:MD_SelectedUser.userPrincipalName
            } catch { Write-Log "MD EWS add error: $_" 'ERROR' }
        }
}

function Start-MdEwsRemove {
    param([string]$DelegateEmail)
    if (-not $Script:MD_SelectedUser) { return }
    $ownerUpn = $Script:MD_SelectedUser.userPrincipalName
    if ($Script:DryMode) {
        Write-MdLog "[DRY] Would remove EWS delegate $DelegateEmail from $ownerUpn" 'Warning'
        return
    }
    Write-MdLog "Removing full-access delegate $DelegateEmail..." 'TextDim'
    if ($Script:MD_ActionTimer) { $Script:MD_ActionTimer.Stop() }
    $Script:MD_ActionTimer = Start-AsyncWork `
        -Vars    @{ OwnerUpn = $ownerUpn; DelegateEmail = $DelegateEmail } `
        -RefSeed @{ Ok = $false } `
        -NoToken `
        -Script {
            $ewsToken = Get-ExchangeToken
            $body = @"
    <m:RemoveDelegate>
      <m:Mailbox><t:EmailAddress>$OwnerUpn</t:EmailAddress></m:Mailbox>
      <m:UserIds>
        <t:UserId><t:PrimarySmtpAddress>$DelegateEmail</t:PrimarySmtpAddress></t:UserId>
      </m:UserIds>
    </m:RemoveDelegate>
"@
            Invoke-EwsRequest -Token $ewsToken -Action 'RemoveDelegate' -BodyXml $body | Out-Null
            $Ref['Ok'] = $true
        } -OnComplete {
            param($ref)
            try {
                if ($ref['Error']) { Write-MdLog "Remove delegate failed: $($ref['Error'])" 'Danger'; return }
                Write-MdLog "Full-access delegate removed." 'Success'
                Start-MdEwsLoad -OwnerUpn $Script:MD_SelectedUser.userPrincipalName
            } catch { Write-Log "MD EWS remove error: $_" 'ERROR' }
        }
}

# ── Demo stubs ────────────────────────────────────────────────────────────────
function Start-MdUserLoadDemo {
    $Script:MD_AllUsers = @($Script:Demo_Users | Select-Object -First 15)
    Update-MdUserFilter
    $Script:MD_UI.UserSearch.IsEnabled = $true
    $Script:MD_UI.UserList.IsEnabled   = $true
    Write-MdLog 'Demo: loaded users.' 'Muted'
}

function Start-MdSendOnBehalfLoadDemo {
    $items = @(
        [PSCustomObject]@{ DisplayName = 'Zara Ahmed'; UPN = 'zara.ahmed@contoso.sch.uk'; DelegateId = 'u-y11-02' }
    )
    $Script:MD_UI.SobGrid.ItemsSource = $items
    $Script:MD_UI.SobStatus.Text      = ''
}

function Start-MdEwsLoadDemo {
    $items = @(
        [PSCustomObject]@{
            DisplayName = 'Connor Burke'
            Email       = 'connor.burke@contoso.sch.uk'
            Inbox       = 'Editor'
            Calendar    = 'Editor'
            Contacts    = 'Reviewer'
            Tasks       = 'None'
        }
    )
    $Script:MD_UI.EwsGrid.ItemsSource = $items
    $Script:MD_UI.EwsStatus.Text      = ''
}

# ── XAML ───────────────────────────────────────────────────────────────────────
$Script:MdXaml = @'
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

    <Style TargetType="TextBox">
      <Setter Property="Background"               Value="#242436"/>
      <Setter Property="Foreground"               Value="#E2E2F0"/>
      <Setter Property="BorderBrush"              Value="#3C3C5A"/>
      <Setter Property="BorderThickness"          Value="1"/>
      <Setter Property="Padding"                  Value="8,4"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="CaretBrush"               Value="#E2E2F0"/>
      <Setter Property="FocusVisualStyle"         Value="{x:Null}"/>
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
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ListBox">
      <Setter Property="Background"      Value="#12121C"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding"         Value="0"/>
    </Style>

    <Style TargetType="ListBoxItem">
      <Setter Property="Foreground"                 Value="#E2E2F0"/>
      <Setter Property="Background"                 Value="Transparent"/>
      <Setter Property="Padding"                    Value="12,7"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Cursor"                     Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    Padding="{TemplateBinding Padding}">
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

  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="260" MinWidth="200"/>
    <ColumnDefinition Width="5"/>
    <ColumnDefinition Width="*"/>
  </Grid.ColumnDefinitions>

  <GridSplitter Grid.Column="1" Width="5" HorizontalAlignment="Stretch"
                Background="#3C3C5A" Cursor="SizeWE" ResizeBehavior="PreviousAndNext"/>

  <!-- Left: user picker -->
  <Border Grid.Column="0" Background="#1C1C2A">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <Border Grid.Row="0" Padding="12,10" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1">
        <StackPanel>
          <TextBlock Text="MAILBOX OWNER" Foreground="#50507A" FontSize="10" FontWeight="Bold" Margin="0,0,0,8"/>
          <TextBox x:Name="MdUserSearch" IsEnabled="False" Height="34"/>
        </StackPanel>
      </Border>
      <ListBox x:Name="MdUserList" Grid.Row="1" IsEnabled="False"
               ScrollViewer.HorizontalScrollBarVisibility="Disabled"
               VirtualizingPanel.IsVirtualizing="True"
               VirtualizingPanel.VirtualizationMode="Recycling"
               Margin="0,2,0,2"/>
    </Grid>
  </Border>

  <!-- Right: three sections stacked -->
  <ScrollViewer Grid.Column="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
    <StackPanel>

      <!-- Section A: Send As (static advisory) -->
      <Border Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1" Margin="0,0,0,1">
        <StackPanel Margin="18,14">
          <TextBlock Text="SEND AS" Foreground="#50507A" FontSize="10" FontWeight="Bold" Margin="0,0,0,10"/>
          <Border Background="#2B1E00" BorderBrush="#F59E0B" BorderThickness="1" CornerRadius="4" Padding="12,10" Margin="0,0,0,10">
            <TextBlock Foreground="#F59E0B" FontSize="12" TextWrapping="Wrap"
                       Text="Send As is an Exchange-level permission and cannot be configured via any Microsoft API. It must be set in Exchange Admin Center."/>
          </Border>
          <Button x:Name="MdBtnEac" Content="Open Exchange Admin Center"
                  Style="{StaticResource PrimaryBtn}" Background="#3C3C5A"
                  Padding="12,7" FontSize="12" HorizontalAlignment="Left"/>
        </StackPanel>
      </Border>

      <!-- Section B: Send on Behalf -->
      <Border Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1" Margin="0,0,0,1">
        <StackPanel Margin="18,14">
          <TextBlock Text="SEND ON BEHALF" Foreground="#50507A" FontSize="10" FontWeight="Bold" Margin="0,0,0,10"/>
          <TextBlock x:Name="MdSobStatus" Foreground="#7878A0" FontSize="12"
                     Text="Select a user." Margin="0,0,0,6" TextWrapping="Wrap"/>
          <DataGrid x:Name="MdSobGrid" Height="160"
                    AutoGenerateColumns="False" IsReadOnly="False"
                    CanUserAddRows="False" CanUserDeleteRows="False"
                    CanUserReorderColumns="False" CanUserResizeRows="False"
                    SelectionMode="Single" HeadersVisibility="Column"
                    RowBackground="#12121C" AlternatingRowBackground="#14171C"
                    GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#1E1E32"
                    Background="#12121C" BorderThickness="1" BorderBrush="#3C3C5A"
                    Foreground="#E2E2F0" Margin="0,0,0,10"
                    ColumnHeaderStyle="{StaticResource DgHdr}"
                    CellStyle="{StaticResource DgCell}"
                    RowStyle="{StaticResource DgRow}"
                    RowHeight="34">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Display Name" Binding="{Binding DisplayName}" Width="*" IsReadOnly="True"/>
              <DataGridTextColumn Header="UPN" Binding="{Binding UPN}" Width="200" IsReadOnly="True"/>
              <DataGridTemplateColumn Header="" Width="90" IsReadOnly="True">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate>
                    <Button Content="Remove" Tag="{Binding DelegateId}"
                            Background="#EF4444" Foreground="White"
                            FontSize="11" FontWeight="SemiBold" Padding="8,4"
                            BorderThickness="0" Cursor="Hand" Margin="4,4"/>
                  </DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
            </DataGrid.Columns>
          </DataGrid>

          <!-- Add delegate search -->
          <TextBlock Text="Add delegate — search by name or UPN:" Foreground="#7878A0" FontSize="11" Margin="0,0,0,4"/>
          <Grid>
            <TextBox x:Name="MdSobAddSearch" Height="32" FontSize="12"/>
          </Grid>
          <Border x:Name="MdSobAddResults" Background="#21262E" BorderBrush="#3C3C5A"
                  BorderThickness="1" CornerRadius="0,0,4,4" MaxHeight="160"
                  Visibility="Collapsed" Margin="0,0,0,4">
            <ListBox x:Name="MdSobAddList" Background="Transparent" BorderThickness="0"
                     ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
          </Border>
        </StackPanel>
      </Border>

      <!-- Section C: Read and Manage (EWS) -->
      <Border Background="#1C1C2A" Margin="0,0,0,1">
        <StackPanel Margin="18,14">
          <TextBlock Text="READ AND MANAGE (FULL ACCESS)" Foreground="#50507A" FontSize="10" FontWeight="Bold" Margin="0,0,0,10"/>
          <TextBlock x:Name="MdEwsStatus" Foreground="#7878A0" FontSize="12"
                     Text="Select a user." Margin="0,0,0,6" TextWrapping="Wrap"/>
          <DataGrid x:Name="MdEwsGrid" Height="180"
                    AutoGenerateColumns="False" IsReadOnly="False"
                    CanUserAddRows="False" CanUserDeleteRows="False"
                    CanUserReorderColumns="False" CanUserResizeRows="False"
                    SelectionMode="Single" HeadersVisibility="Column"
                    RowBackground="#12121C" AlternatingRowBackground="#14171C"
                    GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#1E1E32"
                    Background="#12121C" BorderThickness="1" BorderBrush="#3C3C5A"
                    Foreground="#E2E2F0" Margin="0,0,0,10"
                    ColumnHeaderStyle="{StaticResource DgHdr}"
                    CellStyle="{StaticResource DgCell}"
                    RowStyle="{StaticResource DgRow}"
                    RowHeight="34">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Delegate" Binding="{Binding DisplayName}" Width="*" IsReadOnly="True"/>
              <DataGridTextColumn Header="Inbox"    Binding="{Binding Inbox}"       Width="80" IsReadOnly="True"/>
              <DataGridTextColumn Header="Calendar" Binding="{Binding Calendar}"    Width="80" IsReadOnly="True"/>
              <DataGridTextColumn Header="Contacts" Binding="{Binding Contacts}"    Width="80" IsReadOnly="True"/>
              <DataGridTextColumn Header="Tasks"    Binding="{Binding Tasks}"       Width="70" IsReadOnly="True"/>
              <DataGridTemplateColumn Header="" Width="90" IsReadOnly="True">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate>
                    <Button Content="Remove" Tag="{Binding Email}"
                            Background="#EF4444" Foreground="White"
                            FontSize="11" FontWeight="SemiBold" Padding="8,4"
                            BorderThickness="0" Cursor="Hand" Margin="4,4"/>
                  </DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
            </DataGrid.Columns>
          </DataGrid>

          <!-- Add EWS delegate -->
          <TextBlock Text="Add delegate — enter email address:" Foreground="#7878A0" FontSize="11" Margin="0,0,0,4"/>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="8"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="MdEwsAddEmail" Grid.Column="0" Height="32" FontSize="12"/>
            <Button x:Name="MdBtnEwsAdd" Grid.Column="2" Content="Add Delegate"
                    Style="{StaticResource PrimaryBtn}" Background="#6366F1"
                    Padding="12,7" FontSize="12"/>
          </Grid>
          <TextBlock Foreground="#50507A" FontSize="10" Margin="0,6,0,4" TextWrapping="Wrap"
                     Text="Permissions set: Inbox — Editor, Calendar — Editor, Contacts — Reviewer, Tasks — None"/>
        </StackPanel>
      </Border>

    </StackPanel>
  </ScrollViewer>

</Grid>
'@

# ── Initialize ─────────────────────────────────────────────────────────────────
function Initialize-MailboxDelegationTool {
    $reader  = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new((Invoke-ThemeXaml $Script:MdXaml)))
    $content = [System.Windows.Markup.XamlReader]::Load($reader)

    $Script:MD_UI = @{
        UserSearch     = $content.FindName('MdUserSearch')
        UserList       = $content.FindName('MdUserList')
        BtnEac         = $content.FindName('MdBtnEac')
        SobGrid        = $content.FindName('MdSobGrid')
        SobStatus      = $content.FindName('MdSobStatus')
        SobAddSearch   = $content.FindName('MdSobAddSearch')
        SobAddResults  = $content.FindName('MdSobAddResults')
        SobAddList     = $content.FindName('MdSobAddList')
        EwsGrid        = $content.FindName('MdEwsGrid')
        EwsStatus      = $content.FindName('MdEwsStatus')
        EwsAddEmail    = $content.FindName('MdEwsAddEmail')
        BtnEwsAdd      = $content.FindName('MdBtnEwsAdd')
        _EwsToken      = $null
    }

    $Script:MD_UI.UserSearch.Add_TextChanged({
        try { Update-MdUserFilter }
        catch { Write-Log "MD UserSearch error: $_" 'ERROR' }
    })

    $Script:MD_UI.UserList.Add_SelectionChanged({
        try {
            $sel = $Script:MD_UI.UserList.SelectedItem
            if (-not $sel) { return }
            $Script:MD_SelectedUser = $sel.Tag
            Write-Log "MD: selected $($Script:MD_SelectedUser.displayName)" 'DEBUG'
            Start-MdSendOnBehalfLoad -UserId $Script:MD_SelectedUser.id
            Start-MdEwsLoad -OwnerUpn $Script:MD_SelectedUser.userPrincipalName
        } catch { Write-Log "MD UserList SelectionChanged error: $_" 'ERROR' }
    })

    $Script:MD_UI.BtnEac.Add_Click({
        try { Start-Process 'https://admin.exchange.microsoft.com' }
        catch { Write-Log "MD BtnEac error: $_" 'ERROR' }
    })

    # SOB add-search filter
    $Script:MD_UI.SobAddSearch.Add_TextChanged({
        try { Update-MdSobAddFilter }
        catch { Write-Log "MD SobAddSearch error: $_" 'ERROR' }
    })

    # SOB add-results click
    $Script:MD_UI.SobAddList.Add_MouseLeftButtonUp({
        try {
            $sel = $Script:MD_UI.SobAddList.SelectedItem
            if (-not $sel) { return }
            Start-MdSobAdd -DelegateId $sel.Tag.id
        } catch { Write-Log "MD SobAddList click error: $_" 'ERROR' }
    })

    # SOB grid Remove button
    $Script:MD_UI.SobGrid.AddHandler(
        [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
        [System.Windows.RoutedEventHandler]{
            param($s, $e)
            if ($e.OriginalSource -is [System.Windows.Controls.Button]) {
                $delId = $e.OriginalSource.Tag
                if ($delId) { Start-MdSobRemove -DelegateId $delId }
            }
        }
    )

    # EWS grid Remove button
    $Script:MD_UI.EwsGrid.AddHandler(
        [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
        [System.Windows.RoutedEventHandler]{
            param($s, $e)
            if ($e.OriginalSource -is [System.Windows.Controls.Button]) {
                $email = $e.OriginalSource.Tag
                if ($email) { Start-MdEwsRemove -DelegateEmail $email }
            }
        }
    )

    $Script:MD_UI.BtnEwsAdd.Add_Click({
        try {
            $email = $Script:MD_UI.EwsAddEmail.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($email)) { return }
            Start-MdEwsAdd -DelegateEmail $email
        } catch { Write-Log "MD BtnEwsAdd click error: $_" 'ERROR' }
    })

    Register-ConnectCallback 'Start-MdUserLoad'
    $Script:ResetCallbacks.Add({
        $Script:MD_AllUsers     = @()
        $Script:MD_SelectedUser = $null
        $Script:MD_UI.UserSearch.Text      = ''
        $Script:MD_UI.UserSearch.IsEnabled = $false
        $Script:MD_UI.UserList.Items.Clear()
        $Script:MD_UI.UserList.IsEnabled   = $false
        $Script:MD_UI.SobGrid.ItemsSource  = $null
        $Script:MD_UI.SobStatus.Text       = 'Select a user.'
        $Script:MD_UI.EwsGrid.ItemsSource  = $null
        $Script:MD_UI.EwsStatus.Text       = 'Select a user.'
        $Script:MD_UI.SobAddSearch.Text    = ''
        $Script:MD_UI.SobAddResults.Visibility = 'Collapsed'
        $Script:MD_UI.EwsAddEmail.Text     = ''
    })

    Write-MdLog 'Mailbox Delegation ready. Select a tenant to begin.' 'Muted'
    return $content
}
