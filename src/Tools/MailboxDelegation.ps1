<#
    MailboxDelegation.ps1 — Mailbox Delegation tool for Art's Entra Toolbox.
    Dot-sourced by Start.ps1. Exposes Initialize-MailboxDelegationTool.

    Three sections per selected mailbox owner:
      A. Send As       — advisory + link to Exchange Admin Center (Graph cannot manage this)
      B. Send on Behalf — Graph /users/{id}/publicDelegates
      C. Full Access    — EWS SOAP GetDelegate / AddDelegate / RemoveDelegate
#>

$Script:MD_UI           = $null
$Script:MD_AllUsers     = @()
$Script:MD_SelectedUser = $null

$Script:MD_UserTimer  = $null
$Script:MD_SobTimer   = $null
$Script:MD_EwsTimer   = $null
$Script:MD_ActTimer   = $null

function Write-MdLog([string]$Msg, [string]$Color = 'TextDim') { Write-AppLog $Msg $Color }

# ── User load ──────────────────────────────────────────────────────────────────
function Start-MdUserLoad {
    if ($Script:DemoMode) { Start-MdUserLoadDemo; return }
    if (-not $Script:MD_UI) { return }
    $Script:MD_UI.UserSearch.IsEnabled = $false
    $Script:MD_UI.UserList.IsEnabled   = $false
    Write-MdLog 'Loading users...' 'TextDim'
    if ($Script:MD_UserTimer) { $Script:MD_UserTimer.Stop() }
    $Script:MD_UserTimer = Start-AsyncWork -RefSeed @{ Users = $null } -Script {
        $list = [System.Collections.Generic.List[object]]::new()
        $url  = 'https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName&$top=999&$filter=accountEnabled eq true'
        do {
            $r   = Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
            foreach ($u in $r.value) { $list.Add($u) }
            $url = $r.'@odata.nextLink'
        } while ($url)
        $Ref['Users'] = $list.ToArray()
    } -OnComplete {
        param($ref)
        try {
            if ($ref['Error'] -eq '401') { Write-MdLog 'Session expired — reconnect.' 'Danger'; return }
            if ($ref['Error'])           { Write-MdLog "Users: $($ref['Error'])" 'Danger'; return }
            $Script:MD_AllUsers = @($ref['Users'] | Sort-Object displayName)
            Update-MdUserFilter
            $Script:MD_UI.UserSearch.IsEnabled = $true
            $Script:MD_UI.UserList.IsEnabled   = $true
            Write-MdLog "Loaded $($Script:MD_AllUsers.Count) users." 'Success'
        } catch { Write-Log "MD user-load: $_" 'ERROR' }
    }
}

function Update-MdUserFilter {
    $q = $Script:MD_UI.UserSearch.Text.Trim()
    $Script:MD_UI.UserList.Items.Clear()
    $src = if ([string]::IsNullOrWhiteSpace($q)) { $Script:MD_AllUsers } else {
        $Script:MD_AllUsers | Where-Object { $_.displayName -like "*$q*" -or $_.userPrincipalName -like "*$q*" }
    }
    foreach ($u in $src) {
        $lbi         = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Content = $u.displayName
        $lbi.ToolTip = $u.userPrincipalName
        $lbi.Tag     = $u
        [void]$Script:MD_UI.UserList.Items.Add($lbi)
    }
}

# ── Section B: Send on Behalf ──────────────────────────────────────────────────
function Start-MdSobLoad {
    param([string]$UserId)
    if ($Script:DemoMode) { Start-MdSobLoadDemo; return }
    $Script:MD_UI.SobList.Items.Clear()
    $Script:MD_UI.SobStatus.Text         = 'Loading...'
    $Script:MD_UI.BtnSobRemove.IsEnabled = $false
    if ($Script:MD_SobTimer) { $Script:MD_SobTimer.Stop() }
    $Script:MD_SobTimer = Start-AsyncWork -Vars @{ UserId = $UserId } -RefSeed @{ Items = $null } -Script {
        try {
            $r = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$UserId/publicDelegates" `
                -Headers @{ Authorization = "Bearer $Token" } -Method GET -ErrorAction Stop
            $Ref['Items'] = $r.value
        } catch {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 404) {
                $Ref['Items'] = @()
            } else { throw }
        }
    } -OnComplete {
        param($ref)
        try {
            if ($ref['Error']) { $Script:MD_UI.SobStatus.Text = "Error: $($ref['Error'])"; return }
            $delegates = @($ref['Items'])
            $Script:MD_UI.SobList.Items.Clear()
            foreach ($d in $delegates) {
                $lbi         = [System.Windows.Controls.ListBoxItem]::new()
                $lbi.Content = "$($d.displayName)  ($($d.userPrincipalName))"
                $lbi.Tag     = $d.id
                [void]$Script:MD_UI.SobList.Items.Add($lbi)
            }
            $Script:MD_UI.SobStatus.Text = if ($delegates.Count -eq 0) {
                'No Send on Behalf delegates.'
            } else { "$($delegates.Count) delegate(s)" }
            Update-MdSobButtons
        } catch { Write-Log "MD SOB load: $_" 'ERROR' }
    }
}

