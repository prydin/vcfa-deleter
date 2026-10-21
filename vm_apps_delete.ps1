#Requires -Version 5.1
<#
.SYNOPSIS
Safely delete Missing VM Apps deployments from an enriched inventory CSV.
.DESCRIPTION
Validates every VM immediately before submission. Without -Execute, reports
what would be deleted. Requires VmApps.Common.psm1 beside this script.
TLS certificates are validated by default. -Insecure disables validation; use it
only in a trusted environment and a dedicated PowerShell process.
Use -Debug to print the elapsed time of each API call.
Use -Legacy for on-premises Aria Automation 8.18 authentication. Optional -Domain
selects the identity domain for legacy username/password login; do not use -Org.
.EXAMPLE
.\vm_apps_delete.ps1 -Server vcfa.example.com -Org MyOrganization -InputCsv .\vms.csv
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][Alias('Host')][string]$Server,
    [Alias('api-token')][string]$ApiToken = $env:VCFA_API_TOKEN,
    [string]$Username,
    [AllowNull()][object]$Password = $env:VCFA_PASSWORD,
    [string]$Org,
    [switch]$Legacy,
    [string]$Domain,
    [switch]$Insecure,
    [Alias('api-version')][string]$ApiVersion = '2021-07-15',
    [Alias('cloudapi-version')][string]$CloudApiVersion = '40.0',
    [Alias('page-size')][ValidateRange(1, 2147483647)][int]$PageSize = 100,
    [ValidateScript({ $_ -gt 0 -and -not [double]::IsInfinity($_) })][double]$Timeout = 60,
    [Parameter(Mandatory)][Alias('Input')][string]$InputCsv,
    [switch]$Execute,
    [ValidateRange(1, 2147483647)][int]$Parallel = 5,
    [Alias('poll-interval')][ValidateScript({ $_ -gt 0 -and -not [double]::IsInfinity($_) })][double]$PollInterval = 5,
    [Alias('request-timeout')][ValidateScript({ $_ -gt 0 -and -not [double]::IsInfinity($_) })][double]$RequestTimeout = 300,
    [Alias('log-file')][string]$LogFile = 'deployment-deletions.log'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# -Debug only enables API timing; avoid PowerShell 5.1's Inquire prompts.
$debugTiming = [bool]$PSBoundParameters['Debug']
$DebugPreference = 'SilentlyContinue'
Import-Module (Join-Path $PSScriptRoot 'VmApps.Common.psm1') -DisableNameChecking -Force
$options = @{
    Server = $Server; ApiToken = $ApiToken; Username = $Username; Password = $Password
    Org = $Org; Legacy = $Legacy; Domain = $Domain; Insecure = $Insecure
    ApiVersion = $ApiVersion; CloudApiVersion = $CloudApiVersion
    PageSize = $PageSize; Timeout = $Timeout; Debug = $debugTiming
}
$code = Invoke-VmDeleteCommand $options $InputCsv $LogFile -Execute:$Execute -Parallel $Parallel `
    -PollInterval $PollInterval -RequestTimeout $RequestTimeout
exit $code
