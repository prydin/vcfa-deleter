# Stale VM Record Cleanup: Safeguards

This document describes how the cleanup tool (`vm_apps_inventory.ps1` and
`vm_apps_delete.ps1`) makes sure that it only removes **stale VM Apps records**
from VCF Automation / Aria Automation. It must never touch running workloads,
and it must never touch VMs that are still visible through other cloud accounts
(for example, VMs that moved to another vCenter and appear there as discovered
machines).

## Summary

| Concern | How it is addressed |
|---|---|
| Removing a VM that still exists | Only VMs whose current Automation `syncStatus` is explicitly `MISSING` are eligible. This is re-read from the API immediately before any action. The sole exception is the explicitly confirmed `-DeleteNonMissingVMs` mode (section 2a), which additionally requires the VM's vSphere cloud account to report lost connectivity. |
| Affecting a VM that moved to another cloud account | Actions target one specific deployment resource ID. The VM must be verified as belonging to the original cloud zone, cloud account, datacenter and vCenter. A VM discovered elsewhere has a different identity and is never a target. |
| Deprovisioning infrastructure | The default and only automatic method is the **Unregister** day-2 action, which removes the record from management. `Deployment.Delete` is never used unless an operator explicitly passes `-AllowDelete`. |
| Removing more than intended | A deployment is acted on only if its *entire* current VM set exactly matches the reviewed CSV. Extra, missing or changed resources cause a skip. |
| Mistakes and surprises | Dry run is the default. Every check fails closed: unknown, ambiguous or unreadable data blocks the action instead of permitting it. |
| Traceability | Every submitted request is logged with deployment, resource and request IDs, plus a final summary and a meaningful exit code. |

## 1. Two-phase, human-reviewed workflow

The process is deliberately split so that a person reviews the exact target
list before anything changes.

1. **Inventory (read-only).** `vm_apps_inventory.ps1` uses only read (`GET`)
   calls, plus authentication. It writes a CSV of VMs in one named cloud zone.
   By default the CSV contains only VMs whose `syncStatus` is `MISSING`.
2. **Review.** The operator, or the customer, reviews the CSV. Rows can be
   removed to narrow the scope. Rows cannot be *added* safely by hand, because
   every row carries the immutable IDs that later checks depend on.
3. **Dry run.** `vm_apps_delete.ps1` without `-Execute` runs every safety check
   against live data and reports exactly what *would* happen. It submits
   nothing.
4. **Execute.** Only with `-Execute` are actions submitted, and by default only
   Unregister actions.

## 2. Unregister first; delete only on explicit opt-in

For each eligible deployment, the tool reads the available day-2 actions of
each VM resource
(`GET /deployment/api/deployments/{id}/resources/{resourceId}/actions`).

- **Unregister (default).** If *every* VM in the deployment offers exactly one
  valid `Unregister` action, the tool submits that action, one VM at a time.
  Unregister removes the machine from Automation management; it does not
  power off, delete or otherwise act on the VM in vCenter. The deployment
  object, and any non-VM resources it contains, are left in place.
- **Otherwise the deployment is skipped**, with the reason "Unregister is not
  available; deployment delete requires -AllowDelete". This also happens if
  the action is missing, ambiguous (more than one match) or reported as not
  currently valid.
- **`Deployment.Delete` (opt-in only).** If the operator passes `-AllowDelete`,
  the tool may delete a deployment whose VMs cannot be unregistered. Because a
  deployment delete acts on *all* of its resources, the tool then requires
  **every** resource in the deployment to be explicitly `MISSING`, including
  disks, networks, load balancers and other non-VM resources. Each resource is
  freshly read. A resource that is not Missing, has no status, or whose
  identity or type has changed causes the deployment to be skipped.

The log records which mode each run used (`removal=unregister-only` or
`removal=unregister, delete allowed`). As a second, independent guard, the
execution engine refuses to submit a deployment delete when `-AllowDelete` was
not given, even if validation somehow produced one.

## 2a. Lost vCenters: `-DeleteNonMissingVMs` (high risk)

When a vCenter is decommissioned, Automation can lose its VMs permanently
without ever marking them `MISSING`. Such records can only be cleaned up by
relaxing the Missing requirement. This is never the default, and it is guarded
as follows:

- **Explicit opt-in and typed confirmation.** The operator must pass
  `-DeleteNonMissingVMs` *and* type exactly
  `Yes I am absolutely sure I want this` at a prompt. Any other answer, or a
  non-interactive session, aborts the run before authentication. The prompt is
  shown for dry runs too.
- **Only for the affected cloud account.** Each non-Missing VM (and, with
  `-AllowDelete`, each non-Missing non-VM resource) must record a cloud account
  identical to the cloud account of the CSV cloud zone's region. All other
  checks, including cloud-zone and compute membership, still apply.
