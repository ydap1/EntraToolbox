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
    $request = @{
        Uri = $Uri; Method = $Method; Headers = $Headers
        TimeoutSec = $TimeoutSec; MaximumRedirection = 0; ErrorAction = 'Stop'
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
            return $result
        } catch {
            $response = $_.Exception.Response
            $status = if ($response) { [int]$response.StatusCode } else { 0 }
            # A failed write can have succeeded on the server. Never replay it on
            # an ambiguous gateway/server error (e.g. creating a second Team).
            $retryable = $status -eq 429 -or
                ($Method -in 'GET', 'HEAD', 'OPTIONS' -and $status -in 502, 503, 504)
            if (-not $retryable -or $attempt -ge 4) { throw }
            $delay = Get-EtbRetryDelay -Response $response -Attempt $attempt
            # Do not shorten the server's Retry-After. Cancellation interrupts sleep.
            Start-Sleep -Seconds $delay
        }
    }
}
