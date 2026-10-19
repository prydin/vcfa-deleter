#!/usr/bin/env python3
"""Safely delete missing VM Apps deployments from an enriched inventory CSV."""

from __future__ import annotations

import argparse
from collections import deque
import csv
from dataclasses import dataclass
import json
import logging
from pathlib import Path
import sys
import time

from vm_apps_inventory import (
    ApiError, Client, Inventory, InventoryError, InventoryRow,
    add_connection_arguments, authenticated_client, identifier, is_vm,
    positive_float, positive_int, properties, required_text,
    sync_status, text, zone_membership,
)


LOG = logging.getLogger("vm_apps_delete")
FAILED_STATES = {"FAILED", "ABORTED", "APPROVAL_REJECTED", "CANCELLED", "CANCELED"}
PENDING_STATES = {
    "CREATED", "PENDING", "INITIALIZATION", "CHECKING_APPROVAL", "APPROVAL_PENDING",
    "USER_INTERACTION_PENDING", "INPROGRESS", "COMPLETION",
}


class CheckFailed(InventoryError):
    """A deployment is not safe to delete."""


@dataclass(frozen=True)
class Target:
    deployment_id: str
    rows: tuple[InventoryRow, ...]


@dataclass(frozen=True)
class Outstanding:
    """One chalkboard slot; started is monotonic time, not a wall-clock timestamp."""

    target: Target
    request_id: str
    started: float


@dataclass
class Statistics:
    """Deployment-level totals; timed_out is a subset of failures."""

    successful: int = 0
    failures: int = 0
    skipped: int = 0
    timed_out: int = 0
    eligible: int = 0
    submitted: int = 0


def load_targets(path: Path) -> list[Target]:
    """Validate the entire input before returning one queued target per deployment."""
    grouped: dict[str, list[InventoryRow]] = {}
    identities: set[str] = set()
    resource_ids: set[str] = set()
    with path.open(encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle, strict=True)
        columns = reader.fieldnames
        if (
            columns is None or len(columns) != len(set(columns))
            or not set(InventoryRow._fields).issubset(columns)
        ):
            raise InventoryError("CSV requires enriched inventory columns; regenerate the inventory")
        for line, record in enumerate(reader, 2):
            if None in record or any(value is None for value in record.values()):
                raise InventoryError(f"CSV line {line}: column count mismatch")
            values = [record[field].strip() for field in InventoryRow._fields]
            if not all(values):
                raise InventoryError(f"CSV line {line}: all inventory fields must be nonempty")
            row = InventoryRow(*values)
            if row.vm_id in identities or row.resource_id in resource_ids:
                raise InventoryError(f"CSV line {line}: duplicate VM or resource ID")
            identities.add(row.vm_id)
            resource_ids.add(row.resource_id)
            # Deletion acts on a whole deployment, even when the CSV has several VM rows.
            grouped.setdefault(row.deployment_id, []).append(row)
    for dep_id, rows in grouped.items():
        if len({r.deployment_name for r in rows}) != 1:
            raise InventoryError(f"CSV: inconsistent names for deployment {dep_id}")
        if len({(r.cloudzone_id, r.cloudzone) for r in rows}) != 1:
            raise InventoryError(f"CSV: deployment {dep_id} spans multiple cloud zones")
    return [Target(dep_id, tuple(rows)) for dep_id, rows in grouped.items()]


def validate_target(client: Client, target: Target) -> None:
    """Fresh checks, with zone caches scoped to this one validation only."""
    first = target.rows[0]
    dep_path = f"/deployment/api/deployments/{identifier(target.deployment_id)}"
    deployment = client.get(dep_path)
    if text(deployment, "id") != target.deployment_id:
        raise CheckFailed("Deployment ID mismatch")
    if text(deployment, "name") != first.deployment_name:
        raise CheckFailed("Deployment name changed since CSV export")
    zone = client.get(f"/iaas/api/zones/{identifier(first.cloudzone_id)}")
    if text(zone, "id") != first.cloudzone_id or text(zone, "name") != first.cloudzone:
        raise CheckFailed("Cloud-zone identity/name changed since CSV export")
    path = dep_path + "/resources"
    candidates = list(client.records(path))
    for candidate in candidates:
        required_text(candidate, "type", "Deployment resource")
    expected = {row.resource_id: row for row in target.rows}
    vm_candidates = {required_text(r, "id", path): r for r in candidates if is_vm(r)}
    # A zone-filtered export must not authorize deleting VMs omitted from that export.
    if not vm_candidates or set(vm_candidates) != set(expected):
        raise CheckFailed("Current deployment VM set differs from CSV (extra, missing or changed VMs)")
    # Reuse placement lookups within this deployment, never across queued validations.
    inventory = Inventory(client)
    for resource_id, candidate in vm_candidates.items():
        row = expected[resource_id]
        resource = client.get(f"{path}/{identifier(resource_id)}")
        if text(resource, "id") != resource_id or text(resource, "type") != text(candidate, "type"):
            raise CheckFailed(f"VM resource {resource_id}: identity/type changed")
        recorded = properties(resource, "properties")
        if (text(recorded, "resourceId") or resource_id) != row.vm_id:
            raise CheckFailed(f"VM resource {resource_id}: VM identity changed")
        # CSV state is historical; only the freshly fetched resource can authorize deletion.
        if sync_status(resource).casefold() != "missing":
            raise CheckFailed(f"VM {row.vm_id}: current syncStatus is not Missing")
        membership = zone_membership(resource, zone, allow_names=False)
        compute_membership = inventory.compute_membership(resource, zone)
        # Either source can prove membership, but contradictory evidence must block deletion.
        if membership is False or compute_membership is False:
            raise CheckFailed(f"VM {row.vm_id}: no longer connected to the CSV cloud zone")
        if membership is not True and compute_membership is not True:
            raise CheckFailed(f"VM {row.vm_id}: cloud-zone membership cannot be verified")
    # Detect resource-set changes during detail validation, including new non-VM resources.
    latest = list(client.records(path))
    if {(text(r, "id"), text(r, "type")) for r in latest} != {
        (text(r, "id"), text(r, "type")) for r in candidates
    }:
        raise CheckFailed("Deployment resources changed during validation")