- **Proven loss of connectivity.** The first time an account is needed in a
  run, the tool triggers a fresh Automation health check of that cloud account
  and waits for it to finish. For every deployment, it then re-reads the cloud
  account, which must be of type vSphere and report `healthy` as an explicit
  `false`. A healthy account, an unknown health state, a health check that does
  not finish, or any other account type causes the deployment to be skipped.
- **Visible in the log.** Each accepted non-Missing resource is logged as a
  `WARNING` naming the cloud account, and the run's `Loaded` line shows
  `NON-MISSING VMs allowed`.

This check is performed **only** when `-DeleteNonMissingVMs` is given, and only
for resources that are not Missing. Without the flag, a VM that is not Missing
is always skipped, regardless of its cloud account's health.

## 3. Why discovered VMs in other cloud accounts are not affected

A VM that has moved to another environment and is visible there as a
discovered machine is protected in several independent ways:

1. **Actions are scoped to a deployment resource, not a VM name.** Unregister
   is submitted against one specific `deployments/{deploymentId}/resources/{resourceId}`.
   A discovered VM in another cloud account is a different machine record with
   a different ID. Unless someone onboarded it, it is not a resource of the
   original deployment at all.
2. **Names are never used as identity.** VM names, deployment names and
   cloud-zone names are only consistency checks. Every decision uses immutable
   IDs: deployment ID, resource ID, machine ID and cloud-zone ID.
3. **Placement must match the original cloud zone.** For removal, the VM must
   either carry an explicit link to the CSV's cloud-zone ID, or its recorded
   placement must match that zone, as follows:
   - its compute (`computeHostRef`, the cluster or host MoRef) is a member of
     the zone's computes;
   - its endpoint is the zone's **cloud account**;
   - its datacenter is the zone's **region**;
   - its **vCenter instance UUID** equals that compute's vCenter UUID.

   Any conflicting evidence blocks removal, and so does placement that cannot
   be verified. Matching by name alone is not accepted for removal, because
   two zones can share a name.
4. **`MISSING` is required, fresh.** A VM that Automation still sees in its
   original cloud account is not `MISSING`, so it is not eligible. The CSV's
   status column is informational only; the live API value is what counts.
5. **Unregister does not deprovision.** Even in the worst case, the default
   action only removes a management record. It does not send a destroy
   operation to vCenter.

## 4. Inventory-phase safeguards

- **Exact, unique cloud zone.** The zone is found by exact, case-sensitive
  name. Zero or multiple matches abort the run. The zone is then re-read by ID
  to confirm that it did not change during lookup.
- **Membership must be proven, not assumed.** A VM is included only if its zone
  membership is positively verified (see section 3). VMs whose membership
  cannot be verified are **excluded**, logged as warnings and counted. One
  example is a VM placed in a resource pool that was later removed from the
  zone. Such VMs fall *out* of scope, never into it.
- **Consistency checks.** The run aborts with a request to rerun if:
  - a resource changes identity or type between reads;
  - a deployment resource is re-associated with another machine;
  - the same machine appears in more than one deployment.
- **Partial failures are visible.** Unreadable deployments or VMs, including
  HTTP 403/404 or malformed responses, are logged and skipped instead of
  aborting the run. The run then ends with exit code `2` (incomplete), so
  nobody mistakes a partial inventory for a complete one. Each log line carries
  the HTTP status, its reason, and the server's error message, or a short
  excerpt of an unparseable response. Token, password, and client-secret
  values are redacted from these, and authentication responses are never
  excerpted.
- **Power state is informational.** The `powerStatus` column is never used to
  decide eligibility.
- **Unregister availability is informational.** The `unregisterAvailable`
  column reports `true`, `false` or `unknown` from a read-only action lookup.
  Failed lookups are warned about without excluding the VM. Removal always
  checks live actions again; this CSV value cannot authorize or block removal.

## 5. Removal-phase safeguards

### Input validation (before authenticating)

The entire CSV is parsed and validated before any connection is made. The run
is rejected if any of the following is found:

- missing or duplicate columns, or empty required fields;
- duplicate VM or resource IDs;
- a deployment with inconsistent names;
- a deployment that spans more than one cloud zone.

### Just-in-time revalidation (for each deployment, immediately before acting)

Checks run when an execution slot becomes free, not when the queue is built,
so the data is as current as possible:

1. The deployment and the cloud zone are re-read by ID, and their names must
   still match the CSV.
2. **All** current resources of the deployment are enumerated, with
   pagination. The current VM set must equal the CSV's VM set exactly. A
   deployment with extra VMs, missing VMs or no VMs is skipped. A filtered
   CSV that covers only part of a deployment therefore cannot authorize
   action on the whole deployment.
3. Each VM is re-read. Its resource ID, type and machine ID must be unchanged,
   and its `syncStatus` must be explicitly `MISSING`. An absent or
   unrecognized status blocks the action, unless the `-DeleteNonMissingVMs`
   conditions in section 2a are all met.
4. Cloud-zone and placement membership is re-verified with fresh data, without
   name matching.
5. The removal method is selected (section 2).
6. The deployment's resource set is enumerated **again**. Any addition,
   removal or type change during validation blocks the action.

