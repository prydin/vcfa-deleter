#Requires -Version 5.1
<#
.SYNOPSIS
Export VM Apps resources with individually verified cloud-zone membership.
.DESCRIPTION
Only top-level syncStatus MISSING is exported by default. Use -All for every
synchronization status. Requires VmApps.Common.psm1 beside this script.
The unregisterAvailable CSV column reports live action availability for information
only; an unreadable action list is reported as unknown and does not exclude the VM.
TLS certificates are validated by default. -Insecure disables validation; use it
only in a trusted environment and a dedicated PowerShell process.
Use -Debug to print the elapsed time of each API call.
Use -Legacy for on-premises Aria Automation 8.18 authentication. Optional -Domain
selects the identity domain for legacy username/password login; do not use -Org.
.EXAMPLE
.\vm_apps_inventory.ps1 -Server vcfa.example.com -Org MyOrganization -CloudZone Production
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
    [Parameter(Mandatory)][string]$CloudZone,
    [string]$Output = 'vm_inventory.csv',
    [switch]$All
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
$code = Invoke-VmInventoryCommand $options $CloudZone $Output -All:$All
exit $code
