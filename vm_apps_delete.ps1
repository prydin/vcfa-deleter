#Requires -Version 5.1
<#
.SYNOPSIS
Safely delete Missing VM Apps deployments from an enriched inventory CSV.
.DESCRIPTION
Validates every VM immediately before submission. Removal is unregister-only by
default: if every VM offers an Unregister action, the VMs are unregistered one
at a time and the deployment is left in place; otherwise the deployment is
skipped. With -AllowDelete, such deployments are deleted instead, but only if
every resource, including non-VM resources, is Missing. Without -Execute,
reports what would be done. Requires VmApps.Common.psm1 beside this script.
-DeleteNonMissingVMs (DANGEROUS) also accepts VMs and resources that are not
Missing, for example after their vCenter was decommissioned. It requires typing
"Yes I am absolutely sure I want this", and each such resource must belong to
the cloud zone's vSphere cloud account, which must report healthy=false after a
fresh health check run by this script. Otherwise the deployment is skipped.
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
    [Alias('allow-delete')][switch]$AllowDelete,
    [Alias('delete-non-missing-vms')][switch]$DeleteNonMissingVMs,
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
$code = Invoke-VmDeleteCommand $options $InputCsv $LogFile -Execute:$Execute -AllowDelete:$AllowDelete `
    -DeleteNonMissingVMs:$DeleteNonMissingVMs -Parallel $Parallel `
    -PollInterval $PollInterval -RequestTimeout $RequestTimeout
exit $code