def submit_delete(client: Client, target: Target) -> str:
    """Submit once and return the asynchronous request ID, not a deletion result."""
    path = f"/deployment/api/deployments/{identifier(target.deployment_id)}/requests"
    body, _ = client.request(
        "POST", path,
        data=json.dumps({
            "actionId": "Deployment.Delete", "inputs": {},
            "reason": "CSV cleanup: all deployment VMs verified Missing in the recorded cloud zone",
        }).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    record = client.decode(body, path)
    return required_text(record, "id", "Delete request response")


def deletion_complete(client: Client, outstanding: Outstanding) -> str:
    record = client.get(f"/deployment/api/requests/{identifier(outstanding.request_id)}")
    if text(record, "id") != outstanding.request_id:
        raise InventoryError("Request status returned a different request ID")
    dep_id = text(record, "deploymentId")
    if dep_id and dep_id != outstanding.target.deployment_id:
        raise InventoryError("Request status returned a different deployment ID")
    action = text(record, "actionId")
    if action and action != "Deployment.Delete":
        raise InventoryError("Request status returned a different action")
    status = required_text(record, "status", "Delete request status").upper()
    if status in FAILED_STATES:
        LOG.error("Request %s reached terminal failure status %s", outstanding.request_id, status)
        return "failed"
    if status == "SUCCESSFUL":
        # Request success can precede removal of the deployment record.
        path = f"/deployment/api/deployments/{identifier(outstanding.target.deployment_id)}"
        try:
            client.get(path)
        except ApiError as exc:
            if exc.status == 404:
                return "successful"
            raise
        LOG.info("Request %s successful; waiting for deployment disappearance", outstanding.request_id)
    elif status not in PENDING_STATES:
        LOG.warning("Request %s: unrecognized status %s; retaining slot",
                    outstanding.request_id, status)
    return "pending"


def run(
    client: Client, targets: list[Target], *, execute: bool = False,
    parallel: int = 5, poll_interval: float = 5, request_timeout: float = 300,
    stats: Statistics | None = None,
) -> Statistics:
    """Fill free slots, scan outstanding requests, and repeat until both collections empty."""
    if parallel <= 0 or poll_interval <= 0 or request_timeout <= 0:
        raise ValueError("Chalkboard limits must be positive")
    stats = stats if stats is not None else Statistics()
    # The queue is fixed up front; the board contains only requests submitted by this run.
    queue = deque(targets)
    board: list[Outstanding] = []
    request_ids: set[str] = set()
    while queue or board:
        while queue and len(board) < parallel:
            target = queue.popleft()
            # Validate when a slot is available: a VM may recover while its target is queued.
            try:
                validate_target(client, target)
            except CheckFailed as exc:
                stats.skipped += 1
                LOG.warning("SKIPPED deployment %s: %s", target.deployment_id, exc)
                continue
            except (InventoryError, OSError) as exc:
                # An unreadable record is an operational failure, not a failed safety check.
                stats.failures += 1
                LOG.error("FAILED verification for deployment %s: %s", target.deployment_id, exc)
                continue
            stats.eligible += 1
            if not execute:
                LOG.info("DRY RUN: deployment %s (%s) would be deleted; no delete submitted",
                         target.deployment_id, target.rows[0].deployment_name)
                continue
            # Include POST duration in the deadline; monotonic time ignores clock adjustments.
            started = time.monotonic()
            try:
                request_id = submit_delete(client, target)
                if request_id in request_ids:
                    raise InventoryError("Server returned a duplicate request ID")
            except (InventoryError, OSError) as exc:
                # The server may have accepted the POST before the connection failed.
                stats.failures += 1
                LOG.error(
                    "FAILED submission for deployment %s: %s. Outcome may be uncertain; "
                    "check the server before retrying. No automatic resubmission.",
                    target.deployment_id, exc,
                )
                continue
            request_ids.add(request_id)
            stats.submitted += 1
            board.append(Outstanding(target, request_id, started))
            LOG.info("SUBMITTED deployment %s request %s", target.deployment_id, request_id)
        # Scan a snapshot so completed/expired slots can be removed during iteration.
        for outstanding in tuple(board):
            elapsed = time.monotonic() - outstanding.started
            if elapsed >= request_timeout:
                # Expire local tracking only; this does not cancel the remote operation.
                stats.failures += 1
                stats.timed_out += 1
                LOG.error(
                    "TIMED OUT deployment %s request %s after %.1fs; removed from chalkboard. "
                    "Server operation is NOT cancelled and may still complete.",
                    outstanding.target.deployment_id, outstanding.request_id, elapsed,
                )
                board.remove(outstanding)
                continue
            try:
                outcome = deletion_complete(client, outstanding)
            except (InventoryError, OSError) as exc:
                # Keep uncertain requests occupying their slot rather than prematurely refilling it.
                LOG.error("POLL ERROR request %s: %s; retaining slot until completion/timeout",
                          outstanding.request_id, exc)
                continue
            if outcome != "pending":
                board.remove(outstanding)
                if outcome == "successful":
                    stats.successful += 1
                    LOG.info("DELETED deployment %s request %s",
                             outstanding.target.deployment_id, outstanding.request_id)
                else:
                    stats.failures += 1
                    LOG.error("FAILED deletion deployment %s request %s",
                              outstanding.target.deployment_id, outstanding.request_id)
        # Refill free slots immediately; otherwise wait no longer than the nearest deadline.
        if board and not (queue and len(board) < parallel):
            remaining = min(request_timeout - (time.monotonic() - item.started) for item in board)
            time.sleep(max(0, min(poll_interval, remaining)))
    return stats


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    add_connection_arguments(result)
    result.add_argument("--input", required=True, type=Path, help="Enriched inventory CSV")
    result.add_argument("--execute", action="store_true", help="Submit deletes (default: dry run)")
    result.add_argument("--parallel", type=positive_int, default=5, help="Outstanding request slots")
    result.add_argument("--poll-interval", type=positive_float, default=5, help="Seconds between scans")
    result.add_argument("--request-timeout", type=positive_float, default=300,
                        help="Seconds per deletion request, independent of HTTP --timeout")
    result.add_argument("--log-file", type=Path, default=Path("deployment-deletions.log"))
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    stats = Statistics()
    try:
        if args.log_file.resolve() == args.input.resolve():
            raise InventoryError("--log-file must not overwrite the input CSV")
        with args.log_file.open("a", encoding="utf-8") as log_handle:
            handler = logging.StreamHandler(log_handle)
            handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s: %(message)s"))
            root = logging.getLogger()
            if not root.handlers:
                logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
            old_level = root.level
            root.setLevel(logging.INFO)
            root.addHandler(handler)
            try:
                # Reject malformed input before authentication or any destructive request.
                targets = load_targets(args.input)
                LOG.info("Loaded %d deployments; mode=%s, slots=%d", len(targets),
                         "EXECUTE" if args.execute else "DRY RUN", args.parallel)
                if targets:
                    run(
                        authenticated_client(args), targets, execute=args.execute,
                        parallel=args.parallel, poll_interval=args.poll_interval,
                        request_timeout=args.request_timeout, stats=stats,
                    )
            except (InventoryError, OSError, csv.Error, UnicodeError) as exc:
                stats.failures += 1
                LOG.error("FAILED: %s", exc)
                return 1
            except KeyboardInterrupt:
                LOG.error(
                    "Interrupted; server requests are not cancelled. "
                    "Consult the SUBMITTED entries before retrying."
                )
                return 130
            finally:
                # Persist partial totals on errors/interruption, before closing the log.
                LOG.info(
                    "SUMMARY successful=%d failures=%d skipped=%d timed_out=%d eligible=%d submitted=%d",
                    stats.successful, stats.failures, stats.skipped, stats.timed_out,
                    stats.eligible, stats.submitted,
                )
                root.removeHandler(handler)
                root.setLevel(old_level)
        return 1 if stats.failures else (2 if stats.skipped else 0)
    except (InventoryError, OSError, csv.Error, UnicodeError) as exc:
        LOG.error("%s", exc)
        return 1
    except KeyboardInterrupt:
        LOG.error("Interrupted; server requests are not cancelled. Consult the log before retrying.")
        return 130


if __name__ == "__main__":
    sys.exit(main())
