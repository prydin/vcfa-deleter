# Shared implementation for the two PowerShell entry points (Windows PowerShell 5.1+).
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

class VmInventoryException : System.Exception {
    VmInventoryException([string]$message) : base($message) {}
}

class VmCheckFailedException : VmInventoryException {
    VmCheckFailedException([string]$message) : base($message) {}
}

class VmApiException : VmInventoryException {
    [int]$Status
    VmApiException([string]$method, [string]$path, [int]$status) : base(
        ('{0} {1}: HTTP {2}' -f $method, $path, $status)) {
        $this.Status = $status
    }
}

$script:VmColumns = @(
    'vm_name', 'deployment_name', 'status', 'vm_id', 'resource_id',
    'deployment_id', 'cloudzone', 'cloudzone_id', 'powerStatus'
)
$script:VmLog = $null

function Write-VmLog {
    param([string]$Message, [string]$Level = 'INFO')
    [Console]::Error.WriteLine("${Level}: $Message")
    if ($null -ne $script:VmLog) {
        $script:VmLog.WriteLine(('{0:yyyy-MM-dd HH:mm:ss} {1}: {2}' -f (Get-Date), $Level, $Message))
        $script:VmLog.Flush()
    }
}

function Open-VmLog {
    param([string]$Path)
    $script:VmLog = [IO.StreamWriter]::new((Resolve-VmPath $Path), $true, [Text.UTF8Encoding]::new($false))
}

function Close-VmLog {
    if ($null -ne $script:VmLog) { $script:VmLog.Dispose(); $script:VmLog = $null }
}

function Get-VmValue {
    param($Record, [string]$Key)
    if ($null -eq $Record) { return $null }
    if ($Record -is [System.Collections.IDictionary]) {
        foreach ($name in $Record.Keys) { if ($name -ceq $Key) { return ,$Record[$name] } }
    } else {
        foreach ($property in $Record.PSObject.Properties) {
            if ($property.Name -ceq $Key) { return ,$property.Value }
        }
    }
    return $null
}

function Get-VmText {
    param($Record, [string]$Key)
    $value = Get-VmValue $Record $Key
    if ($value -is [string]) { return $value.Trim() }
    return ''
}

function Get-VmRequiredText {
    param($Record, [string]$Key, [string]$Context)
    $value = Get-VmText $Record $Key
    if (-not $value) { throw [VmInventoryException]::new("${Context}: missing or invalid $Key") }
    return $value
}

function Assert-VmObject {
    param($Value, [string]$Context)
    if ($null -eq $Value -or
        ($Value -isnot [System.Collections.IDictionary] -and
            $Value.GetType() -ne [System.Management.Automation.PSCustomObject])) {
        throw [VmInventoryException]::new("${Context}: expected a JSON object")
    }
    return $Value
}

function Get-VmProperties {
    param($Record, [string]$Key)
    $value = Get-VmValue $Record $Key
    if ($null -eq $value) { return @{} }
    return Assert-VmObject $value $Key
}

function ConvertTo-VmIdentifier {
    param([string]$Value)
    return [Uri]::EscapeDataString($Value)
}

