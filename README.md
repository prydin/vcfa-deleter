# VM Apps cloud-zone inventory

**Development focus:** the PowerShell versions are actively maintained. The
Python scripts and tests are retained in place as a frozen reference.
Start with [PowerShell versions](#powershell-versions) for current usage.

[vm_apps_inventory.py](vm_apps_inventory.py) is a read-only Python CLI intended
for VCF Automation 9.1.1 VM Apps organization inventory. It does not delete,
refresh, power on, or otherwise modify VMs. POST requests are used only for
authentication. Python 3.10+ is required; there are no third-party dependencies.

## Usage

Run with an organization API token (a refresh token, **not** an existing bearer
access token):

```powershell
$env:VCFA_API_TOKEN = '<organization-api-token>'
python .\vm_apps_inventory.py --host vcfa.example.com --org MyOrganization --cloudzone "Production" --output .\production-vms.csv
```

Native PowerShell versions are also available; see
[PowerShell versions](#powershell-versions) below.

Alternatively, supply `--api-token` explicitly. Environment variables avoid
placing credentials in command-line history and process arguments.

Only managed VMs belonging to visible deployments are included. Inventory starts
with deployments, not the full IaaS machine inventory, so discovered VMs are
never scanned. The former `--discovered` option has been removed.

By default, only VMs whose top-level `syncStatus` is **MISSING** are exported.
Add `--all` to include VMs of any status, including unknown, while retaining
the same deployment and cloud-zone checks:

```powershell
python .\vm_apps_inventory.py --host vcfa.example.com --org MyOrganization --cloudzone "Production" --output .\production-vms.csv --all
```

For username/password authentication:

```powershell
python .\vm_apps_inventory.py --host vcfa.example.com --org MyOrganization --username administrator --cloudzone "Production" --output .\production-vms.csv
```

The password is prompted securely. `--password` and `VCFA_PASSWORD` are also
supported. Without `--org`, use an organization-qualified username such as
`administrator@MyOrganization`. With `--org`, the organization suffix is
appended unless already present, including for an identity-provider username
that itself contains `@`.

Use an organization account with read access to **all** relevant zones, machines,
deployments and deployment resources. The tool cannot discover resources hidden
from that account. Provider/system authentication is not used.

TLS certificate verification is enabled. Use `--ca-bundle .\organization-ca.pem`
for a private CA. `--insecure` explicitly disables verification and logs a
warning; it should be used only for controlled troubleshooting.

Other options:

- `--page-size` (default `100`).
- `--timeout` in seconds per HTTP request (default `60`).
- `--api-version` for IaaS (default `2021-07-15`).
- `--cloudapi-version` for organization session login (default `40.0`).
- `--output` (default `vm_inventory.csv`).

## Aria Automation 8.18 compatibility (Python reference)

Both Python scripts accept `--legacy` for **on-premises Aria Automation 8.18**
authentication. Without this flag they retain the VCF Automation 9.1.1 flow.
For PowerShell, use `-Legacy` as described in
[PowerShell versions](#powershell-versions).

With `--legacy`, `--api-token` (or `VCFA_API_TOKEN`) must contain an **Aria
refresh token**, not an access token or a VCF organization token. It is exchanged
using `POST /iaas/api/login` with JSON `{"refreshToken":"..."}`; the response's
`token` is used for subsequent Bearer authentication. No `--org` is required.

```powershell
$env:VCFA_API_TOKEN = '<aria-refresh-token>'
python .\vm_apps_inventory.py --legacy --host aria.example.com --cloudzone "Production" --output .\legacy-vms.csv
python .\vm_apps_delete.py --legacy --host aria.example.com --input .\legacy-vms.csv
```

Alternatively, supply `--username` and optionally `--password`/`VCFA_PASSWORD`.
Omitting the password prompts securely. Remove `VCFA_API_TOKEN` first if using
username/password:

```powershell
Remove-Item Env:VCFA_API_TOKEN -ErrorAction SilentlyContinue
python .\vm_apps_inventory.py --legacy --host aria.example.com --username administrator --domain example.com --cloudzone "Production" --output .\legacy-vms.csv
python .\vm_apps_delete.py --legacy --host aria.example.com --username administrator --domain example.com --input .\legacy-vms.csv
```

This first sends JSON `username`, `password` and optional `domain` to
`POST /csp/gateway/am/api/login?access_token=`, then exchanges the returned
`refresh_token` through `/iaas/api/login`. Usernames are sent unchanged;
`--domain` is optional and is not appended to the username. `--org` is rejected
in legacy mode to avoid silently confusing an organization with an identity
domain. `--domain` is accepted only with `--legacy --username`.
The VCF-specific `--cloudapi-version` is unused in legacy mode.

TLS remains verified by default in both Python modes; the existing `--ca-bundle`
and explicit `--insecure` options still apply. No automatic authentication
fallback or retry is performed on authentication failures.

Legacy mode changes authentication only. CSV layout, Missing-only filtering,
fresh cloud-zone/VM validation and deletion safeguards are unchanged. The
existing IaaS API version (`2021-07-15`) remains configurable using `--api-version`.
Deletion still defaults to dry run; `--execute` is required to submit requests.
Missing or incompatible resource data fails closed rather than relaxing checks.

Legacy authentication and both CLI integrations are covered by mocked tests.
This has **not been validated against a live Aria Automation 8.18 system**;
first run inventory and review a deletion dry run before considering execution.
Authentication shapes follow the public
[VMware Aria refresh-token guide](https://github.com/vmware/terraform-provider-vra/blob/master/docs/refresh_token_vra.md)
and [IaaS API schema](https://github.com/vmware/vra-sdk-go/blob/master/swagger/vra-iaas.json).

### Checking legacy region placement fields

If inventory reports `zone membership unverified`, the read-only
[vm_apps_check_region.py](vm_apps_check_region.py) helper prints the selected
zone's region `id`, `name`, `externalRegionId` and `cloudAccountId`:

```powershell
python .\vm_apps_check_region.py --legacy --host aria.example.com --username administrator --domain example.com --cloudzone "Production"
```

It supports the same connection/authentication/TLS options as both Python
scripts. Output is JSON on stdout; credentials and unrelated API fields are
not printed. Missing region fields appear as empty strings. This helper does
not change membership rules or modify resources; it helps compare an Aria
VM's recorded region name with the cloud zone's provider region identifiers.

## Verification and output

1. Resolve the exact, case-sensitive cloud-zone name. Zero matches or duplicate
   visible names are errors.
2. Enumerate visible deployments and each deployment's resources, with
   pagination. Select only `Cloud.*.Machine` resource types, not networks or disks.
   Deployments are not filtered by zone: a deployment can span multiple zones.
3. GET each selected VM resource again; do not trust resource-list properties
   for inclusion, VM name, or synchronization status. Decide membership using its explicit zone ID
   (`zoneId`/`cloudZoneId` or a zone link), or its explicit zone name
   (`zone`/`zoneName`/`cloudZoneName`). These fields may be top-level, in
   `customProperties`, or in deployment-resource `properties`. IDs take priority
   over display names. A resource `zone` accompanied by `computeHostRef` is a
   compute/resource-pool label, **not** a cloud-zone name.
4. When an explicit cloud-zone association is absent, compare the resource's
   recorded `computeHostRef` with the selected zone's `/computes` members.
   Match provider compute type and external ID, and verify the resource's
   cloud account (`endpointId`), external region (`datacenter`), and
   compute/resource vCenter UUID. Region and compute membership are cached
   once per run. A region
   match alone never proves membership. For Aria 8.18 records without
   `datacenter`, match `properties.region` exactly against the fetched zone
   region's `name` instead. The compute member must still match that region's
   `externalRegionId`, the VM's cloud account and vCenter UUID. An explicit
   conflicting `datacenter` is never overridden by a matching region name.
   This shared fallback also applies during deletion validation in both languages.
   References to computes outside the
   zone's returned member list are excluded; no parent-cluster membership is
   inferred from names or resource-pool paths.
5. Use the enclosing deployment's name and the fresh resource's
   `properties.resourceName` for the VM name (the top-level resource name is
   usually a blueprint component label). Only if the VM name is absent, GET that
   individual IaaS machine by `properties.resourceId`, or the resource ID when
   no separate machine ID is recorded. No IaaS machine collection is requested.
6. Read only the fresh resource's top-level `syncStatus`. A value of `MISSING`
   (case-insensitive) produces `missing`; other values, such as `SUCCESS`, are
   preserved. An absent, empty or invalid `syncStatus` logs a warning and
   produces `unknown`. Export only `missing` rows by default; `--all` includes
   every synchronization status. Power state and guessed missing indicators
   are not read.

The CSV contains display fields plus stable identities needed by the deletion
tool. Regenerate older three-column files before using them for deletion.
This example shows output with `--all`; the default omits the `SUCCESS` row:

```csv
vm_name,deployment_name,status,vm_id,resource_id,deployment_id,cloudzone,cloudzone_id
web-01,Production Web,SUCCESS,vm-id-1,resource-id-1,deployment-id-1,Production,zone-id-1
lost-vm,Old Deployment,missing,vm-id-2,resource-id-2,deployment-id-2,Production,zone-id-1
```

`vm_id` comes from `properties.resourceId` (or the deployment resource ID
when no separate VM ID is recorded). `resource_id` identifies the individual
deployment resource, `deployment_id` identifies its deployment, and
`cloudzone_id` identifies the verified zone. Names are not used as destructive
target identifiers.

CSV is UTF-8 with a BOM for Excel, with proper CSV quoting. Rows are sorted by
VM/deployment name. Distinct VM IDs with identical names remain separate rows.
Output replaces the destination atomically only after collection completes.
An empty result still produces the header.

**Exit codes**

- `0`: all in-scope VM memberships were determined and the CSV was written.
- `1`: API, authentication, consistency, TLS or file error; no new CSV is
  published. An existing output file is left unchanged.
- `2`: incomplete inventory or command-line usage error. For incomplete
  inventory, a CSV of **verified matches only** is written and each unverifiable
  machine is warned about on stderr.

A VM without enough zone evidence is excluded with a warning and makes the run
incomplete. A deployment-resource HTTP 404 also makes the run incomplete;
it is **not** evidence of a VM being missing at the provider. Missing VM resources
are retained when their fresh deployment records contain a VM name, verified
zone/compute evidence and top-level `syncStatus: MISSING`, even if they have no
IaaS record. A name-fallback HTTP 404 is warned about and makes the run incomplete.
`externalZoneId`
is a provider availability-zone identifier, not the VM Apps cloud-zone ID.
Datacenter or region alone is never substituted for zone membership. The
recorded compute reference is used only with the zone's actual compute members
and the account/region/vCenter checks above. Overlapping cloud zones may share
those members; this fallback does not establish a unique historical zone choice.

This reports Automation's **last recorded synchronization status**, not a live
vCenter query. Re-reading bypasses stale collection/filter results, but cannot repair
staleness in the underlying VM Apps record. The API does not provide an atomic
snapshot across these reads; inventory changes can require a rerun.

## API compatibility and validation

Authentication uses `POST /oauth/tenant/{org}/token` with
`grant_type=refresh_token`, or Basic authentication to
`POST /cloudapi/1.0.0/sessions` and the
`X-VMWARE-VCLOUD-ACCESS-TOKEN` response header. The older Aria CSP login flow is used only when `--legacy` is explicitly set,
as described above.

Inventory uses `/iaas/api/zones`, `/deployment/api/deployments`, and each
deployment's resources collection and individual resource endpoints.
The placement fallback also reads `/iaas/api/regions/{id}` and
`/iaas/api/zones/{id}/computes`. Only a missing VM name requires an individual
`/iaas/api/machines/{id}` GET.
IaaS collections use `$top`/`$skip` and stop at `totalElements` when provided
(some zone-computes endpoints ignore offsets). Deployment resources use
`page`/`size`.

References:

- [IaaS machine API](https://developer.broadcom.com/xapis/vrealize-automation-infrastructure-as-a-service-iaas-api/latest/iaas/api/machines/id/get/)
- [IaaS zone API](https://developer.broadcom.com/xapis/vrealize-automation-infrastructure-as-a-service-iaas-api/latest/iaas/api/zones/id/get/)
- [VMware IaaS SDK machine schema](https://github.com/vmware/vra-sdk-go/blob/master/pkg/models/machine.go)
- [Organization session API](https://developer.broadcom.com/xapis/vmware-cloud-director-openapi/latest/cloudapi/1.0.0/sessions/post/)

Regression tests use mocked API responses, including the placement shape observed
on a live VCF Automation 9.1.1 lab appliance. Deployment-first live validation on
2026-10-16 found both managed VMs using 9 inventory GET requests in approximately
0.48 seconds (authentication excluded). No IaaS machine requests were needed.
This measurement is lab-specific, not a performance guarantee. The resulting
CSV was written and read back successfully. Missing-state behavior is unit-tested
but was not confirmed with a live missing VM. Unsupported record shapes are
surfaced as incomplete/error rather than guessed.

Run the tests:

```powershell
python -m unittest -v test_vm_apps_inventory
```

## PowerShell versions

[vm_apps_inventory.ps1](vm_apps_inventory.ps1) and
[vm_apps_delete.ps1](vm_apps_delete.ps1) implement the same workflows without
Python or PowerCLI. Keep [VmApps.Common.psm1](VmApps.Common.psm1) in the same
directory as both scripts. Windows PowerShell **5.1** is the tested runtime.
Only built-in PowerShell/.NET components are needed. Requests use
`Invoke-WebRequest`; there is no embedded C# or custom transport class.

Use native PowerShell parameters (one leading hyphen, not Python's `--`):

```powershell
$env:VCFA_API_TOKEN = '<organization-api-token>'

# Export only Missing VMs, or add -All for every synchronization status.
.\vm_apps_inventory.ps1 -Server vcfa.example.com -Org MyOrganization -CloudZone "Production" -Output .\production-vms.csv
.\vm_apps_inventory.ps1 -Server vcfa.example.com -Org MyOrganization -CloudZone "Production" -Output .\all-vms.csv -All

# Validate and report what would be deleted, without submitting deletes.
.\vm_apps_delete.ps1 -Server vcfa.example.com -Org MyOrganization -InputCsv .\production-vms.csv

# Destructive: delete eligible deployments and wait for completion.
.\vm_apps_delete.ps1 -Server vcfa.example.com -Org MyOrganization -InputCsv .\production-vms.csv -Execute -Parallel 5 -PollInterval 5 -RequestTimeout 300
```

`-Host` is an alias for `-Server`, and `-Input` is an alias for `-InputCsv`.
The alternative names avoid PowerShell's built-in `$Host` and `$Input`
variables. Parameter names are case-insensitive. Other parameter equivalents:

| Python | PowerShell | Default |
|---|---|---|
| `--api-token` | `-ApiToken` | `VCFA_API_TOKEN` |
| `--username` | `-Username` | none |
| `--password` | `-Password` | `VCFA_PASSWORD`, otherwise secure prompt |
| `--org` | `-Org` | none |
| `--legacy` | `-Legacy` | disabled (VCF authentication) |
| `--domain` | `-Domain` | none; legacy username/password only |
| `--insecure` | `-Insecure` | disabled; certificates validated |
| `--api-version` | `-ApiVersion` | `2021-07-15` |
| `--cloudapi-version` | `-CloudApiVersion` | `40.0` |
| `--page-size` | `-PageSize` | `100` |
| `--timeout` | `-Timeout` | `60` seconds |
| `--log-file` | `-LogFile` | `deployment-deletions.log` |

For username/password authentication, remove `VCFA_API_TOKEN` and supply
`-Username`; omit `-Password` to prompt securely. Do not combine token and
username/password authentication. Redirects are disabled, and credentials/server
response bodies are not included in HTTP-error messages. Native web cmdlet
timeouts use whole seconds, so fractional `-Timeout` values round up.

Both PowerShell scripts refresh bearer tokens before requests once the token
reaches 15 minutes of age. Inventory logs unreadable deployment resource lists
and individual VM details, excludes unverified data, continues where possible,
and returns exit code 2 when the resulting CSV is incomplete.
PowerShell inventory writes each verified record directly to the destination,
so rows from before a later fatal error remain available in the partial CSV.
Its output follows API discovery order rather than sorting all VMs in memory.

Pass `-Debug` to either PowerShell script to log every API call's method, path,
HTTP status, and elapsed time to stderr (and the deletion log file), for example
`DEBUG: GET /deployment/api/deployments?page=0&size=100 -> 200 in 412 ms`.
Request bodies, tokens, and credential query values are never logged, and
`-Debug` does not trigger PowerShell's interactive debug prompts.

### Aria Automation 8.18 with PowerShell

Both PowerShell scripts accept `-Legacy` for on-premises Aria Automation 8.18.
VCF Automation authentication remains the default when the switch is absent.

Using an Aria refresh token (not a VCF organization token or bearer access token):

```powershell
$env:VCFA_API_TOKEN = '<aria-refresh-token>'
.\vm_apps_inventory.ps1 -Legacy -Server aria.example.com -CloudZone "vc-01 / vcf-lab-dc-01" -Output .\legacy-vms.csv
.\vm_apps_delete.ps1 -Legacy -Server aria.example.com -InputCsv .\legacy-vms.csv
```

Or use username/password with an optional identity domain. The password is
prompted securely if neither `-Password` nor `VCFA_PASSWORD` is supplied:

```powershell
Remove-Item Env:VCFA_API_TOKEN -ErrorAction SilentlyContinue
.\vm_apps_inventory.ps1 -Legacy -Server aria.example.com -Username administrator -Domain example.com -CloudZone "vc-01 / vcf-lab-dc-01" -Output .\legacy-vms.csv
.\vm_apps_delete.ps1 -Legacy -Server aria.example.com -Username administrator -Domain example.com -InputCsv .\legacy-vms.csv
```

With `-Legacy`, refresh tokens are exchanged using JSON `refreshToken` at
`POST /iaas/api/login`, taking the response's `token` as the bearer token.
Username/password first obtains `refresh_token` from
`POST /csp/gateway/am/api/login?access_token=`. The username is sent unchanged;
`-Domain` is optional. `-Org` is rejected in legacy mode, and `-Domain` is
accepted only with `-Legacy -Username`. `-CloudApiVersion` is unused in legacy
mode. Authentication failures do not trigger retries or fallback to VCF login.

The Aria placement fallback is also ported: when `properties.datacenter` is
absent, `properties.region` must match the fetched zone region's `name` exactly.
Cloud-account, compute member, provider-region and vCenter UUID checks still
apply. A conflicting explicit datacenter is not overridden by a region name.
This is shared by inventory and whole-deployment deletion validation.

CSV format, Missing-only filtering and deletion safety checks are unchanged.
Deletion defaults to dry run; only `-Execute` submits actions. Legacy behavior
is covered by mocked tests but has not been tested against a live 8.18 server.

### PowerShell TLS behavior

Certificate validation is **enabled by default**. On either PowerShell script,
`-Insecure` disables certificate trust, expiry and hostname checks.
HTTPS encryption remains, but the server's identity is not
verified. An interceptor could obtain API tokens/passwords or alter API responses,
including the records used by deletion safety checks. Use only in controlled,
trusted environments. A warning is printed before authentication (and recorded
in the deletion log) only when `-Insecure` is specified. `-CaBundle` is not
supported; install your organization's CA in the Windows trust store instead.
Python's existing TLS options are unchanged.

On Windows PowerShell 5.1 with `-Insecure`, a process-wide certificate callback
is replaced once before authentication and restored when the command exits
through `finally`, including on errors or caught interruptions. Other HTTPS work
in the same process is affected throughout the command; run these scripts in a
dedicated process (for example, `powershell.exe -File .\vm_apps_inventory.ps1 ...`).
Without `-Insecure`, the existing process callback is not changed. A small .NET
expression builds the constant-true callback so it can run on network threads
without a PowerShell runspace. On PowerShell 7, the native per-request
`-SkipCertificateCheck` switch is used only with `-Insecure` instead (5.1 is the
tested runtime). Forced process termination cannot guarantee `finally` cleanup.

Both implementations use the same UTF-8 BOM CSV columns, so either inventory
script can feed either deletion script. PowerShell inventory additionally appends
an informational `powerStatus` column, read directly from the fresh deployment
resource's `properties.powerState` (for example, `ON` or `OFF`). Missing, empty or
non-string values produce `unknown` and a warning; no alternative fields are
guessed and no extra machine requests are made for power state. The frozen Python
inventory format is unchanged.

PowerShell CSV columns:

```csv
vm_name,deployment_name,status,vm_id,resource_id,deployment_id,cloudzone,cloudzone_id,powerStatus
```

PowerShell deletion reads and retains `powerStatus`, but it is informational only:
it does not authorize or prevent deletion. Older enriched CSVs without it are
still accepted; absent or empty values are read as `unknown`. Both deletion
implementations use fresh top-level `syncStatus`, not CSV power state, to check
for Missing VMs. The PowerShell deletion script defaults to dry run and performs
the same whole-deployment checks, five-slot single-threaded scheduler,
monotonic timeouts, no-retry submission policy, deployment-disappearance
confirmation and persistent statistics described below. All existing race,
remote-timeout and visibility limitations also apply.

Operational exit codes are the same: `0` success, `1` failure, `2` incomplete
inventory or skipped-only deletion, and `130` for an interruption caught by the
script. Native PowerShell parameter-binding errors use PowerShell's own exit
behavior (normally `1` under `powershell.exe -File`, not argparse's `2`).
PowerShell host termination can prevent cleanup/summary logging; outstanding
server operations are not cancelled.

Use `Get-Help .\vm_apps_inventory.ps1 -Full` or
`Get-Help .\vm_apps_delete.ps1 -Full` for parameter discovery. If local execution
policy blocks unsigned scripts, follow your organization's signing/execution
policy; the scripts do not change it.

Run the PowerShell regression tests with the Windows-bundled Pester 3.4:

```powershell
$result = Invoke-Pester -Script .\VmApps.Tests.ps1 -PassThru
if ($result.FailedCount) { throw "PowerShell tests failed" }
```

No live delete is used by the tests. VCF API behavior is tested with mocked
records/requests, and HTTP/TLS transport is exercised against a loopback-only
fixture. Only the test fixture uses compiled C#; it is not needed to run either
script. The PowerShell scripts have not been validated against a live VCF server.

## Safe deletion of missing deployments

[vm_apps_delete.py](vm_apps_delete.py) reads the enriched CSV and uses the same
authentication/TLS options as the inventory CLI. Keep both scripts together;
the deletion tool imports the shared client and membership/state checks.
No third-party dependencies or threads are used.

First generate a new CSV, then run the default **dry run**:

```powershell
python .\vm_apps_inventory.py --host vcfa.example.com --org MyOrganization --cloudzone "Production" --output .\production-vms.csv
python .\vm_apps_delete.py --host vcfa.example.com --org MyOrganization --input .\production-vms.csv
```

With `VCFA_API_TOKEN` set, these use organization-token authentication. Otherwise
provide `--username` and optionally `--password`, exactly as for inventory.
The deletion CLI takes its expected cloud zone from each CSV row; it has no
`--cloudzone` override that could change the CSV's intended targets.

Without `--execute`, the tool performs all safety checks and prints a
"would be deleted" message for each eligible deployment, without submitting
deletes or polling requests.

Review the dry-run log. To actually submit delete actions:

```powershell
python .\vm_apps_delete.py --host vcfa.example.com --org MyOrganization --input .\production-vms.csv --execute --parallel 5 --poll-interval 5 --request-timeout 300
```

**`--execute` is destructive:** the `Deployment.Delete` action deletes the
entire deployment, including its networks, disks and any other resources.
Only VM resources are required to be Missing; non-VM resources are not required
to be Missing. No force-delete or unregister shortcut is used.

### Safety checks

The entire CSV is parsed and grouped by deployment ID before any delete is
submitted. Missing IDs, legacy format, malformed records, duplicate VM/resource
IDs, and inconsistent deployment names/zone identities are input errors.
An empty enriched CSV is a successful no-op.

Immediately before each request (not just when building the queue), the tool:

1. Fetches the deployment and cloud zone by their CSV IDs and checks their names
   still match. A missing/inaccessible deployment or zone is not assumed safe.
2. Enumerates **all** current resources in the deployment, with pagination.
   Every current VM must be represented in the CSV and every CSV VM must still
   be present. Empty deployments, extra VMs, or missing VMs are skipped. Thus a
   zone-filtered CSV containing only part of a multi-zone deployment cannot
   authorize deleting that whole deployment.
3. GETs each VM resource again. Its VM ID/type must match; its top-level
   `syncStatus` must explicitly be `MISSING` (case-insensitive), using the same
   helper as inventory. The CSV status is informational and is **not** accepted
   as evidence of current status. Absent, empty or invalid `syncStatus` values
   and all non-Missing values block deletion. Power state and guessed missing
   indicators cannot authorize deletion.
4. Checks the fresh record against the CSV zone ID. A cloud-zone name alone is
   insufficient for deletion (duplicate names could refer to another zone).
   Recorded compute
   references, when available, are independently checked against that zone's
   compute members, account, region and vCenter. Conflicting evidence blocks
   deletion. Each deployment validation starts with fresh zone/compute reads.
5. Enumerates the resource set again to detect additions/removals/type changes
   while validating. Any change blocks submission.

Failed safety checks are logged as **skipped**. API/permission/schema errors
are logged as **failures**, never silently treated as Missing or successful.
Other safe deployments can still proceed.

These are fresh reads of **Automation's records**, not live vCenter inspection.
There is no atomic validate-and-delete API transaction: changes after validation
or staleness inside the server's own records cannot be ruled out. Run this only
under suitable operational controls, without concurrent changes to the targets.

### Chalkboard and completion

- The queue is completely populated from the CSV before submissions begin.
- `--parallel` defaults to **5** outstanding request slots.
- Each slot records deployment ID, request ID and a monotonic start timestamp.
- Free slots are filled from the queue after fresh safety checks.
- Each scan polls `/deployment/api/requests/{requestId}`. Successful requests
  are counted only after the deployment GET also confirms HTTP 404.
  Failed/aborted/rejected requests free their slot and increment failures.
- Polling errors and unknown statuses keep their slot until completion/timeout;
  a request-status 404 is **not** counted as deletion success.
- `--request-timeout` defaults to **300 seconds**. Expired slots are removed,
  logged and counted as failures (also included in `timed_out`).
  **Timeout does not cancel the server operation**: it may still finish, and
  the number of actual server operations can exceed the slot limit after
  timeouts. Reconcile timed-out requests before running the tool again.
- `--poll-interval` defaults to **5 seconds**. This is a synchronous polling
  loop; HTTP request duration and validation time can delay a scan. `--timeout`
  remains the independent per-HTTP-request timeout (default 60 seconds).
- The program drains the queue and waits for all tracked requests to reach a
  terminal result or timeout. It never automatically retries a delete POST,
  including when the network fails after the server may have accepted it.

Logs append to `deployment-deletions.log`, or `--log-file <path>`, as well as
stderr. They include submission/request IDs, individual outcomes and a final
summary of `successful`, `failures`, `skipped`, `timed_out`, `eligible` and
`submitted`. `timed_out` is a subset of `failures`; dry-run eligibility never
counts as a successful deletion. Preserve the log for uncertain submissions.

Deletion exit codes: `0` = all requests confirmed deleted (or dry run/no-op
without rejected targets); `1` = failures/timeouts/input errors; `2` = skipped
targets with no failures, or CLI usage errors; `130` = interrupted. Interruption
does not cancel submitted requests.

The deletion action/request shapes are based on the
[VMware deployment API specification](https://github.com/vmware/vra-sdk-go/blob/master/swagger/vra-catalog-deployment.json).
Destructive requests and polling are tested with mocked responses only; **no
live deployments were deleted during development**.

Run both regression suites:

```powershell
python -m unittest -v test_vm_apps_inventory test_vm_apps_delete
```