Failed checks are logged as **SKIPPED**. Errors such as API, permission or
schema problems are logged as **FAILED**. Neither is ever treated as success,
and the run continues with other deployments.

### Execution controls

- **No automatic retries.** A submission whose outcome is uncertain, such as a
  connection lost mid-request, is reported as a failure and is never
  resubmitted. The log instructs the operator to check the server first.
- **Success means the record is gone.** A request reaching `SUCCESSFUL` is not
  enough on its own:
  - for Unregister, the VM resource must actually disappear from the
    deployment (HTTP 404);
  - for delete, the deployment itself must disappear.
- **Request identity is checked.** The polled request must report the same
  request ID, deployment ID and action as the one submitted. Duplicate request
  IDs from the server are rejected.
- **Sequential per deployment.** Within a deployment, VMs are unregistered one
  at a time. If one fails, the remaining VMs in that deployment are not
  attempted.
- **Bounded concurrency.** At most five deployments are in flight by default
  (`-Parallel`), on a single-threaded scheduler.
- **Timeouts are failures.** A request that does not finish within
  `-RequestTimeout` is counted as timed out and failed. The log states clearly
  that the server-side operation was *not* cancelled and may still complete.

## 6. Transport and authentication

- HTTPS only. The host must be a bare hostname; paths, credentials embedded in
  the URL and other schemes are rejected.
- TLS certificates are validated by default. `-Insecure` must be given
  explicitly, and it produces a prominent warning.
- HTTP redirects are not followed, and all API calls are pinned to the
  configured host.
- Bearer tokens are refreshed proactively when they are older than 15 minutes,
  so long runs do not degrade into authorization errors partway through.

## 7. Auditability

- Every action is written to a log file (`deployment-deletions.log` by
  default), including:
  - `SUBMITTED` lines with the deployment ID, resource ID, action ID and
    request ID;
  - the outcome of each request: `UNREGISTERED`, `COMPLETED`, `DELETED`,
    `FAILED`, `TIMED OUT` or `SKIPPED`, with a reason.
- A final `SUMMARY` line reports successful, failed, skipped, timed-out,
  eligible, submitted, processed, unregistered and deleted counts.
- Exit codes:

  | Code | Meaning |
  |---|---|
  | `0` | Success |
  | `1` | Failures |
  | `2` | Incomplete inventory, or deployments were skipped |
  | `130` | Interrupted |

- `-Debug` prints the timing of every API call for troubleshooting.

## 8. Known limitations

These are stated plainly so that operational controls can cover them.

- **Automation's view, not vCenter's.** All checks read Automation's own
  records, including `syncStatus`. The tool does not connect to vCenter. If
  Automation's data collection is stale, its view can be stale too.
- **No atomic transaction.** There is no API to validate and act in a single
  step. Changes made by others between the final check and the submission
  cannot be ruled out entirely, although the window is kept as short as
  possible.
- **Unregister action discovery.** The Unregister action is identified by its
  name, or by an action ID ending in `.Unregister`, as exposed by the
  resource's actions endpoint. Confirm on one VM in your environment that the
  action is offered and behaves as expected.
- **Timeouts do not cancel.** A timed-out request may still complete on the
  server. Check the request in the Automation UI before rerunning.
- **The deployment remains after Unregister.** Removing the deployment
  objects that are left behind, empty or holding only non-VM resources, is a
  separate decision.
- **`healthy=false` is not proof that a vCenter is gone.** Automation reports
  an account as unhealthy both when it cannot reach vCenter and when its
  credentials are invalid. A temporary outage looks the same as a
  decommissioned vCenter. Before using `-DeleteNonMissingVMs`, confirm
  independently that the vCenter is permanently retired. The health-check
  endpoint has not yet been validated against a live 8.18 system; if it is
  unavailable, the affected deployments are skipped. A `Deployment.Delete`
  against an unreachable vCenter may fail, so Unregister is preferred.

## 9. Recommended operational controls

1. **Back up first.** Take an Automation backup or snapshot per your standard
   procedure before the first execute run.
2. **Pilot.** Run the inventory and dry run, then execute on one or two
   deployments. Confirm in vCenter and in the other cloud accounts that the
   corresponding VMs, including discovered copies, are unaffected.
3. **Review the CSV and the dry-run log** before every execute run. Remove any
   row you are unsure about; removing rows can only reduce scope.
4. **Work in batches**, for example per project or by splitting the CSV, and
   keep the log files as change records.
5. **Least privilege.** Run with a service account that can see only the
   relevant projects and perform only the required day-2 actions.
6. **Freeze changes** to the affected cloud zone and deployments during the
   run.
7. **Keep `-AllowDelete` off** unless a specific, reviewed set of deployments
   requires it.
8. **Use `-DeleteNonMissingVMs` only for a retired vCenter**, in a separate run
   with a CSV restricted to that cloud zone, after confirming that the vCenter
   is permanently decommissioned and not merely unreachable.