function Update-MdSobButtons {
    $Script:MD_UI.BtnSobRemove.IsEnabled = ($null -ne $Script:MD_UI.SobList.SelectedItem)
}

function Update-MdSobSearch {
    $q = $Script:MD_UI.SobSearch.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($q)) {
        $Script:MD_UI.SobDropdown.Visibility = 'Collapsed'
        return
    }
    $hits = @($Script:MD_AllUsers | Where-Object {
        $_.displayName -like "*$q*" -or $_.userPrincipalName -like "*$q*"
    } | Select-Object -First 8)
    $Script:MD_UI.SobDropList.Items.Clear()
    if ($hits.Count -eq 0) { $Script:MD_UI.SobDropdown.Visibility = 'Collapsed'; return }
    foreach ($u in $hits) {
        $lbi         = [System.Windows.Controls.ListBoxItem]::new()
        $lbi.Content = "$($u.displayName)  ($($u.userPrincipalName))"
        $lbi.Tag     = $u
        [void]$Script:MD_UI.SobDropList.Items.Add($lbi)
    }
    $Script:MD_UI.SobDropdown.Visibility = 'Visible'
}

function Start-MdSobAdd {
    param([string]$DelegateId)
    if (-not $Script:MD_SelectedUser) { return }
    $userId = $Script:MD_SelectedUser.id
    if ($Script:DryMode) { Write-MdLog "[DRY] Would add SOB delegate to $($Script:MD_SelectedUser.displayName)" 'Warning'; return }
    Write-MdLog 'Adding Send on Behalf delegate...' 'TextDim'
    if ($Script:MD_ActTimer) { $Script:MD_ActTimer.Stop() }
    $Script:MD_ActTimer = Start-AsyncWork `
        -Vars @{ UserId = $userId; DelegateId = $DelegateId } `
        -RefSeed @{ Ok = $false } `
        -Script {
            $body = '{"@odata.id":"https://graph.microsoft.com/v1.0/users/' + $DelegateId + '"}'
            Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$UserId/publicDelegates/`$ref" `
                -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } `
                -Method POST -Body $body -ErrorAction Stop
            $Ref['Ok'] = $true
        } -OnComplete {
            param($ref)
            try {
                if ($ref['Error']) { Write-MdLog "Add failed: $($ref['Error'])" 'Danger'; return }
                Write-MdLog 'Send on Behalf delegate added.' 'Success'
                $Script:MD_UI.SobSearch.Text             = ''
                $Script:MD_UI.SobDropdown.Visibility     = 'Collapsed'
                Start-MdSobLoad -UserId $Script:MD_SelectedUser.id
            } catch { Write-Log "MD SOB add: $_" 'ERROR' }
        }
}

function Start-MdSobRemove {
    $sel = $Script:MD_UI.SobList.SelectedItem
    if (-not $sel -or -not $Script:MD_SelectedUser) { return }
    $delId  = $sel.Tag
    $userId = $Script:MD_SelectedUser.id
    if ($Script:DryMode) { Write-MdLog "[DRY] Would remove SOB delegate $($sel.Content)" 'Warning'; return }
    Write-MdLog 'Removing Send on Behalf delegate...' 'TextDim'
    $Script:MD_UI.BtnSobRemove.IsEnabled = $false
    if ($Script:MD_ActTimer) { $Script:MD_ActTimer.Stop() }
    $Script:MD_ActTimer = Start-AsyncWork `
        -Vars @{ UserId = $userId; DelegateId = $delId } `
        -RefSeed @{ Ok = $false } `
        -Script {
            Invoke-RestMethod `
                -Uri "https://graph.microsoft.com/v1.0/users/$UserId/publicDelegates/$DelegateId/`$ref" `
                -Headers @{ Authorization = "Bearer $Token" } -Method DELETE -ErrorAction Stop
            $Ref['Ok'] = $true
        } -OnComplete {
            param($ref)
            try {
                if ($ref['Error']) { Write-MdLog "Remove failed: $($ref['Error'])" 'Danger'; Update-MdSobButtons; return }
                Write-MdLog 'Send on Behalf delegate removed.' 'Success'
                Start-MdSobLoad -UserId $Script:MD_SelectedUser.id
            } catch { Write-Log "MD SOB remove: $_" 'ERROR' }
        }
}

