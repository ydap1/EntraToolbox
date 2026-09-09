# Shared by the UI session and background workers. Keep this file WPF-free.
function Get-EtbGraphCollection {
    param([Parameter(Mandatory)][string]$Uri, [System.Collections.IDictionary]$Headers = @{})
    $items = [System.Collections.Generic.List[object]]::new()
    $visited = [System.Collections.Generic.HashSet[string]]::new()
    do {
        if (-not $visited.Add($Uri)) { throw 'Graph returned a repeated pagination link.' }
        $page = Invoke-RestMethod -Uri $Uri -Headers $Headers -Method GET
        foreach ($item in $page.value) { if ($null -ne $item) { $items.Add($item) } }
        $Uri = $page.'@odata.nextLink'
    } while ($Uri)
    $items.ToArray()
}

function Get-EtbRetryDelay {
    param($Response, [int]$Attempt)
    $retry = $Response.Headers.RetryAfter
    if ($retry.Delta) { return [math]::Max(1, [math]::Ceiling($retry.Delta.TotalSeconds)) }
    if ($retry.Date) { return [math]::Max(1, [math]::Ceiling(($retry.Date.UtcDateTime - [datetime]::UtcNow).TotalSeconds)) }
    return [math]::Min(30, [math]::Pow(2, $Attempt + 1))
}

function Invoke-RestMethod {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [string]$Method = 'GET',
        [System.Collections.IDictionary]$Headers = @{},
        $Body,
        [string]$ContentType,
        [ValidateRange(1, 300)][int]$TimeoutSec = 60,
        [string]$ResponseHeadersVariable
    )
    if ($Headers['Authorization'] -eq 'Bearer DEMO') { throw 'Demo mode cannot send authenticated requests.' }
    if ($Headers['Authorization'] -and
        ($Uri.Scheme -ne 'https' -or $Uri.Host -ne 'graph.microsoft.com' -or
         $Uri.Port -ne 443 -or $Uri.UserInfo)) {
        throw 'Refusing to send credentials outside https://graph.microsoft.com.'
    }
    if ($Script:DryMode -and $Method -notin 'GET', 'HEAD', 'OPTIONS') {
        throw 'Dry run is active. This request would modify the tenant.'
    }
    # A batch can outlive the token captured when its worker started. The UI
    # thread publishes each silent refresh into $Ref['Token'] (see
    # Publish-EtbWorkerToken); use the current one rather than the captured one.
    if ($Ref -and $Ref['Token'] -and $Headers['Authorization'] -like 'Bearer *') {
        $current = @{}
        foreach ($key in $Headers.Keys) { $current[$key] = $Headers[$key] }
        $current['Authorization'] = "Bearer $($Ref['Token'])"
        $Headers = $current
    }
    $request = @{
        Uri = $Uri; Method = $Method; Headers = $Headers
        TimeoutSec = $TimeoutSec; MaximumRedirection = 0; ErrorAction = 'Stop'; StatusCodeVariable = 'etbStatus'
    }
    if ($PSBoundParameters.ContainsKey('Body')) { $request.Body = $Body }
    if ($ContentType) { $request.ContentType = $ContentType }
    if ($ResponseHeadersVariable) { $request.ResponseHeadersVariable = 'responseHeaders' }
    for ($attempt = 0; ; $attempt++) {
        if ($Ref -and $Ref['Cancelled']) { throw [System.OperationCanceledException]::new() }
        try {
            $result = Microsoft.PowerShell.Utility\Invoke-RestMethod @request
            if ($ResponseHeadersVariable) {
                Set-Variable -Name $ResponseHeadersVariable -Value $responseHeaders -Scope 1
            }
            if ($Method -notin 'GET','HEAD','OPTIONS') {
                Publish-EtbWriteResult $request $(if ($etbStatus -eq 202) { 'Accepted' } else { 'Succeeded' }) $(if ($etbStatus -eq 202) { 'Request accepted. Check the original tool for provisioning completion.' } else { '' })
            }
            return $result
        } catch {
            $response = $_.Exception.Response
            $status = if ($response) { [int]$response.StatusCode } else { 0 }
            # A failed write can have succeeded on the server. Never replay it on
            # an ambiguous gateway/server error (e.g. creating a second Team).
            $retryable = $status -eq 429 -or
                ($Method -in 'GET', 'HEAD', 'OPTIONS' -and $status -in 502, 503, 504)
            if (-not $retryable -or $attempt -ge 4) {
                if ($Method -notin 'GET','HEAD','OPTIONS') { Publish-EtbWriteResult $request (Get-EtbWriteResult $status) $_.Exception.Message }
                throw
            }
            $delay = Get-EtbRetryDelay -Response $response -Attempt $attempt
            # Do not shorten the server's Retry-After. Cancellation interrupts sleep.
            Start-Sleep -Seconds $delay
        }
    }
}


