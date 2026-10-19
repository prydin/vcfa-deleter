# VM Apps cloud-zone inventory

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
   match alone never proves membership. References to computes outside the
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
`X-VMWARE-VCLOUD-ACCESS-TOKEN` response header. This intentionally does not use
the older Aria CSP login flow.

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
