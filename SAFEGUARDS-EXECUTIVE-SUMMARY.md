# Stale VM Record Cleanup: Executive Summary

## Purpose and approach

The tool removes stale VM management records from VCF Automation / Aria
Automation, including records left behind when VMs were deleted or moved outside
Automation. Its default approach is **Unregister, not infrastructure deletion**.
Independent safeguards limit scope, require human review, and block actions when
the available information is incomplete or inconsistent.

## Core safeguards

- **Review before execution.** A read-only inventory produces a CSV for review.
  Dry run is the default; changes require an explicit `-Execute` flag. A partial
  inventory is clearly reported rather than presented as complete.
- **Unregister only by default.** Every VM in an eligible deployment must offer
  a valid Unregister action. This removes the VM from Automation management
  without powering it off or deleting it in vCenter. The deployment and non-VM
  resources remain. If Unregister is unavailable, the deployment is skipped.
- **Exact identity and scope.** Actions target deployment and resource IDs, not
  VM names. Machine identity and cloud-zone membership are checked against live
  data. Placement-based verification includes the cloud account, datacenter,
  compute membership and vCenter UUID. A VM discovered through another cloud
  account is a separate record, not the target of the original deployment's
  Unregister action.
- **Fresh validation; fail closed.** Immediately before acting, the tool
  re-reads each deployment and VM. The entire current VM set must exactly match
  the reviewed CSV, and each VM must explicitly be `MISSING`. Changed identities,
  conflicting placement, unreadable data or resource-set changes block action.
- **Controlled, auditable execution.** Actions are logged with their identifiers
  and outcomes. VMs are unregistered sequentially within each deployment;
  concurrency across deployments is bounded. Uncertain submissions are never
  automatically retried. Success requires confirmation that the targeted record
  has disappeared, not merely a successful request status.

## Exceptions require deliberate authorization

**Deployment deletion:** `-AllowDelete` permits a deployment-delete fallback
when Unregister is unavailable. Normally, every resource must be explicitly
`MISSING`, including disks, networks and other non-VM resources. This is broader
than Unregister and should remain disabled unless specifically reviewed.

**Records that never become Missing:** `-DeleteNonMissingVMs` relaxes the Missing
requirement only after the operator types
`Yes I am absolutely sure I want this`. Non-Missing resources must belong to the
expected vSphere cloud account, pass the remaining identity and scope checks,
and have an account reporting explicitly unhealthy after a fresh health check.
This does **not** independently authorize deployment deletion.

## Residual risks and recommended approval conditions

The tool relies on Automation's records; it does not independently query vCenter.
Validation and submission are not atomic. An unhealthy cloud account can mean
invalid credentials or a temporary outage, not a retired vCenter. The health-check
endpoint still requires live validation against Aria Automation 8.18. Timeouts do
not cancel server-side operations.

**Recommended rollout:** back up Automation, pilot one or two deployments,
confirm that live and discovered VMs are unaffected, then proceed in reviewed
batches using least privilege and a change freeze. Retain logs, keep both
exception flags off by default, and independently confirm permanent vCenter
retirement before using the non-Missing exception.

Full technical detail: [Safeguards](SAFEGUARDS.md).
