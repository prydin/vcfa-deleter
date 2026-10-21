from __future__ import annotations

import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import vm_apps_delete as delete
import vm_apps_inventory as app
from test_vm_apps_inventory import DEPLOYMENTS, RESOURCES, ZONE, inventory_client, row, vm


def target(dep_id: str = "dep-1", rows: tuple[app.InventoryRow, ...] | None = None) -> delete.Target:
    return delete.Target(dep_id, rows or (row()._replace(deployment_id=dep_id, status="missing"),))


def deletion_client(resources: list[app.Record] | None = None):
    resources = resources if resources is not None else [{**vm(), "syncStatus": "MISSING"}]
    client = inventory_client(resources)
    client.responses[DEPLOYMENTS + "/dep-1"] = [{"id": "dep-1", "name": "App"}]
    client.responses[RESOURCES].append({"content": resources, "last": True})
    return client


class InputTests(unittest.TestCase):
    def test_enriched_inventory_round_trip_and_grouping(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "vms.csv"
            app.write_csv(path, [row(), row("b")])
            targets = delete.load_targets(path)
            self.assertEqual(len(targets), 1)
            self.assertEqual(targets[0].rows, (row(), row("b")))

    def test_legacy_empty_malformed_duplicate_and_cross_zone_rejected(self) -> None:
        header = ",".join(app.InventoryRow._fields) + "\n"
        line = ",".join(row()) + "\n"
        for contents in (
            "vm_name,deployment_name,status\nvm-a,App,missing\n",
            header + line + line,
            header + line.rstrip("\n") + ",extra\n",
            header + "vm-a,App,missing,,,,,\n",
            header + line + ",".join(row("b")._replace(cloudzone_id="other")) + "\n",
        ):
            with self.subTest(contents=contents), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "vms.csv"
                path.write_text(contents, encoding="utf-8")
                with self.assertRaises(app.InventoryError):
                    delete.load_targets(path)

    def test_empty_enriched_file_produces_empty_queue(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "vms.csv"
            app.write_csv(path, [])
            self.assertEqual(delete.load_targets(path), [])


class ValidationTests(unittest.TestCase):
    def test_aria_region_name_fallback_checks_all_deployment_vms(self) -> None:
        for overrides, qualifies in (
            ({}, True),
            ({"region": "other"}, False),
            ({"endpointId": "other"}, False),
            ({"computeHostRef": "ResourcePool:other"}, False),
            ({"datacenter": "other"}, False),
        ):
            with self.subTest(overrides=overrides):
                second = {**vm("b", datacenter="", region="vcf-lab-dc-01"), "syncStatus": "MISSING"}
                app.properties(second, "properties").update(overrides)
                resources = [
                    {**vm(datacenter="", region="vcf-lab-dc-01"), "syncStatus": "MISSING"}, second,
                ]
                client = deletion_client(resources)
                client.responses["/iaas/api/regions/region-1"][0]["name"] = "vcf-lab-dc-01"
                deployment = target(rows=(row(), row("b")))
                if qualifies:
                    delete.validate_target(client, deployment)
                else:
                    with self.assertRaises(delete.CheckFailed):
                        delete.validate_target(client, deployment)

    def test_valid_missing_vm_with_compute_reference(self) -> None:
        client = deletion_client()
        delete.validate_target(client, target())
        self.assertEqual(sum(path == RESOURCES for path, _ in client.calls), 2)

    def test_csv_status_does_not_replace_fresh_check(self) -> None:
        delete.validate_target(deletion_client(), target(rows=(row(),)))
        with self.assertRaisesRegex(delete.CheckFailed, "not Missing"):
            delete.validate_target(deletion_client([vm()]), target())

    def test_all_vms_must_be_missing(self) -> None:
        resources = [{**vm(), "syncStatus": "MISSING"}, vm("b")]
        with self.assertRaisesRegex(delete.CheckFailed, "not Missing"):
            delete.validate_target(deletion_client(resources), target(rows=(row(), row("b"))))

    def test_all_vms_must_be_in_same_recorded_zone(self) -> None:
        resources = [
            {**vm(), "syncStatus": "MISSING"},
            {**vm("b", computeHostRef="ResourcePool:other"), "syncStatus": "MISSING"},
        ]
        with self.assertRaisesRegex(delete.CheckFailed, "no longer connected"):
            delete.validate_target(deletion_client(resources), target(rows=(row(), row("b"))))

    def test_extra_or_absent_vm_or_empty_deployment_is_skipped(self) -> None:
        for resources in ([], [vm(), vm("b")], [vm("other")]):
            with self.subTest(resources=resources), self.assertRaisesRegex(
                delete.CheckFailed, "VM set differs",
            ):
                delete.validate_target(deletion_client(resources), target())

    def test_changed_zone_identity_name_or_deployment_name(self) -> None:
        for path, replacement in (
            ("/iaas/api/zones/zone-1", {**ZONE, "id": "other"}),
            ("/iaas/api/zones/zone-1", {**ZONE, "name": "other"}),
            (DEPLOYMENTS + "/dep-1", {"id": "dep-1", "name": "other"}),
        ):
            client = deletion_client()
            client.responses[path] = [replacement]
            with self.subTest(path=path), self.assertRaises(delete.CheckFailed):
                delete.validate_target(client, target())

    def test_missing_zone_evidence_blocks_delete(self) -> None:
        resource = {**vm(computeHostRef="", zone=""), "syncStatus": "MISSING"}
        with self.assertRaisesRegex(delete.CheckFailed, "cannot be verified"):
            delete.validate_target(deletion_client([resource]), target())

    def test_name_only_zone_match_is_insufficient_for_delete(self) -> None:
        resource = {**vm(computeHostRef="", zone="Production"), "syncStatus": "MISSING"}
        with self.assertRaisesRegex(delete.CheckFailed, "cannot be verified"):
            delete.validate_target(deletion_client([resource]), target())

    def test_explicit_zone_id_without_compute_reference_can_qualify(self) -> None:
        resource = {**vm(zoneId="zone-1", computeHostRef=""), "syncStatus": "MISSING"}
        delete.validate_target(deletion_client([resource]), target())

    def test_new_resource_appearing_during_validation_blocks_delete(self) -> None:
        client = deletion_client()
        client.responses[RESOURCES][-1] = {
            "content": [vm(), {"id": "new-disk", "type": "Cloud.vSphere.Disk"}], "last": True,
        }
        with self.assertRaisesRegex(delete.CheckFailed, "changed during"):
            delete.validate_target(client, target())

    def test_explicit_zone_cannot_override_conflicting_compute(self) -> None:
        resource = {**vm(zoneId="zone-1", endpointId="other"), "syncStatus": "MISSING"}
        with self.assertRaises(delete.CheckFailed):
            delete.validate_target(deletion_client([resource]), target())

    def test_live_vm_id_change_is_skipped(self) -> None:
        resource = {**vm(resourceId="other"), "syncStatus": "MISSING"}
        with self.assertRaisesRegex(delete.CheckFailed, "VM identity"):
            delete.validate_target(deletion_client([resource]), target())

    def test_non_vm_resource_without_type_is_not_silently_ignored(self) -> None:
        client = deletion_client([{**vm(), "syncStatus": "MISSING"}, {"id": "unknown-resource"}])
        with self.assertRaisesRegex(app.InventoryError, "type"):
            delete.validate_target(client, target())

    def test_name_only_match_does_not_authorize_another_vm(self) -> None:
        resource = {**vm("different-id", resourceName="vm-a"), "syncStatus": "MISSING"}
        with self.assertRaises(delete.CheckFailed):
            delete.validate_target(deletion_client([resource]), target())

    def test_only_fresh_top_level_sync_status_authorizes_delete(self) -> None:
        for state in ("MISSING", "missing", "MiSsInG"):
            with self.subTest(state=state):
                client = deletion_client([vm()])
                client.responses[RESOURCES + "/a"] = [{**vm(), "syncStatus": state}]
                delete.validate_target(client, target())
        for resource in (
            vm(powerState="MISSING", missing=True, __missing="true"),
            {**vm(), "state": "MISSING", "syncState": "MISSING"},
            {**vm(), "syncStatus": None},
            {**vm(), "syncStatus": ""},
            {**vm(), "syncStatus": {"state": "MISSING"}},
            vm(syncStatus="MISSING"),
        ):
            with self.subTest(resource=resource):
                client = deletion_client()
                client.responses[RESOURCES + "/a"] = [resource]
                with self.assertRaisesRegex(delete.CheckFailed, "syncStatus is not Missing"):
                    delete.validate_target(client, target())
class RequestTests(unittest.TestCase):
    def test_submit_exact_delete_action_once(self) -> None:
        client = Mock(spec=app.Client)
        client.request.return_value = (b'{"id":"request-1"}', {})
        client.decode.side_effect = app.Client.decode
        self.assertEqual(delete.submit_delete(client, target()), "request-1")
        args, kwargs = client.request.call_args
        self.assertEqual(args, ("POST", DEPLOYMENTS + "/dep-1/requests"))
        self.assertEqual(json.loads(kwargs["data"])["actionId"], "Deployment.Delete")
        self.assertEqual(json.loads(kwargs["data"])["inputs"], {})
        client.request.assert_called_once()

    def test_request_success_requires_deployment_disappearance(self) -> None:
        outstanding = delete.Outstanding(target(), "r", 0)
        client = Mock(spec=app.Client)
        client.get.side_effect = [
            {"id": "r", "status": "SUCCESSFUL"}, {"id": "dep-1"},
            {"id": "r", "status": "SUCCESSFUL"},
            app.ApiError("GET", DEPLOYMENTS + "/dep-1", 404),
        ]
        self.assertEqual(delete.deletion_complete(client, outstanding), "pending")
        self.assertEqual(delete.deletion_complete(client, outstanding), "successful")

    def test_request_failure_pending_unknown_and_identity_mismatch(self) -> None:
        outstanding = delete.Outstanding(target(), "r", 0)
        for status in delete.FAILED_STATES:
            client = Mock(spec=app.Client)
            client.get.return_value = {"id": "r", "status": status}
            self.assertEqual(delete.deletion_complete(client, outstanding), "failed")
        for record in (
            {"id": "other", "status": "SUCCESSFUL"},
            {"id": "r", "status": "SUCCESSFUL", "deploymentId": "other"},
            {"id": "r", "status": "SUCCESSFUL", "actionId": "Other.Action"},
        ):
            client.get.return_value = record
            with self.assertRaises(app.InventoryError):
                delete.deletion_complete(client, outstanding)
        client.get.return_value = {"id": "r", "status": "NEW_UNKNOWN_STATUS"}
        with self.assertLogs(delete.LOG, level="WARNING"):
            self.assertEqual(delete.deletion_complete(client, outstanding), "pending")


class Clock:
    def __init__(self) -> None:
        self.now = 0.0

    def monotonic(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


class ChalkboardTests(unittest.TestCase):
    def test_failed_request_frees_slot_and_next_target_checked_just_in_time(self) -> None:
        events: list[str] = []

        def validate(client, item):
            events.append("validate " + item.deployment_id)
            if item.deployment_id == "d2":
                raise delete.CheckFailed("VM recovered while queued")

        def submit(client, item):
            events.append("submit " + item.deployment_id)
            return "r"

        def poll(client, item):
            events.append("poll")
            return "failed"

        with patch.object(delete, "validate_target", validate), \
             patch.object(delete, "submit_delete", submit), \
             patch.object(delete, "deletion_complete", poll), self.assertLogs(delete.LOG):
            stats = delete.run(Mock(), [target("d1"), target("d2")], execute=True, parallel=1)
        self.assertEqual(events, ["validate d1", "submit d1", "poll", "validate d2"])
        self.assertEqual((stats.failures, stats.skipped, stats.submitted), (1, 1, 1))

    def test_five_slots_refilled_until_queue_empty(self) -> None:
        targets = [target(f"d{i}") for i in range(13)]
        events: list[tuple[str, str]] = []
        active: set[str] = set()
        peak = 0
        polls: dict[str, int] = {}
        clock = Clock()

        def submit(client, item):
            nonlocal peak
            active.add(item.deployment_id)
            peak = max(peak, len(active))
            events.append(("submit", item.deployment_id))
            return item.deployment_id

        def poll(client, item):
            events.append(("poll", item.request_id))
            count = polls.get(item.request_id, 0) + 1
            polls[item.request_id] = count
            if count == 1:
                return "pending"
            active.remove(item.request_id)
            return "successful"

        with patch.object(delete, "validate_target"), patch.object(delete, "submit_delete", submit), \
             patch.object(delete, "deletion_complete", poll), \
             patch.object(delete.time, "monotonic", clock.monotonic), \
             patch.object(delete.time, "sleep", clock.sleep):
            stats = delete.run(Mock(), targets, execute=True)
        self.assertEqual(peak, 5)
        self.assertEqual(stats.successful, 13)
        self.assertEqual(stats.submitted, 13)
        self.assertEqual(stats.failures, 0)
        self.assertEqual(events[:5], [("submit", f"d{i}") for i in range(5)])
        self.assertFalse(active)

    def test_timeout_frees_slot_and_counts_failure_without_cancellation(self) -> None:
        clock = Clock()
        with patch.object(delete, "validate_target"), \
             patch.object(delete, "submit_delete", side_effect=["r1", "r2"]) as submit, \
             patch.object(delete, "deletion_complete", return_value="pending"), \
             patch.object(delete.time, "monotonic", clock.monotonic), \
             patch.object(delete.time, "sleep", clock.sleep), \
             self.assertLogs(delete.LOG, level="ERROR"):
            stats = delete.run(Mock(), [target("d1"), target("d2")], execute=True,
                               parallel=1, request_timeout=10, poll_interval=3)
        self.assertEqual(submit.call_count, 2)
        self.assertEqual(stats.failures, 2)
        self.assertEqual(stats.timed_out, 2)
        self.assertEqual(clock.now, 20)

    def test_validation_skip_failure_and_success_statistics(self) -> None:
        with patch.object(delete, "validate_target", side_effect=[
            delete.CheckFailed("not missing"), app.InventoryError("HTTP error"), None,
        ]), patch.object(delete, "submit_delete", return_value="r") as submit, \
             patch.object(delete, "deletion_complete", return_value="successful"), \
             self.assertLogs(delete.LOG):
            stats = delete.run(Mock(), [target("d1"), target("d2"), target("d3")], execute=True)
        self.assertEqual((stats.skipped, stats.failures, stats.successful), (1, 1, 1))
        submit.assert_called_once()

    def test_dry_run_never_submits_or_polls(self) -> None:
        with patch.object(delete, "validate_target") as validate, \
             patch.object(delete, "submit_delete") as submit, \
             patch.object(delete, "deletion_complete") as poll:
            stats = delete.run(Mock(), [target()])
        validate.assert_called_once()
        submit.assert_not_called()
        poll.assert_not_called()
        self.assertEqual((stats.eligible, stats.submitted, stats.successful), (1, 0, 0))

    def test_poll_errors_keep_slot_until_timeout(self) -> None:
        clock = Clock()
        with patch.object(delete, "validate_target"), \
             patch.object(delete, "submit_delete", return_value="r") as submit, \
             patch.object(delete, "deletion_complete", side_effect=app.InventoryError("HTTP 404")), \
             patch.object(delete.time, "monotonic", clock.monotonic), \
             patch.object(delete.time, "sleep", clock.sleep), self.assertLogs(delete.LOG):
            stats = delete.run(Mock(), [target()], execute=True,
                               poll_interval=2, request_timeout=5)
        submit.assert_called_once()
        self.assertEqual(stats.timed_out, 1)
        self.assertEqual(stats.successful, 0)

    def test_ambiguous_submit_not_retried_and_other_request_drained(self) -> None:
        with patch.object(delete, "validate_target"), \
             patch.object(delete, "submit_delete", side_effect=[
                 "r1", app.InventoryError("connection lost"),
             ]) as submit, patch.object(delete, "deletion_complete", return_value="successful"), \
             self.assertLogs(delete.LOG):
            stats = delete.run(Mock(), [target("d1"), target("d2")], execute=True)
        self.assertEqual(submit.call_count, 2)
        self.assertEqual((stats.successful, stats.failures), (1, 1))


@patch.dict("os.environ", {}, clear=True)
class CliTests(unittest.TestCase):
    def test_legacy_delete_main_authenticates_and_preserves_default_dry_run(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "legacy.csv"
            logfile = Path(directory) / "legacy.log"
            app.write_csv(path, [row(status="missing")])

            def validate(client: app.Client, target: delete.Target) -> None:
                self.assertEqual(client.token, "legacy-access")
                self.assertEqual(target.deployment_id, "dep-1")

            with patch.object(app.Client, "request", return_value=(b'{"token":"legacy-access"}', {})) as request, \
                 patch.object(delete, "validate_target", side_effect=validate) as check, \
                 patch.object(delete, "submit_delete") as submit, self.assertLogs():
                result = delete.main([
                    "--host", "example.invalid", "--legacy", "--api-token", "legacy-refresh",
                    "--input", str(path), "--log-file", str(logfile),
                ])
            self.assertEqual(result, 0)
            self.assertEqual(request.call_args.args, ("POST", "/iaas/api/login"))
            check.assert_called_once()
            submit.assert_not_called()
            self.assertIn("would be deleted", logfile.read_text())

    def test_defaults(self) -> None:
        args = delete.parser().parse_args(["--host", "host", "--input", "vms.csv"])
        self.assertFalse(args.execute)
        self.assertEqual(args.parallel, 5)
        self.assertEqual(args.request_timeout, 300)

    def test_execute_is_opt_in_and_dryrun_flag_is_rejected(self) -> None:
        base = ["--host", "host", "--input", "vms.csv"]
        self.assertTrue(delete.parser().parse_args([*base, "--execute"]).execute)
        for flags in (["--dryrun"], ["--dryrun", "--execute"], ["--execute", "--dryrun"]):
            with self.subTest(flags=flags), patch("sys.stderr", new_callable=io.StringIO), \
                 self.assertRaises(SystemExit):
                delete.parser().parse_args([*base, *flags])

    def test_invalid_limits(self) -> None:
        for option, value in (("--parallel", "0"), ("--request-timeout", "-1"),
                              ("--poll-interval", "nan")):
            with self.subTest(option=option), patch("sys.stderr", new_callable=io.StringIO), \
                 self.assertRaises(SystemExit):
                delete.parser().parse_args(["--host", "host", "--input", "v.csv", option, value])

    def test_input_validation_before_auth_and_persistent_summary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "vms.csv"
            logfile = Path(directory) / "deletions.log"
            path.write_text("vm_name,deployment_name,status\nvm,App,missing\n")
            with patch.object(delete, "authenticated_client") as auth, self.assertLogs():
                result = delete.main(["--host", "host", "--input", str(path),
                                      "--log-file", str(logfile)])
            self.assertEqual(result, 1)
            auth.assert_not_called()
            self.assertIn("SUMMARY", logfile.read_text())

    def test_enriched_csv_end_to_end_dry_run(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "vms.csv"
            logfile = Path(directory) / "deletions.log"
            app.write_csv(path, [row(status="missing")])
            client = deletion_client()
            with patch.object(delete, "authenticated_client", return_value=client), \
                 patch.object(delete, "submit_delete") as submit, \
                 patch.object(delete, "deletion_complete") as poll, self.assertLogs():
                result = delete.main([
                    "--host", "host", "--input", str(path),
                    "--log-file", str(logfile),
                ])
            self.assertEqual(result, 0)
            submit.assert_not_called()
            poll.assert_not_called()
            self.assertIn((RESOURCES + "/a", None), client.calls)
            self.assertIn("would be deleted; no delete submitted", logfile.read_text())
            self.assertIn("successful=0 failures=0 skipped=0", logfile.read_text())
            self.assertIn("eligible=1 submitted=0", logfile.read_text())

    def test_enriched_csv_execute_full_mock_http_flow(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "vms.csv"
            logfile = Path(directory) / "deletions.log"
            app.write_csv(path, [row(status="missing")])
            client = deletion_client()
            client.request = Mock(return_value=(b'{"id":"r"}', {}))
            original = client.get

            def get(path: str, params: app.Record | None = None) -> app.Record:
                if path == "/deployment/api/requests/r":
                    return {"id": "r", "status": "SUCCESSFUL",
                            "deploymentId": "dep-1", "actionId": "Deployment.Delete"}
                if path == DEPLOYMENTS + "/dep-1" and not client.responses[path]:
                    raise app.ApiError("GET", path, 404)
                return original(path, params)

            client.get = get
            with patch.object(delete, "authenticated_client", return_value=client), self.assertLogs():
                result = delete.main([
                    "--host", "host", "--input", str(path),
                    "--log-file", str(logfile), "--execute",
                ])
            self.assertEqual(result, 0)
            client.request.assert_called_once()
            self.assertIn("successful=1 failures=0 skipped=0", logfile.read_text())
            self.assertIn("SUBMITTED", logfile.read_text())


if __name__ == "__main__":
    unittest.main()