# ── Section C: Full Access (EWS) ───────────────────────────────────────────────
# EWS token is acquired inline inside the background runspace — dot-sourced functions
# from the main session are not available in a background runspace.
function Start-MdEwsLoad {
    param([string]$OwnerUpn)
    if ($Script:DemoMode) { Start-MdEwsLoadDemo; return }
    $Script:MD_UI.EwsList.Items.Clear()
    $Script:MD_UI.EwsStatus.Text          = 'Loading... (Exchange consent may open on first use)'
    $Script:MD_UI.BtnEwsRemove.IsEnabled  = $false
    $msalApp = $Script:MsalApps[$Script:CurrentTenantId]
    if ($Script:MD_EwsTimer) { $Script:MD_EwsTimer.Stop() }
    $Script:MD_EwsTimer = Start-AsyncWork `
        -Vars @{ OwnerUpn = $OwnerUpn; MsalApp = $msalApp } `
        -RefSeed @{ Xml = $null } `
        -NoToken `
        -Script {
            $ewsScope = @('https://outlook.office365.com/EWS.AccessAsUser.All')
            $ewsTok   = $null
            $accts    = $MsalApp.GetAccountsAsync().GetAwaiter().GetResult()
            $acct     = $accts | Select-Object -First 1
            if ($acct) {
                try {
                    $r = $MsalApp.AcquireTokenSilent($ewsScope, $acct).ExecuteAsync().GetAwaiter().GetResult()
                    if ($r.AccessToken) { $ewsTok = $r.AccessToken }
                } catch {}
            }
            if (-not $ewsTok) {
                $r = $MsalApp.AcquireTokenInteractive($ewsScope).ExecuteAsync().GetAwaiter().GetResult()
                $ewsTok = $r.AccessToken
                if (-not $ewsTok) { throw 'Could not acquire Exchange token.' }
            }
            $soapBody = "<m:GetDelegate IncludePermissions=`"true`"><m:Mailbox><t:EmailAddress>$OwnerUpn</t:EmailAddress></m:Mailbox></m:GetDelegate>"
            $envelope = '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Header><t:RequestServerVersion Version="Exchange2016"/></soap:Header><soap:Body>' + $soapBody + '</soap:Body></soap:Envelope>'
            $resp = Invoke-WebRequest -Uri 'https://outlook.office365.com/EWS/Exchange.asmx' -Method POST `
                -Headers @{ Authorization = "Bearer $ewsTok"; SOAPAction = '"http://schemas.microsoft.com/exchange/services/2006/messages/GetDelegate"' } `
                -ContentType 'text/xml; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($envelope))
            if ($resp.Content -match '<faultstring>([^<]*)') { throw "EWS: $($Matches[1])" }
            $Ref['Xml'] = $resp.Content
        } -OnComplete {
            param($ref)
            try {
                if ($ref['Error']) { $Script:MD_UI.EwsStatus.Text = "Error: $($ref['Error'])"; return }
                $xml    = $ref['Xml']
                $blocks = [regex]::Matches($xml, '<t:DelegateUser>(.*?)</t:DelegateUser>', 'Singleline')
                $Script:MD_UI.EwsList.Items.Clear()
                foreach ($blk in $blocks) {
                    $b      = $blk.Groups[1].Value
                    $email  = if ($b -match '<t:PrimarySmtpAddress>([^<]+)') { $Matches[1] } else { '' }
                    $name   = if ($b -match '<t:DisplayName>([^<]+)')        { $Matches[1] } else { $email }
                    $inbox  = if ($b -match '<t:InboxFolderPermissionLevel>([^<]+)')    { $Matches[1] } else { 'None' }
                    $cal    = if ($b -match '<t:CalendarFolderPermissionLevel>([^<]+)') { $Matches[1] } else { 'None' }
                    $lbi         = [System.Windows.Controls.ListBoxItem]::new()
                    $lbi.Content = "$name  |  Inbox: $inbox   Calendar: $cal"
                    $lbi.ToolTip = $email
                    $lbi.Tag     = $email
                    [void]$Script:MD_UI.EwsList.Items.Add($lbi)
                }
                $count = $Script:MD_UI.EwsList.Items.Count
                $Script:MD_UI.EwsStatus.Text = if ($count -eq 0) { 'No full-access delegates.' } else { "$count delegate(s)" }
                Update-MdEwsButtons
            } catch { Write-Log "MD EWS load: $_" 'ERROR' }
        }
}

function Update-MdEwsButtons {
    $Script:MD_UI.BtnEwsRemove.IsEnabled = ($null -ne $Script:MD_UI.EwsList.SelectedItem)
}

function Start-MdEwsAdd {
    $email = $Script:MD_UI.EwsAddEmail.Text.Trim()
    if (-not $Script:MD_SelectedUser -or [string]::IsNullOrWhiteSpace($email)) { return }
    $ownerUpn = $Script:MD_SelectedUser.userPrincipalName
    if ($Script:DryMode) { Write-MdLog "[DRY] Would add full-access delegate $email to $ownerUpn" 'Warning'; return }
    Write-MdLog "Adding full-access delegate $email..." 'TextDim'
    $msalApp = $Script:MsalApps[$Script:CurrentTenantId]
    if ($Script:MD_ActTimer) { $Script:MD_ActTimer.Stop() }
    $Script:MD_ActTimer = Start-AsyncWork `
        -Vars @{ OwnerUpn = $ownerUpn; DelegateEmail = $email; MsalApp = $msalApp } `
        -RefSeed @{ Ok = $false } `
        -NoToken `
        -Script {
            $ewsScope = @('https://outlook.office365.com/EWS.AccessAsUser.All')
            $ewsTok   = $null
            $accts    = $MsalApp.GetAccountsAsync().GetAwaiter().GetResult()
            $acct     = $accts | Select-Object -First 1
            if ($acct) {
                try {
                    $r = $MsalApp.AcquireTokenSilent($ewsScope, $acct).ExecuteAsync().GetAwaiter().GetResult()
                    if ($r.AccessToken) { $ewsTok = $r.AccessToken }
                } catch {}
            }
            if (-not $ewsTok) {
                $r = $MsalApp.AcquireTokenInteractive($ewsScope).ExecuteAsync().GetAwaiter().GetResult()
                $ewsTok = $r.AccessToken
                if (-not $ewsTok) { throw 'Could not acquire Exchange token.' }
            }
            $soapBody = "<m:AddDelegate><m:Mailbox><t:EmailAddress>$OwnerUpn</t:EmailAddress></m:Mailbox><m:DelegateUsers><t:DelegateUser><t:UserId><t:PrimarySmtpAddress>$DelegateEmail</t:PrimarySmtpAddress></t:UserId><t:DelegatePermissions><t:CalendarFolderPermissionLevel>Editor</t:CalendarFolderPermissionLevel><t:InboxFolderPermissionLevel>Editor</t:InboxFolderPermissionLevel><t:ContactsFolderPermissionLevel>Reviewer</t:ContactsFolderPermissionLevel><t:TasksFolderPermissionLevel>None</t:TasksFolderPermissionLevel><t:NotesFolderPermissionLevel>None</t:NotesFolderPermissionLevel><t:JournalFolderPermissionLevel>None</t:JournalFolderPermissionLevel></t:DelegatePermissions><t:ReceiveCopiesOfMeetingMessages>false</t:ReceiveCopiesOfMeetingMessages><t:ViewPrivateItems>false</t:ViewPrivateItems></t:DelegateUser></m:DelegateUsers></m:AddDelegate>"
            $envelope = '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Header><t:RequestServerVersion Version="Exchange2016"/></soap:Header><soap:Body>' + $soapBody + '</soap:Body></soap:Envelope>'
            $resp = Invoke-WebRequest -Uri 'https://outlook.office365.com/EWS/Exchange.asmx' -Method POST `
                -Headers @{ Authorization = "Bearer $ewsTok"; SOAPAction = '"http://schemas.microsoft.com/exchange/services/2006/messages/AddDelegate"' } `
                -ContentType 'text/xml; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($envelope))
            if ($resp.Content -match '<faultstring>([^<]*)') { throw "EWS: $($Matches[1])" }
            $Ref['Ok'] = $true
        } -OnComplete {
            param($ref)
            try {
                if ($ref['Error']) { Write-MdLog "Add failed: $($ref['Error'])" 'Danger'; return }
                Write-MdLog 'Full-access delegate added.' 'Success'
                $Script:MD_UI.EwsAddEmail.Text = ''
                Start-MdEwsLoad -OwnerUpn $Script:MD_SelectedUser.userPrincipalName
            } catch { Write-Log "MD EWS add: $_" 'ERROR' }
        }
}

function Start-MdEwsRemove {
    $sel = $Script:MD_UI.EwsList.SelectedItem
    if (-not $sel -or -not $Script:MD_SelectedUser) { return }
    $delegateEmail = $sel.Tag
    $ownerUpn      = $Script:MD_SelectedUser.userPrincipalName
    if ($Script:DryMode) { Write-MdLog "[DRY] Would remove full-access delegate $delegateEmail" 'Warning'; return }
    Write-MdLog "Removing full-access delegate $delegateEmail..." 'TextDim'
    $Script:MD_UI.BtnEwsRemove.IsEnabled = $false
    $msalApp = $Script:MsalApps[$Script:CurrentTenantId]
    if ($Script:MD_ActTimer) { $Script:MD_ActTimer.Stop() }
    $Script:MD_ActTimer = Start-AsyncWork `
        -Vars @{ OwnerUpn = $ownerUpn; DelegateEmail = $delegateEmail; MsalApp = $msalApp } `
        -RefSeed @{ Ok = $false } `
        -NoToken `
        -Script {
            $ewsScope = @('https://outlook.office365.com/EWS.AccessAsUser.All')
            $ewsTok   = $null
            $accts    = $MsalApp.GetAccountsAsync().GetAwaiter().GetResult()
            $acct     = $accts | Select-Object -First 1
            if ($acct) {
                try {
                    $r = $MsalApp.AcquireTokenSilent($ewsScope, $acct).ExecuteAsync().GetAwaiter().GetResult()
                    if ($r.AccessToken) { $ewsTok = $r.AccessToken }
                } catch {}
            }
            if (-not $ewsTok) {
                $r = $MsalApp.AcquireTokenInteractive($ewsScope).ExecuteAsync().GetAwaiter().GetResult()
                $ewsTok = $r.AccessToken
                if (-not $ewsTok) { throw 'Could not acquire Exchange token.' }
            }
            $soapBody = "<m:RemoveDelegate><m:Mailbox><t:EmailAddress>$OwnerUpn</t:EmailAddress></m:Mailbox><m:UserIds><t:UserId><t:PrimarySmtpAddress>$DelegateEmail</t:PrimarySmtpAddress></t:UserId></m:UserIds></m:RemoveDelegate>"
            $envelope = '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Header><t:RequestServerVersion Version="Exchange2016"/></soap:Header><soap:Body>' + $soapBody + '</soap:Body></soap:Envelope>'
            $resp = Invoke-WebRequest -Uri 'https://outlook.office365.com/EWS/Exchange.asmx' -Method POST `
                -Headers @{ Authorization = "Bearer $ewsTok"; SOAPAction = '"http://schemas.microsoft.com/exchange/services/2006/messages/RemoveDelegate"' } `
                -ContentType 'text/xml; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($envelope))
            if ($resp.Content -match '<faultstring>([^<]*)') { throw "EWS: $($Matches[1])" }
            $Ref['Ok'] = $true
        } -OnComplete {
            param($ref)
            try {
                if ($ref['Error']) { Write-MdLog "Remove failed: $($ref['Error'])" 'Danger'; Update-MdEwsButtons; return }
                Write-MdLog 'Full-access delegate removed.' 'Success'
                Start-MdEwsLoad -OwnerUpn $Script:MD_SelectedUser.userPrincipalName
            } catch { Write-Log "MD EWS remove: $_" 'ERROR' }
        }
}

# ── Demo stubs ────────────────────────────────────────────────────────────────
function Start-MdUserLoadDemo {
    $Script:MD_AllUsers = @($Script:Demo_Users | Select-Object -First 15)
    Update-MdUserFilter
    $Script:MD_UI.UserSearch.IsEnabled = $true
    $Script:MD_UI.UserList.IsEnabled   = $true
    Write-MdLog 'Demo: users loaded.' 'Muted'
}

function Start-MdSobLoadDemo {
    $Script:MD_UI.SobList.Items.Clear()
    $lbi         = [System.Windows.Controls.ListBoxItem]::new()
    $lbi.Content = 'Zara Ahmed  (zara.ahmed@contoso.sch.uk)'
    $lbi.Tag     = 'demo-sob-01'
    [void]$Script:MD_UI.SobList.Items.Add($lbi)
    $Script:MD_UI.SobStatus.Text = '1 delegate(s)'
    Update-MdSobButtons
}

function Start-MdEwsLoadDemo {
    $Script:MD_UI.EwsList.Items.Clear()
    $lbi         = [System.Windows.Controls.ListBoxItem]::new()
    $lbi.Content = 'Connor Burke  |  Inbox: Editor   Calendar: Editor'
    $lbi.ToolTip = 'connor.burke@contoso.sch.uk'
    $lbi.Tag     = 'connor.burke@contoso.sch.uk'
    [void]$Script:MD_UI.EwsList.Items.Add($lbi)
    $Script:MD_UI.EwsStatus.Text = '1 delegate(s)'
    Update-MdEwsButtons
}

# ── XAML ───────────────────────────────────────────────────────────────────────
$Script:MdXaml = @'
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
            <Border Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                            Background="{TemplateBinding Background}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ListBox">
      <Setter Property="Background"      Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>

    <Style TargetType="ListBoxItem">
      <Setter Property="Foreground"           Value="#E2E2F0"/>
      <Setter Property="Background"           Value="Transparent"/>
      <Setter Property="Padding"              Value="12,7"/>
      <Setter Property="Cursor"               Value="Hand"/>
      <Setter Property="FocusVisualStyle"     Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    Padding="{TemplateBinding Padding}">
              <TextBlock Text="{TemplateBinding Content}"
                         Foreground="{TemplateBinding Foreground}"
                         TextTrimming="CharacterEllipsis"/>
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

  </Grid.Resources>

  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="260" MinWidth="180"/>
    <ColumnDefinition Width="5"/>
    <ColumnDefinition Width="*"/>
  </Grid.ColumnDefinitions>

  <GridSplitter Grid.Column="1" Width="5" HorizontalAlignment="Stretch"
                Background="#3C3C5A" Cursor="SizeWE" ResizeBehavior="PreviousAndNext"/>

  <!-- Left: mailbox owner picker -->
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
               VirtualizingPanel.VirtualizationMode="Recycling"/>
    </Grid>
  </Border>

  <!-- Right: three sections -->
  <ScrollViewer Grid.Column="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
    <StackPanel>

      <!-- A: Send As (advisory) -->
      <Border Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1" Margin="0,0,0,1">
        <StackPanel Margin="18,14,18,14">
          <TextBlock Text="SEND AS" Foreground="#50507A" FontSize="10" FontWeight="Bold" Margin="0,0,0,10"/>
          <Border Background="#2B1E00" BorderBrush="#F59E0B" BorderThickness="1" CornerRadius="4"
                  Padding="12,10" Margin="0,0,0,10">
            <TextBlock Foreground="#F59E0B" FontSize="12" TextWrapping="Wrap"
                       Text="Send As is an Exchange-level permission that cannot be managed via the Microsoft Graph API. Use Exchange Admin Center to add or remove Send As delegates."/>
          </Border>
          <Button x:Name="MdBtnEac" Content="Open Exchange Admin Center"
                  Style="{StaticResource Btn}" Background="#3C3C5A"
                  Padding="12,7" HorizontalAlignment="Left"/>
        </StackPanel>
      </Border>

      <!-- B: Send on Behalf -->
      <Border Background="#1C1C2A" BorderBrush="#3C3C5A" BorderThickness="0,0,0,1" Margin="0,0,0,1">
        <StackPanel Margin="18,14,18,14">
          <TextBlock Text="SEND ON BEHALF" Foreground="#50507A" FontSize="10" FontWeight="Bold" Margin="0,0,0,8"/>
          <TextBlock x:Name="MdSobStatus" Foreground="#7878A0" FontSize="12"
                     Text="Select a mailbox owner." Margin="0,0,0,8" TextWrapping="Wrap"/>

          <!-- Delegate list -->
          <Border BorderBrush="#3C3C5A" BorderThickness="1" CornerRadius="4">
            <ListBox x:Name="MdSobList" Height="110"
                     ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
          </Border>
          <Border Padding="0,8,0,10">
            <Button x:Name="MdBtnSobRemove" Content="Remove Selected Delegate"
                    Style="{StaticResource Btn}" Background="#EF4444"
                    Padding="12,7" IsEnabled="False" HorizontalAlignment="Left"/>
          </Border>

          <!-- Add by search -->
          <Border BorderBrush="#3C3C5A" BorderThickness="0,1,0,0" Padding="0,12,0,0">
            <StackPanel>
              <TextBlock Text="Add delegate — search by name or UPN:"
                         Foreground="#7878A0" FontSize="11" Margin="0,0,0,4"/>
              <TextBox x:Name="MdSobSearch" Height="32"/>
              <Border x:Name="MdSobDropdown" Background="#242436" BorderBrush="#3C3C5A"
                      BorderThickness="1" CornerRadius="0,0,4,4" MaxHeight="150"
                      Visibility="Collapsed">
                <ListBox x:Name="MdSobDropList" Background="Transparent" BorderThickness="0"
                         ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
              </Border>
            </StackPanel>
          </Border>
        </StackPanel>
      </Border>

      <!-- C: Full Access (EWS) -->
      <Border Background="#1C1C2A" Margin="0,0,0,0">
        <StackPanel Margin="18,14,18,18">
          <TextBlock Text="FULL ACCESS (READ AND MANAGE)" Foreground="#50507A" FontSize="10" FontWeight="Bold" Margin="0,0,0,8"/>
          <TextBlock x:Name="MdEwsStatus" Foreground="#7878A0" FontSize="12"
                     Text="Select a mailbox owner." Margin="0,0,0,8" TextWrapping="Wrap"/>

          <!-- Delegate list -->
          <Border BorderBrush="#3C3C5A" BorderThickness="1" CornerRadius="4">
            <ListBox x:Name="MdEwsList" Height="120"
                     ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
          </Border>
          <Border Padding="0,8,0,10">
            <Button x:Name="MdBtnEwsRemove" Content="Remove Selected Delegate"
                    Style="{StaticResource Btn}" Background="#EF4444"
                    Padding="12,7" IsEnabled="False" HorizontalAlignment="Left"/>
          </Border>

          <!-- Add by email -->
          <Border BorderBrush="#3C3C5A" BorderThickness="0,1,0,0" Padding="0,12,0,0">
            <StackPanel>
              <TextBlock Text="Add delegate — enter email address:"
                         Foreground="#7878A0" FontSize="11" Margin="0,0,0,4"/>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="8"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBox x:Name="MdEwsAddEmail" Grid.Column="0" Height="32"/>
                <Button x:Name="MdBtnEwsAdd" Grid.Column="2" Content="Add Delegate"
                        Style="{StaticResource Btn}" Background="#6366F1" Padding="12,7"/>
              </Grid>
              <TextBlock Foreground="#50507A" FontSize="10" Margin="0,6,0,0" TextWrapping="Wrap"
                         Text="Default permissions granted: Inbox — Editor, Calendar — Editor, Contacts — Reviewer, Tasks — None"/>
            </StackPanel>
          </Border>
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
        UserSearch    = $content.FindName('MdUserSearch')
        UserList      = $content.FindName('MdUserList')
        BtnEac        = $content.FindName('MdBtnEac')
        SobStatus     = $content.FindName('MdSobStatus')
        SobList       = $content.FindName('MdSobList')
        BtnSobRemove  = $content.FindName('MdBtnSobRemove')
        SobSearch     = $content.FindName('MdSobSearch')
        SobDropdown   = $content.FindName('MdSobDropdown')
        SobDropList   = $content.FindName('MdSobDropList')
        EwsStatus     = $content.FindName('MdEwsStatus')
        EwsList       = $content.FindName('MdEwsList')
        BtnEwsRemove  = $content.FindName('MdBtnEwsRemove')
        EwsAddEmail   = $content.FindName('MdEwsAddEmail')
        BtnEwsAdd     = $content.FindName('MdBtnEwsAdd')
    }

    $Script:MD_UI.UserSearch.Add_TextChanged({
        try { Update-MdUserFilter } catch { Write-Log "MD UserSearch: $_" 'ERROR' }
    })

    $Script:MD_UI.UserList.Add_SelectionChanged({
        try {
            $sel = $Script:MD_UI.UserList.SelectedItem
            if (-not $sel) { return }
            $Script:MD_SelectedUser = $sel.Tag
            Write-Log "MD: selected $($Script:MD_SelectedUser.displayName)" 'DEBUG'
            Start-MdSobLoad -UserId $Script:MD_SelectedUser.id
            Start-MdEwsLoad -OwnerUpn $Script:MD_SelectedUser.userPrincipalName
        } catch { Write-Log "MD UserList: $_" 'ERROR' }
    })

    $Script:MD_UI.BtnEac.Add_Click({
        try { Start-Process 'https://admin.exchange.microsoft.com' } catch {}
    })

    $Script:MD_UI.SobList.Add_SelectionChanged({
        try { Update-MdSobButtons } catch {}
    })

    $Script:MD_UI.BtnSobRemove.Add_Click({
        try { Start-MdSobRemove } catch { Write-Log "MD SobRemove: $_" 'ERROR' }
    })

    $Script:MD_UI.SobSearch.Add_TextChanged({
        try { Update-MdSobSearch } catch { Write-Log "MD SobSearch: $_" 'ERROR' }
    })

    $Script:MD_UI.SobDropList.Add_SelectionChanged({
        try {
            $sel = $Script:MD_UI.SobDropList.SelectedItem
            if (-not $sel) { return }
            Start-MdSobAdd -DelegateId $sel.Tag.id
        } catch { Write-Log "MD SobDropList: $_" 'ERROR' }
    })

    $Script:MD_UI.EwsList.Add_SelectionChanged({
        try { Update-MdEwsButtons } catch {}
    })

    $Script:MD_UI.BtnEwsRemove.Add_Click({
        try { Start-MdEwsRemove } catch { Write-Log "MD EwsRemove: $_" 'ERROR' }
    })

    $Script:MD_UI.BtnEwsAdd.Add_Click({
        try { Start-MdEwsAdd } catch { Write-Log "MD EwsAdd: $_" 'ERROR' }
    })

    Register-ConnectCallback 'Start-MdUserLoad'

    $Script:ResetCallbacks.Add({
        $Script:MD_AllUsers     = @()
        $Script:MD_SelectedUser = $null
        $Script:MD_UI.UserSearch.Text      = ''
        $Script:MD_UI.UserSearch.IsEnabled = $false
        $Script:MD_UI.UserList.Items.Clear()
        $Script:MD_UI.UserList.IsEnabled   = $false
        $Script:MD_UI.SobList.Items.Clear()
        $Script:MD_UI.SobStatus.Text       = 'Select a mailbox owner.'
        $Script:MD_UI.BtnSobRemove.IsEnabled = $false
        $Script:MD_UI.SobSearch.Text       = ''
        $Script:MD_UI.SobDropdown.Visibility = 'Collapsed'
        $Script:MD_UI.EwsList.Items.Clear()
        $Script:MD_UI.EwsStatus.Text       = 'Select a mailbox owner.'
        $Script:MD_UI.BtnEwsRemove.IsEnabled = $false
        $Script:MD_UI.EwsAddEmail.Text     = ''
    })

    Write-MdLog 'Mailbox Delegation ready. Connect a tenant to begin.' 'Muted'
    return $content
}