function Resolve-VmPath {
    param([string]$Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function New-VmSet {
    return ,([Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal))
}

function Get-VmFailure {
    param([Exception]$Exception)
    while ($null -ne $Exception.InnerException -and $Exception -isnot [VmInventoryException]) {
        $Exception = $Exception.InnerException
    }
    return $Exception
}

function Test-VmApiStatus {
    param([Exception]$Exception, [int]$Status)
    $failure = Get-VmFailure $Exception
    return ($failure -is [VmApiException] -and $failure.Status -eq $Status)
}

function New-VmCertificateBypass {
    # A scriptblock callback cannot reliably run on .NET's network threads.
    # Build a constant-true .NET delegate without compiling embedded C#.
    $parameters = [Linq.Expressions.ParameterExpression[]]@(
        [Linq.Expressions.Expression]::Parameter([object], 'sender'),
        [Linq.Expressions.Expression]::Parameter([Security.Cryptography.X509Certificates.X509Certificate], 'certificate'),
        [Linq.Expressions.Expression]::Parameter([Security.Cryptography.X509Certificates.X509Chain], 'chain'),
        [Linq.Expressions.Expression]::Parameter([Net.Security.SslPolicyErrors], 'errors')
    )
    return [Linq.Expressions.Expression]::Lambda([Net.Security.RemoteCertificateValidationCallback],
        [Linq.Expressions.Expression]::Constant($true), $parameters).Compile()
}

function Start-VmTlsScope {
    param([hashtable]$Options)
    $state = [pscustomobject]@{ Changed = $false; PreviousCallback = $null }
    if ($Options['Insecure']) {
        Write-VmLog 'TLS certificate verification is disabled by Insecure. Server identity is not verified. On Windows PowerShell 5.1, this affects all HTTPS work in this process until the command exits; use a dedicated process on a trusted network.' WARNING
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            $state.PreviousCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
            [Net.ServicePointManager]::ServerCertificateValidationCallback = New-VmCertificateBypass
            $state.Changed = $true
        }
    }
    return $state
}

function Stop-VmTlsScope {
    param($State)
    if ($null -ne $State -and $State.Changed) {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = $State.PreviousCallback
    }
}

function Update-VmAccessTokenIfNeeded {
    param($Client)
    $refreshMode = Get-VmValue $Client RefreshMode
    $issuedAt = Get-VmValue $Client TokenIssuedAt
    if (-not $refreshMode -or $null -eq $issuedAt -or
        ([DateTime]::UtcNow - [DateTime]$issuedAt).TotalMinutes -lt 15) {
        return
    }

    switch ($refreshMode) {
        'oauth' {
            $body = 'grant_type=refresh_token&refresh_token=' + (ConvertTo-VmIdentifier $Client.RefreshToken)
            $reply = Invoke-VmRequest $Client POST $Client.RefreshPath -Body $body `
                -Headers @{ 'Content-Type' = 'application/x-www-form-urlencoded' } `
                -NoBearerToken -SkipTokenRefresh
            $Client.Token = Get-VmRequiredText (ConvertFrom-VmJson $reply.Body 'token refresh') access_token 'token refresh'
        }
        'legacy' {
            $reply = Invoke-VmRequest $Client POST '/iaas/api/login' `
                -Body (ConvertTo-Json -Compress -InputObject @{ refreshToken = $Client.RefreshToken }) `
                -Headers @{ 'Content-Type' = 'application/json' } -NoBearerToken -SkipTokenRefresh
            $Client.Token = Get-VmRequiredText (ConvertFrom-VmJson $reply.Body 'legacy token refresh') token 'legacy token refresh'
        }
        'session' {
            $reply = Invoke-VmRequest $Client POST '/cloudapi/1.0.0/sessions' -Body '' `
                -Headers @{
                    Authorization = $Client.SessionAuthorization
                    Accept = 'application/json;version=' + $Client.CloudApiVersion
                } -NoBearerToken -SkipTokenRefresh
            if (-not $reply.Headers.ContainsKey('x-vmware-vcloud-access-token')) {
                throw [VmInventoryException]::new('Session refresh omitted X-VMWARE-VCLOUD-ACCESS-TOKEN')
            }
            $Client.Token = $reply.Headers['x-vmware-vcloud-access-token']
            if (-not $Client.Token) { throw [VmInventoryException]::new('Empty session access token after refresh') }
        }
        default { throw [VmInventoryException]::new('Unsupported bearer token refresh mode') }
    }
    $Client.TokenIssuedAt = [DateTime]::UtcNow
    Write-VmLog 'Refreshed bearer token before request'
}

function Invoke-VmRequest {
    param($Client, [string]$Method, [string]$Path, [hashtable]$Query = @{},
          [AllowNull()][string]$Body, [hashtable]$Headers = @{},
          [switch]$NoBearerToken, [switch]$SkipTokenRefresh)
    if (-not $Path.StartsWith('/') -or $Path.StartsWith('//')) {
        throw [VmInventoryException]::new('API paths must be relative to the configured host')
    }
    if (-not $SkipTokenRefresh) { Update-VmAccessTokenIfNeeded $Client }
    $parameters = @{} + $Query
    if ($Path.StartsWith('/iaas/')) { $parameters.apiVersion = $Client.ApiVersion }
    $url = $Client.Base + $Path
    if ($parameters.Count) {
        $pairs = foreach ($key in $parameters.Keys) {
            '{0}={1}' -f (ConvertTo-VmIdentifier $key), (ConvertTo-VmIdentifier ([string]$parameters[$key]))
        }
        $url += '?' + ($pairs -join '&')
    }
    $requestHeaders = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    $requestHeaders['Accept'] = 'application/json'
    if (-not $NoBearerToken -and $Client.Token) { $requestHeaders['Authorization'] = 'Bearer ' + $Client.Token }
    foreach ($key in $Headers.Keys) { $requestHeaders[$key] = $Headers[$key] }
    $request = @{
        Uri = $url; Method = $Method; Headers = $requestHeaders
        TimeoutSec = [int][Math]::Min([int]::MaxValue, [Math]::Ceiling($Client.Timeout))
        MaximumRedirection = 0; UseBasicParsing = $true; ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Body')) { $request.Body = [Text.Encoding]::UTF8.GetBytes($Body) }
    if ($PSVersionTable.PSVersion.Major -ge 6 -and (Get-VmValue $Client Insecure)) {
        $request.SkipCertificateCheck = $true
    }
    $response = @()
    $previousProgressPreference = $ProgressPreference
    $debug = [bool](Get-VmValue $Client Debug)
    $outcome = 'failed'
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $ProgressPreference = 'SilentlyContinue'
        # 5.1 can emit the redirect response before raising MaximumRedirectExceeded.
        $null = Invoke-WebRequest @request -OutVariable response
        $outcome = [string][int]$response[0].StatusCode
    }
    catch {
        if ($response.Count -gt 0) {
            $outcome = [string][int]$response[0].StatusCode
            throw [VmApiException]::new($Method, $Path, [int]$response[0].StatusCode)
        }
        $webResponse = $null
        if ($_.Exception.PSObject.Properties['Response']) { $webResponse = $_.Exception.Response }
        if ($null -ne $webResponse) {
            $outcome = [string][int]$webResponse.StatusCode
            throw [VmApiException]::new($Method, $Path, [int]$webResponse.StatusCode)
        }
        $outcome = 'connection/TLS failure'
        throw [VmInventoryException]::new("${Method} ${Path}: connection/TLS failure")
    }
    finally {
        $stopwatch.Stop()
        $ProgressPreference = $previousProgressPreference
        if ($debug) {
            # Query values may carry credentials, so only non-secret paging parameters are shown.
            $shown = @($Query.Keys | Where-Object { $_ -in @('page', 'size', '$top', '$skip') } | Sort-Object |
                ForEach-Object { '{0}={1}' -f $_, $Query[$_] })
            $target = $Path
            if ($shown.Count) { $target += '?' + ($shown -join '&') }
            Write-VmLog ('{0} {1} -> {2} in {3:N0} ms' -f $Method, $target, $outcome, $stopwatch.Elapsed.TotalMilliseconds) DEBUG
        }
    }
    $response = $response[0]
    if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) {
        throw [VmApiException]::new($Method, $Path, [int]$response.StatusCode)
    }
    $responseHeaders = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $response.Headers.Keys) { $responseHeaders[$key] = $response.Headers[$key] -join ', ' }
    return [pscustomobject]@{ Body = [string]$response.Content; Headers = $responseHeaders }
}

function ConvertFrom-VmJson {
    param([string]$Body, [string]$Context)
    try { $record = ConvertFrom-Json -InputObject $Body -ErrorAction Stop }
    catch { throw [VmInventoryException]::new("${Context}: invalid JSON response") }
    if (-not $Body.TrimStart().StartsWith('{')) {
        throw [VmInventoryException]::new("${Context}: expected a JSON object")
    }
    return Assert-VmObject $record $Context
}

function Get-VmRecord {
    param($Client, [string]$Path, [hashtable]$Query = @{})
    $reply = Invoke-VmRequest $Client GET $Path -Query $Query
    return ConvertFrom-VmJson $reply.Body $Path
}

function Get-VmRecords {
    param($Client, [string]$Path)
    $offset = 0
    $pageNumber = 0
    $spring = $Path.StartsWith('/deployment/')
    $seen = New-VmSet
    while ($true) {
        if ($spring) { $query = @{ page = $pageNumber; size = $Client.PageSize } }
        else { $query = @{ '$top' = $Client.PageSize; '$skip' = $offset } }
        $page = Get-VmRecord $Client $Path $query
        $content = Get-VmValue $page content
        if ($content -isnot [array]) {
            throw [VmInventoryException]::new("${Path}: expected a content array")
        }
        $total = Get-VmValue $page totalElements
        $hasTotal = $total -is [int] -or $total -is [long]
        if ($content.Count -eq 0) {
            if ($hasTotal -and $offset -lt $total) {
                throw [VmInventoryException]::new("${Path}: pagination ended before totalElements")
            }
            return
        }
        foreach ($value in $content) {
            $record = Assert-VmObject $value $Path
            $id = Get-VmRequiredText $record id $Path
            if (-not $seen.Add($id)) {
                throw [VmInventoryException]::new("${Path}: repeated ID $id; pagination/inventory changed, rerun")
            }
            Write-Output $record
        }
        $offset += $content.Count
        $pageNumber++
        if ($hasTotal -and $offset -ge $total) { return }
        if ($spring -and (Get-VmValue $page last) -ceq $true) {
            if ($hasTotal -and $offset -lt $total) {
                throw [VmInventoryException]::new("${Path}: last page ended before totalElements")
            }
            return
        }
    }
}

function New-VmClient {
    param([hashtable]$Options)
    $server = [string]$Options.Server
    if (-not $server.Contains('://')) { $server = 'https://' + $server }
    $uri = $null
    if (-not [Uri]::TryCreate($server, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or -not $uri.Host -or $uri.UserInfo -or
        $uri.AbsolutePath -cne '/' -or $uri.Query -or $uri.Fragment) {
        throw [VmInventoryException]::new('Host must be an HTTPS hostname or origin, without a path')
    }
    if ($Options.ApiToken -and $Options.Username) {
        throw [VmInventoryException]::new('Do not combine ApiToken/VCFA_API_TOKEN with Username')
    }
    if (-not $Options.ApiToken -and -not $Options.Username) {
        throw [VmInventoryException]::new('Provide ApiToken, VCFA_API_TOKEN, or Username')
    }
    if ($Options.ApiToken -and $null -ne $Options.Password) {
        throw [VmInventoryException]::new('Password/VCFA_PASSWORD cannot be combined with ApiToken')
    }
    $legacy = [bool]$Options['Legacy']
    $domain = [string]$Options['Domain']
    if ($legacy -and $Options.Org) {
        throw [VmInventoryException]::new('Org is not supported with Legacy; use Domain for an identity domain')
    }
    if ($domain -and (-not $legacy -or -not $Options.Username)) {
        throw [VmInventoryException]::new('Domain requires Legacy and Username')
    }
    $client = [pscustomobject]@{
        Base = $uri.GetLeftPart([UriPartial]::Authority)
        Timeout = $Options.Timeout; PageSize = $Options.PageSize
        ApiVersion = $Options.ApiVersion; CloudApiVersion = $Options.CloudApiVersion
        Token = ''; TokenIssuedAt = $null; RefreshMode = ''; RefreshToken = ''
        RefreshPath = ''; SessionAuthorization = ''; Insecure = [bool]$Options['Insecure']
        Debug = [bool]$Options['Debug']
    }
    if ($legacy) {
        $refreshToken = $Options.ApiToken
        if (-not $refreshToken) {
            $password = $Options.Password
            if ($null -eq $password) {
                $secure = Read-Host 'Password' -AsSecureString
                $password = [Net.NetworkCredential]::new('', $secure).Password
            }
            $credentials = @{ username = $Options.Username; password = $password }
            if ($domain) { $credentials.domain = $domain }
            $reply = Invoke-VmRequest $client POST '/csp/gateway/am/api/login' `
                -Query @{ access_token = '' } -Body (ConvertTo-Json -Compress -InputObject $credentials) `
                -Headers @{ 'Content-Type' = 'application/json' }
            $refreshToken = Get-VmRequiredText (ConvertFrom-VmJson $reply.Body 'legacy login') refresh_token 'legacy login'
        }
        $client.RefreshMode = 'legacy'
        $client.RefreshToken = $refreshToken
        $reply = Invoke-VmRequest $client POST '/iaas/api/login' `
            -Body (ConvertTo-Json -Compress -InputObject @{ refreshToken = $refreshToken }) `
            -Headers @{ 'Content-Type' = 'application/json' }
        $client.Token = Get-VmRequiredText (ConvertFrom-VmJson $reply.Body 'legacy token exchange') token 'legacy token exchange'
        $client.TokenIssuedAt = [DateTime]::UtcNow
    } elseif ($Options.ApiToken) {
        if (-not $Options.Org) { throw [VmInventoryException]::new('Org is required for an organization API token') }
        $client.RefreshMode = 'oauth'
        $client.RefreshToken = $Options.ApiToken
        $client.RefreshPath = '/oauth/tenant/{0}/token' -f (ConvertTo-VmIdentifier $Options.Org)
        $body = 'grant_type=refresh_token&refresh_token=' + (ConvertTo-VmIdentifier $Options.ApiToken)
        $reply = Invoke-VmRequest $client POST $client.RefreshPath `
            -Body $body -Headers @{ 'Content-Type' = 'application/x-www-form-urlencoded' }
        $client.Token = Get-VmRequiredText (ConvertFrom-VmJson $reply.Body 'token exchange') access_token 'token exchange'
        $client.TokenIssuedAt = [DateTime]::UtcNow
    } else {
        $principal = [string]$Options.Username
        if ($Options.Org -and -not $principal.EndsWith('@' + $Options.Org, [StringComparison]::Ordinal)) {
            $principal += '@' + $Options.Org
        }
        if (-not $Options.Org -and -not $principal.Contains('@')) {
            throw [VmInventoryException]::new('Use Org or an organization-qualified username')
        }
        $password = $Options.Password
        if ($null -eq $password) {
            $secure = Read-Host 'Password' -AsSecureString
            $password = [Net.NetworkCredential]::new('', $secure).Password
        }
        $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${principal}:$password"))
        $client.RefreshMode = 'session'
        $client.SessionAuthorization = "Basic $basic"
        $reply = Invoke-VmRequest $client POST '/cloudapi/1.0.0/sessions' -Body '' -Headers @{
            Authorization = $client.SessionAuthorization; Accept = 'application/json;version=' + $client.CloudApiVersion
        }
        if (-not $reply.Headers.ContainsKey('x-vmware-vcloud-access-token')) {
            throw [VmInventoryException]::new('Session response omitted X-VMWARE-VCLOUD-ACCESS-TOKEN')
        }
        $client.Token = $reply.Headers['x-vmware-vcloud-access-token']
        if (-not $client.Token) { throw [VmInventoryException]::new('Empty session access token') }
        $client.TokenIssuedAt = [DateTime]::UtcNow
    }
    return $client
}

function Test-VmResource {
    param($Resource)
    $type = Get-VmText $Resource type
    return $type.StartsWith('Cloud.', [StringComparison]::Ordinal) -and $type.EndsWith('.Machine', [StringComparison]::Ordinal)
}

function Get-VmSyncStatus {
    param($Resource)
    $status = Get-VmText $Resource syncStatus
    if ($status) {
        if ($status -ieq 'missing') { return 'missing' }
        return $status
    }
    Write-VmLog ("VM {0} has no valid syncStatus; reporting unknown" -f (Get-VmText $Resource id)) WARNING
    return 'unknown'
}

function Get-VmPowerStatus {
    param($Resource)
    $status = Get-VmText (Get-VmProperties $Resource properties) powerState
    if ($status) { return $status }
    Write-VmLog ("VM {0} has no valid properties.powerState; reporting unknown powerStatus" -f (Get-VmText $Resource id)) WARNING
    return 'unknown'
}

 function Get-VmZoneMembership {
    param($Resource, $Zone, [bool]$AllowNames = $true)
    $zoneId = Get-VmRequiredText $Zone id 'cloud zone'
    $zoneName = Get-VmRequiredText $Zone name 'cloud zone'
    $sources = @($Resource, (Get-VmProperties $Resource customProperties), (Get-VmProperties $Resource properties))
    $ids = New-VmSet
    foreach ($source in $sources) {
        foreach ($key in @('zoneId', 'cloudZoneId')) {
            $value = Get-VmText $source $key
            if ($value) { [void]$ids.Add($value) }
        }
    }
    $links = Get-VmProperties $Resource _links
    foreach ($key in @('zone', 'cloud-zone')) {
        $link = Get-VmValue $links $key
        if ($null -ne $link) {
            $href = Get-VmRequiredText (Assert-VmObject $link "_links.$key") href "_links.$key"
            $uri = [Uri]::new($href, [UriKind]::RelativeOrAbsolute)
            if ($uri.IsAbsoluteUri) { $path = $uri.AbsolutePath.TrimEnd('/') }
            else { $path = ($href -split '[?#]', 2)[0].TrimEnd('/') }
            if (-not $path.StartsWith('/iaas/api/zones/')) {
                throw [VmInventoryException]::new("Unsupported cloud-zone link: $path")
            }
            [void]$ids.Add([Uri]::UnescapeDataString(($path -split '/')[-1]))
        }
    }
    if ($ids.Count) {
        if ($ids.Count -ne 1) { throw [VmInventoryException]::new('Conflicting explicit cloud-zone IDs in a VM record') }
        return $ids.Contains($zoneId)
    }
    if (-not $AllowNames) { return $null }
    $names = New-VmSet
    foreach ($source in $sources) {
        foreach ($key in @('zone', 'zoneName', 'cloudZoneName')) {
            if ($key -ceq 'zone' -and (Get-VmText $source computeHostRef)) { continue }
            $value = Get-VmText $source $key
            if ($value) { [void]$names.Add($value) }
        }
    }
    if ($names.Count) {
        if ($names.Count -ne 1) { throw [VmInventoryException]::new('Conflicting explicit cloud-zone names in a VM record') }
        return $names.Contains($zoneName)
    }
    return $null
}

function New-VmPlacementCache {
    return @{ Region = $null; Computes = $null }
}

function Get-VmComputeMembership {
    param($Client, $Resource, $Zone, [hashtable]$Cache)
    $recorded = Get-VmProperties $Resource properties
    $reference = Get-VmText $recorded computeHostRef
    if (-not $reference) { return $null }
    if ($null -eq $Cache.Region) {
        $link = Assert-VmObject (Get-VmValue (Get-VmProperties $Zone _links) region) 'cloud zone region link'
        $path = Get-VmRequiredText $link href 'cloud zone region link'
        if (-not $path.StartsWith('/iaas/api/regions/')) {
            throw [VmInventoryException]::new('Unsupported cloud-zone region link')
        }
        $Cache.Region = Get-VmRecord $Client $path
    }
    $account = Get-VmRequiredText $Cache.Region cloudAccountId 'cloud zone region'
    $regionId = Get-VmRequiredText $Cache.Region externalRegionId 'cloud zone region'
    $endpoint = Get-VmText $recorded endpointId
    $datacenter = Get-VmText $recorded datacenter
    if (-not $endpoint) { return $null }
    if ($endpoint -cne $account) { return $false }
    if ($datacenter) {
        if ($datacenter -cne $regionId) { return $false }
    } else {
        # Aria 8.18 may record the region name instead of a datacenter MoRef.
        $recordedRegion = Get-VmText $recorded region
        $regionName = Get-VmText $Cache.Region name
        if (-not $recordedRegion -or -not $regionName) { return $null }
        if ($recordedRegion -cne $regionName) { return $false }
    }
    if ($null -eq $Cache.Computes) {
        $zoneId = Get-VmRequiredText $Zone id 'cloud zone'
        $Cache.Computes = @(Get-VmRecords $Client ("/iaas/api/zones/{0}/computes" -f (ConvertTo-VmIdentifier $zoneId)))
    }
    foreach ($compute in $Cache.Computes) {
        $type = Get-VmText $compute type
        if ($type -ceq 'Cluster') { $type = 'ClusterComputeResource' }
        if (('{0}:{1}' -f $type, (Get-VmText $compute externalId)) -cne $reference) { continue }
        if ((Get-VmText $compute externalRegionId) -cne $regionId) {
            throw [VmInventoryException]::new('Zone compute has a conflicting region')
        }
        $vc = Get-VmText (Get-VmProperties $compute customProperties) vcUuid
        $resourceVc = Get-VmText $recorded vcUuid
        if (-not $vc -or -not $resourceVc) { return $null }
        if ($vc -cne $resourceVc) { throw [VmInventoryException]::new('Zone compute and VM reference different vCenters') }
        return $true
    }
    return $false
}

function Get-VmInventory {
    param($Client, [string]$CloudZone, [Parameter(Mandatory)][IO.StreamWriter]$CsvWriter, [switch]$All)
    $zones = @(Get-VmRecords $Client '/iaas/api/zones' | Where-Object { (Get-VmText $_ name) -ceq $CloudZone })
    if ($zones.Count -ne 1) {
        throw [VmInventoryException]::new("Expected one visible cloud zone named '$CloudZone'; found $($zones.Count)")
    }
    $zoneId = Get-VmRequiredText $zones[0] id 'cloud zone'
    $zone = Get-VmRecord $Client ("/iaas/api/zones/{0}" -f (ConvertTo-VmIdentifier $zoneId))
    if ((Get-VmText $zone id) -cne $zoneId -or (Get-VmText $zone name) -cne $CloudZone) {
        throw [VmInventoryException]::new('Cloud zone changed during lookup; rerun')
    }
    $rowCount = 0
    $unverified = 0
    $incompleteDeployments = 0
    $seen = New-VmSet
    $cache = New-VmPlacementCache
    foreach ($deployment in (Get-VmRecords $Client '/deployment/api/deployments')) {
        $depId = Get-VmRequiredText $deployment id deployment
        $depName = Get-VmRequiredText $deployment name "Deployment $depId"
        $path = '/deployment/api/deployments/{0}/resources' -f (ConvertTo-VmIdentifier $depId)
        try { $candidates = @(Get-VmRecords $Client $path) }
        catch [System.Management.Automation.PipelineStoppedException] { throw }
        catch {
            $failure = Get-VmFailure $_.Exception
            Write-VmLog "Deployment $depId resources could not be read: $($failure.Message)" ERROR
            $incompleteDeployments++
            continue
        }
        foreach ($candidate in $candidates) {
            if (-not (Test-VmResource $candidate)) { continue }
            $resourceId = Get-VmRequiredText $candidate id 'deployment resource'
            try { $resource = Get-VmRecord $Client ("{0}/{1}" -f $path, (ConvertTo-VmIdentifier $resourceId)) }
            catch [System.Management.Automation.PipelineStoppedException] { throw }
            catch {
                $failure = Get-VmFailure $_.Exception
                if (Test-VmApiStatus $failure 404) {
                    Write-VmLog "VM resource $resourceId disappeared; membership unverified" WARNING
                } else {
                    Write-VmLog "VM resource $resourceId could not be verified: $($failure.Message)" ERROR
                }
                $unverified++; continue
            }
            if ((Get-VmText $resource id) -cne $resourceId -or
                (Get-VmText $resource type) -cne (Get-VmText $candidate type)) {
                throw [VmInventoryException]::new('Deployment resource identity/type changed; rerun')
            }
            $recorded = Get-VmProperties $resource properties
            $machineId = Get-VmText $recorded resourceId
            if (-not $machineId) { $machineId = $resourceId }
            $oldId = Get-VmText (Get-VmProperties $candidate properties) resourceId
            if ($oldId -and $oldId -cne $machineId) {
                throw [VmInventoryException]::new('Deployment resource changed its machine association; rerun')
            }
            if (-not $seen.Add($machineId)) {
                throw [VmInventoryException]::new("VM $machineId appears in multiple deployment resources")
            }
            $membership = Get-VmZoneMembership $resource $zone
            if ($null -eq $membership) { $membership = Get-VmComputeMembership $Client $resource $zone $cache }
            if ($membership -ceq $false) { continue }
            if ($null -eq $membership) {
                Write-VmLog "VM resource ${resourceId}: zone membership unverified; excluded" WARNING
                $unverified++; continue
            }
            $status = Get-VmSyncStatus $resource
            if (-not $All -and $status -ine 'missing') { continue }
            $name = Get-VmText $recorded resourceName
            if (-not $name) {
                # The top-level resource name is a blueprint label, not the VM name.
                try { $machine = Get-VmRecord $Client ("/iaas/api/machines/{0}" -f (ConvertTo-VmIdentifier $machineId)) }
                catch [System.Management.Automation.PipelineStoppedException] { throw }
                catch {
                    $failure = Get-VmFailure $_.Exception
                    if (Test-VmApiStatus $failure 404) {
                        Write-VmLog "VM resource $resourceId has no recorded VM name; excluded" WARNING
                    } else {
                        Write-VmLog "VM $machineId name could not be read: $($failure.Message)" ERROR
                    }
                    $unverified++; continue
                }
                if ((Get-VmText $machine id) -cne $machineId) {
                    throw [VmInventoryException]::new('Machine detail returned a different ID')
                }
                $name = Get-VmRequiredText $machine name "VM $machineId"
            }
            $row = [pscustomobject][ordered]@{
                vm_name = $name; deployment_name = $depName; status = $status
                vm_id = $machineId; resource_id = $resourceId; deployment_id = $depId
                cloudzone = $CloudZone; cloudzone_id = $zoneId
                powerStatus = Get-VmPowerStatus $resource
            }
            Write-VmCsvRow $CsvWriter $row
            $rowCount++
        }
    }
    return [pscustomobject]@{
        Count = $rowCount; Unverified = $unverified; IncompleteDeployments = $incompleteDeployments
    }
}

function ConvertTo-VmCsvLine {
    param([object[]]$Values)
    return (($Values | ForEach-Object { '"' + ([string]$_).Replace('"', '""') + '"' }) -join ',')
}

function Open-VmCsv {
    param([string]$Path)
    $writer = [IO.StreamWriter]::new((Resolve-VmPath $Path), $false, [Text.UTF8Encoding]::new($true))
    $writer.AutoFlush = $true
    $writer.WriteLine((ConvertTo-VmCsvLine $script:VmColumns))
    return $writer
}

function Write-VmCsvRow {
    param([IO.StreamWriter]$Writer, $Row)
    $values = foreach ($column in $script:VmColumns) { Get-VmText $Row $column }
    $Writer.WriteLine((ConvertTo-VmCsvLine $values))
}

function Close-VmCsv {
    param([AllowNull()][IO.StreamWriter]$Writer)
    if ($null -ne $Writer) { $Writer.Dispose() }
}

function Write-VmCsv {
    param([string]$Path, [object[]]$Rows)
    $writer = Open-VmCsv $Path
    try {
        foreach ($row in $Rows) { Write-VmCsvRow $writer $row }
    } finally { Close-VmCsv $writer }
}

function Read-VmTargets {
    param([string]$Path)
    Add-Type -AssemblyName Microsoft.VisualBasic
    $reader = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new(
        (Resolve-VmPath $Path), [Text.UTF8Encoding]::new($false, $true), $true)
    $reader.SetDelimiters(',')
    $reader.HasFieldsEnclosedInQuotes = $true
    $reader.TrimWhiteSpace = $false
    $grouped = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $order = [Collections.Generic.List[string]]::new()
    $ids = New-VmSet
    $resourceIds = New-VmSet
    try {
        $columns = $reader.ReadFields()
        $columnSet = New-VmSet
        if ($null -eq $columns) { throw [VmInventoryException]::new('CSV requires enriched inventory columns; regenerate the inventory') }
        foreach ($column in $columns) {
            if (-not $columnSet.Add($column)) { throw [VmInventoryException]::new('CSV contains duplicate columns') }
        }
        foreach ($column in $script:VmColumns) {
            if ($column -ceq 'powerStatus') { continue }
            if (-not $columnSet.Contains($column)) {
                throw [VmInventoryException]::new('CSV requires enriched inventory columns; regenerate the inventory')
            }
        }
        while (-not $reader.EndOfData) {
            $line = $reader.LineNumber
            $values = $reader.ReadFields()
            if ($values.Count -ne $columns.Count) {
                throw [VmInventoryException]::new("CSV line ${line}: column count mismatch")
            }
            $record = [ordered]@{}
            foreach ($column in $script:VmColumns) {
                if ($column -ceq 'powerStatus') {
                    $value = 'unknown'
                    if ($columnSet.Contains($column)) {
                        $value = $values[[Array]::IndexOf($columns, $column)].Trim()
                        if (-not $value) { $value = 'unknown' }
                    }
                    $record[$column] = $value
                    continue
                }
                $value = $values[[Array]::IndexOf($columns, $column)].Trim()
                if (-not $value) { throw [VmInventoryException]::new("CSV line ${line}: all inventory fields must be nonempty") }
                $record[$column] = $value
            }
            $row = [pscustomobject]$record
            if (-not $ids.Add($row.vm_id) -or -not $resourceIds.Add($row.resource_id)) {
                throw [VmInventoryException]::new("CSV line ${line}: duplicate VM or resource ID")
            }
            if (-not $grouped.ContainsKey($row.deployment_id)) {
                $grouped[$row.deployment_id] = [Collections.Generic.List[object]]::new()
                $order.Add($row.deployment_id)
            }
            $grouped[$row.deployment_id].Add($row)
        }
    } finally { $reader.Close() }
    # Validate all groups before emitting any target or authenticating.
    $targets = foreach ($id in $order) {
        $rows = $grouped[$id].ToArray()
        foreach ($row in $rows) {
            if ($row.deployment_name -cne $rows[0].deployment_name) {
                throw [VmInventoryException]::new("CSV: inconsistent names for deployment $id")
            }
            if ($row.cloudzone_id -cne $rows[0].cloudzone_id -or $row.cloudzone -cne $rows[0].cloudzone) {
                throw [VmInventoryException]::new("CSV: deployment $id spans multiple cloud zones")
            }
        }
        [pscustomobject]@{ DeploymentId = $id; Rows = $rows }
    }
    return $targets
}

function Get-VmResourceSet {
    param([object[]]$Resources)
    $set = New-VmSet
    foreach ($resource in $Resources) {
        # JSON encodes the pair unambiguously, even if IDs or types contain delimiters.
        $pair = @((Get-VmText $resource id), (Get-VmText $resource type))
        [void]$set.Add((ConvertTo-Json -InputObject $pair -Compress))
    }
    return ,$set
}

function Assert-VmTarget {
    param($Client, $Target)
    $first = $Target.Rows[0]
    $depPath = '/deployment/api/deployments/{0}' -f (ConvertTo-VmIdentifier $Target.DeploymentId)
    $deployment = Get-VmRecord $Client $depPath
    if ((Get-VmText $deployment id) -cne $Target.DeploymentId) { throw [VmCheckFailedException]::new('Deployment ID mismatch') }
    if ((Get-VmText $deployment name) -cne $first.deployment_name) {
        throw [VmCheckFailedException]::new('Deployment name changed since CSV export')
    }
    $zone = Get-VmRecord $Client ('/iaas/api/zones/{0}' -f (ConvertTo-VmIdentifier $first.cloudzone_id))
    if ((Get-VmText $zone id) -cne $first.cloudzone_id -or (Get-VmText $zone name) -cne $first.cloudzone) {
        throw [VmCheckFailedException]::new('Cloud-zone identity/name changed since CSV export')
    }
    $path = $depPath + '/resources'
    $candidates = @(Get-VmRecords $Client $path)
    $expected = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($row in $Target.Rows) { $expected[$row.resource_id] = $row }
    $vms = @()
    $actualIds = New-VmSet
    foreach ($candidate in $candidates) {
        $null = Get-VmRequiredText $candidate type 'Deployment resource'
        if (Test-VmResource $candidate) {
            $vms += $candidate
            [void]$actualIds.Add((Get-VmRequiredText $candidate id $path))
        }
    }
    if (-not $actualIds.Count -or -not $actualIds.SetEquals($expected.Keys)) {
        throw [VmCheckFailedException]::new('Current deployment VM set differs from CSV (extra, missing or changed VMs)')
    }
    # Placement data is fresh for each queued deployment, cached only within that validation.
    $cache = New-VmPlacementCache
    foreach ($candidate in $vms) {
        $resourceId = Get-VmText $candidate id
        $row = $expected[$resourceId]
        $resource = Get-VmRecord $Client ('{0}/{1}' -f $path, (ConvertTo-VmIdentifier $resourceId))
        if ((Get-VmText $resource id) -cne $resourceId -or
            (Get-VmText $resource type) -cne (Get-VmText $candidate type)) {
            throw [VmCheckFailedException]::new("VM resource ${resourceId}: identity/type changed")
        }
        $machineId = Get-VmText (Get-VmProperties $resource properties) resourceId
        if (-not $machineId) { $machineId = $resourceId }
        if ($machineId -cne $row.vm_id) { throw [VmCheckFailedException]::new("VM resource ${resourceId}: VM identity changed") }
        if ((Get-VmSyncStatus $resource) -ine 'missing') {
            throw [VmCheckFailedException]::new("VM $($row.vm_id): current syncStatus is not Missing")
        }
        $membership = Get-VmZoneMembership $resource $zone -AllowNames $false
        $compute = Get-VmComputeMembership $Client $resource $zone $cache
        if ($membership -ceq $false -or $compute -ceq $false) {
            throw [VmCheckFailedException]::new("VM $($row.vm_id): no longer connected to the CSV cloud zone")
        }
        if ($membership -cne $true -and $compute -cne $true) {
            throw [VmCheckFailedException]::new("VM $($row.vm_id): cloud-zone membership cannot be verified")
        }
    }
    # Unregister only removes VMs from management; it is used when every VM offers it.
    $steps = @(foreach ($candidate in $vms) {
        $resourceId = Get-VmText $candidate id
        $actionId = Get-VmUnregisterAction (Get-VmResourceActions $Client $Target.DeploymentId $resourceId)
        if (-not $actionId) { break }
        [pscustomobject]@{ ResourceId = $resourceId; ActionId = $actionId }
    })
    if ($steps.Count -eq $vms.Count) {
        $plan = New-VmRemovalPlan unregister $steps
    } else {
        # Deployment.Delete deprovisions every resource, so each one must be Missing too.
        foreach ($candidate in $candidates) {
            if (Test-VmResource $candidate) { continue }
            $resourceId = Get-VmRequiredText $candidate id $path
            $type = Get-VmText $candidate type
            $resource = Get-VmRecord $Client ('{0}/{1}' -f $path, (ConvertTo-VmIdentifier $resourceId))
            if ((Get-VmText $resource id) -cne $resourceId -or (Get-VmText $resource type) -cne $type) {
                throw [VmCheckFailedException]::new("Resource ${resourceId}: identity/type changed")
            }
            if ((Get-VmSyncStatus $resource) -ine 'missing') {
                throw [VmCheckFailedException]::new("Resource $resourceId ($type) is not Missing; deployment delete refused")
            }
        }
        $plan = New-VmRemovalPlan delete
    }
    $latest = @(Get-VmRecords $Client $path)
    if (-not (Get-VmResourceSet $candidates).SetEquals((Get-VmResourceSet $latest))) {
        throw [VmCheckFailedException]::new('Deployment resources changed during validation')
    }
    return $plan
}

function New-VmRemovalPlan {
    param([ValidateSet('unregister', 'delete')][string]$Method = 'delete', [object[]]$Steps = @())
    if ($Method -ceq 'delete') { $Steps = @([pscustomobject]@{ ResourceId = ''; ActionId = 'Deployment.Delete' }) }
    return [pscustomobject]@{ Method = $Method; Steps = $Steps }
}

function Get-VmResourceActions {
    param($Client, [string]$DeploymentId, [string]$ResourceId)
    $path = '/deployment/api/deployments/{0}/resources/{1}/actions' -f
        (ConvertTo-VmIdentifier $DeploymentId), (ConvertTo-VmIdentifier $ResourceId)
    $body = (Invoke-VmRequest $Client GET $path).Body
    $trimmed = ([string]$body).TrimStart()
    if ($trimmed.StartsWith('{')) {
        $items = Get-VmValue (ConvertFrom-VmJson $body $path) content
        if ($items -isnot [array]) { throw [VmInventoryException]::new("${path}: expected a content array") }
    } elseif ($trimmed.StartsWith('[')) {
        try { $parsed = ConvertFrom-Json -InputObject $body -ErrorAction Stop }
        catch { throw [VmInventoryException]::new("${path}: invalid JSON response") }
        # Windows PowerShell emits a top-level JSON array as one object; unroll it.
        $items = @(foreach ($item in $parsed) { $item })
    } else {
        throw [VmInventoryException]::new("${path}: invalid JSON response")
    }
    return @(foreach ($item in $items) { Assert-VmObject $item $path })
}

function Get-VmUnregisterAction {
    param([object[]]$Actions)
    $found = @(foreach ($action in $Actions) {
        $id = Get-VmText $action id
        if (($id -and ($id -split '\.')[-1] -ieq 'Unregister') -or (Get-VmText $action name) -ieq 'Unregister') { $action }
    })
    # Absent, ambiguous or currently disallowed Unregister actions are treated as unavailable.
    if ($found.Count -ne 1) { return '' }
    if ((Get-VmValue $found[0] valid) -ceq $false) { return '' }
    return Get-VmText $found[0] id
}

function Submit-VmDelete {
    param($Client, $Target)
    $path = '/deployment/api/deployments/{0}/requests' -f (ConvertTo-VmIdentifier $Target.DeploymentId)
    $body = ConvertTo-Json -Compress -InputObject @{
        actionId = 'Deployment.Delete'; inputs = @{}
        reason = 'CSV cleanup: all deployment VMs verified Missing in the recorded cloud zone'
    }
    $reply = Invoke-VmRequest $Client POST $path -Body $body -Headers @{ 'Content-Type' = 'application/json' }
    return Get-VmRequiredText (ConvertFrom-VmJson $reply.Body $path) id 'Delete request response'
}

function Submit-VmUnregister {
    param($Client, $Target, $Step)
    $path = '/deployment/api/deployments/{0}/resources/{1}/requests' -f
        (ConvertTo-VmIdentifier $Target.DeploymentId), (ConvertTo-VmIdentifier $Step.ResourceId)
    $body = ConvertTo-Json -Compress -InputObject @{
        actionId = $Step.ActionId; inputs = @{}
        reason = 'CSV cleanup: VM verified Missing in the recorded cloud zone; unregister only'
    }
    $reply = Invoke-VmRequest $Client POST $path -Body $body -Headers @{ 'Content-Type' = 'application/json' }
    return Get-VmRequiredText (ConvertFrom-VmJson $reply.Body $path) id 'Unregister request response'
}

function Get-VmDeletionOutcome {
    param($Client, $Outstanding)
    $record = Get-VmRecord $Client ('/deployment/api/requests/{0}' -f (ConvertTo-VmIdentifier $Outstanding.RequestId))
    if ((Get-VmText $record id) -cne $Outstanding.RequestId) {
        throw [VmInventoryException]::new('Request status returned a different request ID')
    }
    $depId = Get-VmText $record deploymentId
    if ($depId -and $depId -cne $Outstanding.Target.DeploymentId) {
        throw [VmInventoryException]::new('Request status returned a different deployment ID')
    }
    $step = Get-VmValue $Outstanding Step
    $expectedAction = 'Deployment.Delete'
    if ($null -ne $step -and $step.ResourceId) { $expectedAction = $step.ActionId }
    $action = Get-VmText $record actionId
    if ($action -and $action -cne $expectedAction) {
        throw [VmInventoryException]::new('Request status returned a different action')
    }
    $status = (Get-VmRequiredText $record status 'Request status').ToUpperInvariant()
    if ($status -cin @('FAILED', 'ABORTED', 'APPROVAL_REJECTED', 'CANCELLED', 'CANCELED')) {
        Write-VmLog "Request $($Outstanding.RequestId) reached terminal failure status $status" ERROR
        return 'failed'
    }
    if ($status -ceq 'SUCCESSFUL') {
        # Request success alone is insufficient: the deployment or unregistered VM must actually disappear.
        $gone = '/deployment/api/deployments/{0}' -f (ConvertTo-VmIdentifier $Outstanding.Target.DeploymentId)
        if ($expectedAction -cne 'Deployment.Delete') { $gone += '/resources/' + (ConvertTo-VmIdentifier $step.ResourceId) }
        try { $null = Get-VmRecord $Client $gone }
        catch {
            if (Test-VmApiStatus $_.Exception 404) { return 'successful' }
            throw
        }
        Write-VmLog "Request $($Outstanding.RequestId) successful; waiting for resource disappearance"
    } elseif ($status -cnotin @('CREATED', 'PENDING', 'INITIALIZATION', 'CHECKING_APPROVAL',
        'APPROVAL_PENDING', 'USER_INTERACTION_PENDING', 'INPROGRESS', 'COMPLETION')) {
        Write-VmLog "Request $($Outstanding.RequestId): unrecognized status $status; retaining slot" WARNING
    }
    return 'pending'
}

function New-VmStatistics {
    return [pscustomobject]@{
        Successful = 0; Failures = 0; Skipped = 0; TimedOut = 0
        Eligible = 0; Submitted = 0; Processed = 0; Unregistered = 0; Deleted = 0
    }
}

function Start-VmPlanStep {
    param($Client, $Outstanding, $RequestIds, $Statistics)
    $target = $Outstanding.Target
    $step = $Outstanding.Step
    $Outstanding.Started = Get-VmMonotonicTime
    try {
        if ($Outstanding.Plan.Method -ceq 'unregister') { $requestId = Submit-VmUnregister $Client $target $step }
        else { $requestId = Submit-VmDelete $Client $target }
        if (-not $RequestIds.Add($requestId)) { throw [VmInventoryException]::new('Server returned a duplicate request ID') }
    } catch {
        $Statistics.Failures++
        Write-VmLog ("FAILED {0} submission for deployment {1}: {2}. Outcome may be uncertain; check the server before retrying. No automatic resubmission." -f
            $Outstanding.Plan.Method, $target.DeploymentId, (Get-VmFailure $_.Exception).Message) ERROR
        return $false
    }
    $Outstanding.RequestId = $requestId
    if ($Outstanding.Plan.Method -ceq 'unregister') {
        Write-VmLog "SUBMITTED unregister ($($step.ActionId)) of VM resource $($step.ResourceId) in deployment $($target.DeploymentId) request $requestId"
    } else {
        Write-VmLog "SUBMITTED delete of deployment $($target.DeploymentId) request $requestId"
    }
    return $true
}

function Update-VmProcessedProgress {
    param($Statistics, $Target, [int]$Total)
    $Statistics.Processed += @($Target.Rows).Count
    Write-Progress -Activity 'Processing VMs' `
        -Status ("{0}/{1} VMs processed" -f $Statistics.Processed, $Total) `
        -PercentComplete ([int](100 * $Statistics.Processed / $Total))
}

function Get-VmMonotonicTime {
    return [Diagnostics.Stopwatch]::GetTimestamp() / [double][Diagnostics.Stopwatch]::Frequency
}

function Wait-VmPoll {
    param([double]$Seconds)
    if ($Seconds -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Min([int]::MaxValue, [Math]::Ceiling($Seconds * 1000))) }
}

function Invoke-VmDeletionQueue {
    param($Client, [object[]]$Targets, [switch]$Execute,
          [int]$Parallel = 5, [double]$PollInterval = 5, [double]$RequestTimeout = 300,
          $Statistics = (New-VmStatistics))
    foreach ($limit in @($Parallel, $PollInterval, $RequestTimeout)) {
        if ($limit -le 0 -or [double]::IsNaN($limit) -or [double]::IsInfinity($limit)) {
            throw [VmInventoryException]::new('Chalkboard limits must be finite and positive')
        }
    }
    $queue = [Collections.Generic.Queue[object]]::new()
    $totalVms = 0
    foreach ($target in $Targets) {
        $queue.Enqueue($target)
        $totalVms += @($target.Rows).Count
    }
    $board = [Collections.Generic.List[object]]::new()
    $requestIds = New-VmSet
    try {
    while ($queue.Count -or $board.Count) {
        while ($queue.Count -and $board.Count -lt $Parallel) {
            $target = $queue.Dequeue()
            # Revalidate only when a slot becomes available, not when the queue is built.
            try {
                $plan = Assert-VmTarget $Client $target
                if ((Get-VmText $plan Method) -cnotin @('unregister', 'delete') -or -not @($plan.Steps).Count) {
                    throw [VmInventoryException]::new('Validation produced no removal plan')
                }
            }
            catch {
                $failure = Get-VmFailure $_.Exception
                if ($failure -is [VmCheckFailedException]) {
                    $Statistics.Skipped++
                    Write-VmLog "SKIPPED deployment $($target.DeploymentId): $($failure.Message)" WARNING
                } else {
                    $Statistics.Failures++
                    Write-VmLog "FAILED verification for deployment $($target.DeploymentId): $($failure.Message)" ERROR
                }
                Update-VmProcessedProgress $Statistics $target $totalVms
                continue
            }
            $Statistics.Eligible++
            if (-not $Execute) {
                if ($plan.Method -ceq 'unregister') {
                    Write-VmLog ("DRY RUN: deployment {0} ({1}): {2} VM(s) would be unregistered; nothing submitted" -f
                        $target.DeploymentId, $target.Rows[0].deployment_name, @($plan.Steps).Count)
                } else {
                    Write-VmLog "DRY RUN: deployment $($target.DeploymentId) ($($target.Rows[0].deployment_name)) would be deleted; no delete submitted"
                }
                Update-VmProcessedProgress $Statistics $target $totalVms
                continue
            }
            $outstanding = [pscustomobject]@{
                Target = $target; Plan = $plan; StepIndex = 0; Step = $plan.Steps[0]; RequestId = ''; Started = 0
            }
            if (-not (Start-VmPlanStep $Client $outstanding $requestIds $Statistics)) {
                Update-VmProcessedProgress $Statistics $target $totalVms
                continue
            }
            $Statistics.Submitted++
            $board.Add($outstanding)
        }
        foreach ($outstanding in $board.ToArray()) {
            $elapsed = (Get-VmMonotonicTime) - $outstanding.Started
            if ($elapsed -ge $RequestTimeout) {
                # Expiring local tracking does not cancel an operation already running on the server.
                $Statistics.Failures++; $Statistics.TimedOut++
                Write-VmLog "TIMED OUT deployment $($outstanding.Target.DeploymentId) request $($outstanding.RequestId) after ${elapsed}s; removed from chalkboard. Server operation is NOT cancelled and may still complete." ERROR
                [void]$board.Remove($outstanding)
                Update-VmProcessedProgress $Statistics $outstanding.Target $totalVms
                continue
            }
            try { $outcome = Get-VmDeletionOutcome $Client $outstanding }
            catch {
                Write-VmLog ("POLL ERROR request {0}: {1}; retaining slot until completion/timeout" -f
                    $outstanding.RequestId, (Get-VmFailure $_.Exception).Message) ERROR
                continue
            }
            if ($outcome -cne 'pending') {
                $target = $outstanding.Target
                if ($outcome -ceq 'successful' -and $outstanding.Plan.Method -ceq 'unregister') {
                    Write-VmLog "UNREGISTERED VM resource $($outstanding.Step.ResourceId) in deployment $($target.DeploymentId) request $($outstanding.RequestId)"
                    if ($outstanding.StepIndex + 1 -lt @($outstanding.Plan.Steps).Count) {
                        # Submit the next VM only after the previous request finished on this deployment.
                        $outstanding.StepIndex++
                        $outstanding.Step = $outstanding.Plan.Steps[$outstanding.StepIndex]
                        if (Start-VmPlanStep $Client $outstanding $requestIds $Statistics) { continue }
                        [void]$board.Remove($outstanding)
                        Update-VmProcessedProgress $Statistics $target $totalVms
                        continue
                    }
                }
                [void]$board.Remove($outstanding)
                if ($outcome -ceq 'successful') {
                    $Statistics.Successful++
                    if ($outstanding.Plan.Method -ceq 'unregister') {
                        $Statistics.Unregistered++
                        Write-VmLog "COMPLETED unregister of all VMs in deployment $($target.DeploymentId)"
                    } else {
                        $Statistics.Deleted++
                        Write-VmLog "DELETED deployment $($target.DeploymentId) request $($outstanding.RequestId)"
                    }
                } else {
                    $Statistics.Failures++
                    Write-VmLog ("FAILED {0} deployment {1} request {2}" -f
                        $outstanding.Plan.Method, $target.DeploymentId, $outstanding.RequestId) ERROR
                }
                Update-VmProcessedProgress $Statistics $target $totalVms
            }
        }
        if ($board.Count -and -not ($queue.Count -and $board.Count -lt $Parallel)) {
            $now = Get-VmMonotonicTime
            $remaining = ($board | ForEach-Object { $RequestTimeout - ($now - $_.Started) } | Measure-Object -Minimum).Minimum
            Wait-VmPoll ([Math]::Max(0, [Math]::Min($PollInterval, $remaining)))
        }
    }
    } finally {
        if ($totalVms -gt 0) { Write-Progress -Activity 'Processing VMs' -Completed }
    }
    return $Statistics
}

function Invoke-VmInventoryCommand {
    param([hashtable]$Options, [string]$CloudZone, [string]$Output, [switch]$All)
    $tlsState = $null
    $csvWriter = $null
    try {
        $tlsState = Start-VmTlsScope $Options
        $client = New-VmClient $Options
        $csvWriter = Open-VmCsv $Output
        $inventory = Get-VmInventory $client $CloudZone $csvWriter -All:$All
        Write-VmLog "Wrote $($inventory.Count) verified VM(s) to $Output"
        $incompleteDeployments = Get-VmValue $inventory IncompleteDeployments
        if ($null -eq $incompleteDeployments) { $incompleteDeployments = 0 }
        if ($inventory.Unverified -or $incompleteDeployments) {
            Write-VmLog ("INCOMPLETE: {0} VM(s) could not be verified; {1} deployment resource list(s) could not be read" -f
                $inventory.Unverified, $incompleteDeployments) ERROR
            return 2
        }
        return 0
    } catch [System.Management.Automation.PipelineStoppedException] {
        Write-VmLog 'Interrupted' ERROR
        return 130
    } catch {
        Write-VmLog (Get-VmFailure $_.Exception).Message ERROR
        return 1
    } finally {
        Close-VmCsv $csvWriter
        Stop-VmTlsScope $tlsState
    }
}

function Invoke-VmDeleteCommand {
    param([hashtable]$Options, [string]$InputCsv, [string]$LogFile, [switch]$Execute,
          [int]$Parallel = 5, [double]$PollInterval = 5, [double]$RequestTimeout = 300)
    $stats = New-VmStatistics
    $code = 1
    $completed = $false
    $tlsState = $null
    try {
        if ((Resolve-VmPath $LogFile) -eq (Resolve-VmPath $InputCsv)) {
            throw [VmInventoryException]::new('LogFile must not overwrite the input CSV')
        }
        Open-VmLog $LogFile
        try {
            # Reject malformed CSV input before authentication or any destructive request.
            $targets = @(Read-VmTargets $InputCsv)
            $mode = 'DRY RUN'
            if ($Execute) { $mode = 'EXECUTE' }
            Write-VmLog "Loaded $($targets.Count) deployments; mode=$mode, slots=$Parallel"
            if ($targets.Count) {
                $tlsState = Start-VmTlsScope $Options
                $client = New-VmClient $Options
                $null = Invoke-VmDeletionQueue $client $targets -Execute:$Execute -Parallel $Parallel `
                    -PollInterval $PollInterval -RequestTimeout $RequestTimeout -Statistics $stats
            }
            $completed = $true
        } catch [System.Management.Automation.PipelineStoppedException] {
            Write-VmLog 'Interrupted; server requests are not cancelled. Consult the SUBMITTED entries before retrying.' ERROR
            $code = 130
        } catch {
            $stats.Failures++
            Write-VmLog ('FAILED: ' + (Get-VmFailure $_.Exception).Message) ERROR
        } finally {
            Write-VmLog ("SUMMARY successful={0} failures={1} skipped={2} timed_out={3} eligible={4} submitted={5} processed={6} unregistered={7} deleted={8}" -f
                $stats.Successful, $stats.Failures, $stats.Skipped, $stats.TimedOut, $stats.Eligible, $stats.Submitted, $stats.Processed,
                $stats.Unregistered, $stats.Deleted)
        }
        if ($completed) {
            $code = 0
            if ($stats.Failures) { $code = 1 }
            elseif ($stats.Skipped) { $code = 2 }
        }
    } catch {
        Write-VmLog (Get-VmFailure $_.Exception).Message ERROR
    } finally {
        Stop-VmTlsScope $tlsState
        Close-VmLog
    }
    return $code
}

Export-ModuleMember -Function *-Vm*