function Get-EtbWriteResult {
    param([int]$Status)
    if ($Status -in 400,401,403,404,405,409,412,422,429) { return 'Failed' }
    return 'Uncertain'
}

function Publish-EtbWriteResult {
    param($Request, [string]$Result, [string]$Detail = '')
    if (-not $Ref -or -not $Ref['BulkQueue']) { return }
    $uri = [uri]$Request.Uri
    $retry = $null
    $body = if ($Request.Body) { try { $Request.Body | ConvertFrom-Json -AsHashtable } catch { $null } }
    # Keep only narrowly supported, non-secret requests for explicit recovery.
    if ($Request.Method -eq 'PATCH' -and $uri.AbsolutePath -match '/users/[^/]+$' -and $body -and
        @($body.Keys | Where-Object { $_ -notin 'userPrincipalName','onPremisesImmutableId','accountEnabled' }).Count -eq 0) {
        $retry = @{ Uri = $uri.AbsoluteUri; Method = 'PATCH'; Body = $Request.Body }
    } elseif ($Request.Method -eq 'POST' -and $uri.AbsolutePath -match '/users/[^/]+/assignLicense$' -and $body) {
        $retry = @{ Uri=$uri.AbsoluteUri; Method='POST'; Body=$Request.Body; Kind='Licence'; VerifyUri=($uri.AbsoluteUri -replace '/assignLicense$', '?$select=licenseAssignmentStates') }
    } elseif ($uri.AbsolutePath -match '/groups/[^/]+/members/(?:[^/]+/)?\$ref$') {
        $verify = if ($Request.Method -eq 'DELETE') { $uri.AbsoluteUri -replace '/\$ref$', '' }
            elseif ($body['@odata.id']) { ($uri.AbsoluteUri -replace '/\$ref$', '/') + ($body['@odata.id'] -split '/')[-1] }
        if ($verify) { $retry = @{ Uri = $uri.AbsoluteUri; Method = $Request.Method; Body = $Request.Body; VerifyUri = $verify } }
    }
    $target = $uri.AbsolutePath -replace '^/v1.0/', ''
    if ($body -and $body['@odata.id']) { $target += ' -> ' + ($body['@odata.id'] -split '/')[-1] }
    if ($body -and $body['user@odata.bind']) { $target += ' -> ' + $body['user@odata.bind'] }
    if ($body -and $body['displayName']) { $target += ' -> ' + $body['displayName'] }
    if ($Ref['BulkLabels']) {
        foreach ($segment in ($target -split '[/ ]+')) {
            if ($Ref['BulkLabels'].ContainsKey($segment)) { $target = $target.Replace($segment, $Ref['BulkLabels'][$segment]) }
        }
    }
    if ($body -and $body.ContainsKey('passwordProfile')) { $Detail = if ($Result -eq 'Succeeded') { '' } else { 'Password request failed or has an uncertain outcome; review the original tool.' } }
    $action = if ($uri.AbsolutePath -match '/assignLicense$') { if (@($body['addLicenses']).Count) { 'Assign licence' } else { 'Remove licence' } }
        elseif ($uri.AbsolutePath -match '/members/') { if ($Request.Method -eq 'DELETE') { 'Remove member' } else { 'Add member' } } else { $Request.Method }
    $Ref['BulkQueue'].Enqueue([pscustomobject]@{ Time = (Get-Date -Format HH:mm:ss); Target = $target; Action = $action; Result = $Result; Detail = $Detail; Retry = $retry })
}
