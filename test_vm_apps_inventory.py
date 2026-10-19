from __future__ import annotations

import argparse
import csv
from email.message import Message
import io
from pathlib import Path
import ssl
import tempfile
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlsplit

import vm_apps_inventory as app


ZONE: app.Record = {
    "id": "zone-1", "name": "Production",
    "_links": {"region": {"href": "/iaas/api/regions/region-1"}},
}
DEPLOYMENTS = "/deployment/api/deployments"
RESOURCES = DEPLOYMENTS + "/dep-1/resources"


class FakeClient(app.Client):
    def __init__(self, responses: dict[str, list[app.Record]]) -> None:
        self.responses = responses
        self.calls: list[tuple[str, app.Record | None]] = []
        self.page_size = 100

    def get(self, path: str, params: app.Record | None = None) -> app.Record:
        self.calls.append((path, params))
        if path not in self.responses or not self.responses[path]:
            raise AssertionError(f"Unexpected GET {path} {params}")
        return self.responses[path].pop(0)


def vm(vm_id: str = "a", **overrides: object) -> app.Record:
    return {
        "id": vm_id, "type": "Cloud.vSphere.Machine", "name": "Blueprint_component",
        "syncStatus": "SUCCESS",
        "properties": {
            "resourceId": vm_id, "resourceName": f"vm-{vm_id}", "powerState": "ON",
            "zone": "cluster / pool", "computeHostRef": "ResourcePool:pool-1",
            "endpointId": "account-1", "datacenter": "dc-1", "vcUuid": "vc-1",
            **overrides,
        },
    }


def row(vm_id: str = "a", name: str | None = None, status: str = "SUCCESS") -> app.InventoryRow:
    return app.InventoryRow(
        name or f"vm-{vm_id}", "App", status, vm_id, vm_id, "dep-1", "Production", "zone-1",
    )


def inventory_client(resources: list[app.Record]) -> FakeClient:
    responses: dict[str, list[app.Record]] = {
        "/iaas/api/zones": [{"content": [ZONE], "totalElements": 1}],
        "/iaas/api/zones/zone-1": [ZONE],
        DEPLOYMENTS: [{"content": [{"id": "dep-1", "name": "App"}], "last": True}],
        RESOURCES: [{"content": resources, "last": True}],
        "/iaas/api/regions/region-1": [{
            "cloudAccountId": "account-1", "externalRegionId": "dc-1",
        }],
        "/iaas/api/zones/zone-1/computes": [{
            "content": [{
                "id": "compute-1", "type": "ResourcePool", "externalId": "pool-1",
                "externalRegionId": "dc-1", "customProperties": {"vcUuid": "vc-1"},
            }], "totalElements": 1,
        }],
    }
    for resource in resources:
        responses[f"{RESOURCES}/{resource['id']}"] = [resource]
    return FakeClient(responses)


class ZoneTests(unittest.TestCase):
    def test_resource_pool_label_is_not_cloud_zone_name(self) -> None:
        self.assertIsNone(app.zone_membership(vm(), ZONE))

    def test_explicit_ids_and_links(self) -> None:
        self.assertTrue(app.zone_membership({"zoneId": "zone-1"}, ZONE))
        self.assertFalse(app.zone_membership({"cloudZoneId": "other"}, ZONE))
        self.assertTrue(app.zone_membership({
            "_links": {"zone": {"href": "/iaas/api/zones/zone-1"}},
        }, ZONE))

    def test_external_zone_and_region_do_not_prove_membership(self) -> None:
        self.assertIsNone(app.zone_membership({
            "externalZoneId": "zone-1", "externalRegionId": "Production",
        }, ZONE))

    def test_name_and_id_precedence(self) -> None:
        self.assertTrue(app.zone_membership({"properties": {"zone": "Production"}}, ZONE))
        self.assertFalse(app.zone_membership({"properties": {"zone": "production"}}, ZONE))
        self.assertFalse(app.zone_membership({
            "zoneId": "other", "properties": {"zone": "Production"},
        }, ZONE))

    def test_conflicting_ids_fail(self) -> None:
        with self.assertRaises(app.InventoryError):
            app.zone_membership({
                "zoneId": "zone-1", "customProperties": {"zoneId": "other"},
            }, ZONE)


class StateTests(unittest.TestCase):
    def test_sync_status_values_are_preserved(self) -> None:
        for state in ("SUCCESS", "FAILED", "UNKNOWN"):
            with self.subTest(state=state):
                self.assertEqual(app.sync_status({**vm(), "syncStatus": state}), state)

    def test_sync_status_is_the_only_missing_indicator(self) -> None:
        for state in ("MISSING", "missing", "MiSsInG"):
            resource = {**vm(), "syncStatus": state}
            with self.subTest(state=state):
                self.assertEqual(app.sync_status(resource), "missing")
        for resource in (
            {**vm(), "state": "MISSING"}, vm(missing=True),
            vm(__missing="true"), vm(powerState="MISSING"),
            {**vm(), "customProperties": {"__missing": "true"}},
            {**vm(), "syncState": "MISSING"},
            {**vm(), "syncStatus": "SUCCESS"},
            vm(syncStatus="MISSING"),
        ):
            with self.subTest(resource=resource):
                self.assertEqual(app.sync_status(resource), "SUCCESS")

    def test_absent_or_invalid_sync_status_is_unknown_not_missing(self) -> None:
        for resource in (
            {"id": "a", "powerState": "MISSING", "state": "MISSING", "missing": True,
             "customProperties": {"syncStatus": "MISSING"}},
            {**vm(), "syncStatus": None},
            {**vm(), "syncStatus": ""},
            {**vm(), "syncStatus": {"state": "MISSING"}},
        ):
            with self.subTest(resource=resource), self.assertLogs(app.LOG, level="WARNING"):
                self.assertEqual(app.sync_status(resource), "unknown")


class PaginationTests(unittest.TestCase):
    def test_iaas_capped_pages(self) -> None:
        client = FakeClient({"/iaas/api/zones": [
            {"content": [{"id": "a"}], "totalElements": 2},
            {"content": [{"id": "b"}], "totalElements": 2},
        ]})
        self.assertEqual(len(list(client.records("/iaas/api/zones"))), 2)
        self.assertEqual([p["$skip"] for _, p in client.calls if p], [0, 1])

    def test_spring_capped_pages(self) -> None:
        client = FakeClient({DEPLOYMENTS: [
            {"content": [{"id": "a"}], "last": False},
            {"content": [{"id": "b"}], "last": True},
        ]})
        self.assertEqual(len(list(client.records(DEPLOYMENTS))), 2)
        self.assertEqual([p["page"] for _, p in client.calls if p], [0, 1])

    def test_repeated_ids_fail(self) -> None:
        client = FakeClient({DEPLOYMENTS: [
            {"content": [{"id": "a"}]}, {"content": [{"id": "a"}]},
        ]})
        with self.assertRaisesRegex(app.InventoryError, "repeated ID"):
            list(client.records(DEPLOYMENTS))

    def test_malformed_and_truncated_pages_fail(self) -> None:
        for page in ({}, {"content": [], "totalElements": 3},
                     {"content": [{"id": "a"}], "totalElements": 3, "last": True}):
            with self.subTest(page=page), self.assertRaises(app.InventoryError):
                list(FakeClient({DEPLOYMENTS: [page]}).records(DEPLOYMENTS))


class InventoryTests(unittest.TestCase):
    def test_request_count_and_no_machine_scan_or_unnecessary_details(self) -> None:
        client = inventory_client([vm(), vm("b"), {
            "id": "disk", "type": "Cloud.vSphere.Disk",
        }])
        self.assertEqual(app.Inventory(client).collect("Production"), [
            row(), row("b"),
        ])
        self.assertEqual(len(client.calls), 8)
        self.assertFalse(any(path.startswith("/iaas/api/machines") for path, _ in client.calls))
        self.assertFalse(any(path == RESOURCES + "/disk" for path, _ in client.calls))

    def test_membership_uses_fresh_resource_not_stale_list(self) -> None:
        client = inventory_client([vm(zoneId="other"), vm("b", zoneId="zone-1")])
        client.responses[RESOURCES + "/a"] = [vm(zoneId="zone-1")]
        client.responses[RESOURCES + "/b"] = [vm("b", zoneId="other")]
        self.assertEqual(app.Inventory(client).collect("Production"), [row()])

    def test_missing_vm_retained_without_iaas_record(self) -> None:
        client = inventory_client([{**vm(), "syncStatus": "MISSING"}])
        self.assertEqual(app.Inventory(client).collect("Production"), [row(status="missing")])

    def test_account_region_and_compute_checked_per_resource(self) -> None:
        for overrides in (
            {"endpointId": "other"}, {"datacenter": "other"},
            {"computeHostRef": "ResourcePool:other"},
        ):
            with self.subTest(overrides=overrides):
                self.assertEqual(
                    app.Inventory(inventory_client([vm(**overrides)])).collect("Production"), [],
                )

    def test_vcenter_mismatch_fails(self) -> None:
        with self.assertRaisesRegex(app.InventoryError, "different vCenters"):
            app.Inventory(inventory_client([vm(vcUuid="other")])).collect("Production")

    def test_missing_evidence_is_incomplete(self) -> None:
        inventory = app.Inventory(inventory_client([vm(computeHostRef="", zone="")]))
        with self.assertLogs(app.LOG, level="WARNING"):
            self.assertEqual(inventory.collect("Production"), [])
        self.assertEqual(inventory.unverified, 1)

    def test_missing_name_fetches_only_that_machine(self) -> None:
        client = inventory_client([vm(resourceName="")])
        client.responses["/iaas/api/machines/a"] = [{"id": "a", "name": "actual-vm"}]
        self.assertEqual(app.Inventory(client).collect("Production"), [row(name="actual-vm")])

    def test_detail_404_is_incomplete_not_missing(self) -> None:
        client = inventory_client([vm()])
        original = client.get

        def get(path: str, params: app.Record | None = None) -> app.Record:
            if path == RESOURCES + "/a":
                raise app.ApiError("GET", path, 404)
            return original(path, params)

        client.get = get
        inventory = app.Inventory(client)
        with self.assertLogs(app.LOG, level="WARNING"):
            self.assertEqual(inventory.collect("Production"), [])
        self.assertEqual(inventory.unverified, 1)

    def test_identity_or_association_changes_fail(self) -> None:
        for detail in (vm("other"), {**vm(), "type": "Cloud.vSphere.Disk"}, vm(resourceId="other")):
            client = inventory_client([vm()])
            client.responses[RESOURCES + "/a"] = [detail]
            with self.subTest(detail=detail), self.assertRaises(app.InventoryError):
                app.Inventory(client).collect("Production")

    def test_duplicate_names_remain_distinct(self) -> None:
        client = inventory_client([vm(resourceName="same"), vm("b", resourceName="same")])
        self.assertEqual(len(app.Inventory(client).collect("Production")), 2)

    def test_same_vm_in_multiple_resources_fails(self) -> None:
        client = inventory_client([vm(), vm("b", resourceId="a")])
        with self.assertRaisesRegex(app.InventoryError, "multiple deployment resources"):
            app.Inventory(client).collect("Production")

    def test_empty_deployments(self) -> None:
        client = inventory_client([])
        client.responses[DEPLOYMENTS] = [{"content": [], "totalElements": 0}]
        self.assertEqual(app.Inventory(client).collect("Production"), [])

    def test_duplicate_zone_names_fail(self) -> None:
        client = inventory_client([])
        client.responses["/iaas/api/zones"] = [{
            "content": [ZONE, {**ZONE, "id": "zone-2"}], "totalElements": 2,
        }]
        with self.assertRaisesRegex(app.InventoryError, "found 2"):
            app.Inventory(client).collect("Production")


class HttpTests(unittest.TestCase):
    def client(self) -> app.Client:
        return app.Client("example.invalid", ssl.create_default_context(), 5, 100,
                          "2021-07-15", "40.0")

    def test_api_token_exchange(self) -> None:
        client = self.client()
        client.request = Mock(return_value=(b'{"access_token":"access"}', {}))
        client.authenticate(argparse.Namespace(
            api_token="secret-token", org="my org", username=None, password=None,
        ))
        self.assertEqual(client.token, "access")
        args, kwargs = client.request.call_args
        self.assertEqual(args, ("POST", "/oauth/tenant/my%20org/token"))
        self.assertEqual(parse_qs(kwargs["data"].decode()), {
            "grant_type": ["refresh_token"], "refresh_token": ["secret-token"],
        })

    def test_session_auth(self) -> None:
        client = self.client()
        client.request = Mock(return_value=(b"", {"x-vmware-vcloud-access-token": "access"}))
        client.authenticate(argparse.Namespace(
            api_token=None, org="tenant", username="user", password="pass",
        ))
        self.assertEqual(client.request.call_args.args, ("POST", "/cloudapi/1.0.0/sessions"))
        self.assertEqual(client.token, "access")

    def test_request_parameters_and_bearer(self) -> None:
        client = self.client()
        client.token = "access"
        response = Mock()
        response.read.return_value = b'{"content":[]}'
        response.headers = Message()
        client.opener = Mock()
        client.opener.open.return_value.__enter__ = Mock(return_value=response)
        client.opener.open.return_value.__exit__ = Mock(return_value=False)
        self.assertEqual(client.get("/iaas/api/zones", {"$skip": 3}), {"content": []})
        request = client.opener.open.call_args.args[0]
        self.assertEqual(parse_qs(urlsplit(request.full_url).query), {
            "$skip": ["3"], "apiVersion": ["2021-07-15"],
        })
        self.assertEqual(request.get_header("Authorization"), "Bearer access")

    def test_http_errors_do_not_leak_response(self) -> None:
        client = self.client()
        client.opener = Mock()
        client.opener.open.side_effect = HTTPError(
            "https://example.invalid/path", 403, "secret", Message(), io.BytesIO(b"secret"),
        )
        with self.assertRaises(app.ApiError) as caught:
            client.get("/path")
        self.assertEqual(str(caught.exception), "GET /path: HTTP 403")

    def test_invalid_hosts_and_redirects(self) -> None:
        for host in ("http://host", "https://user:pass@host", "host/path", "host?token=x"):
            with self.subTest(host=host), self.assertRaises(app.InventoryError):
                app.Client(host, ssl.create_default_context(), 5, 100, "x", "40.0")
        self.assertIsNone(app.NoRedirects().redirect_request(None, None, 302, "", {}, "https://evil"))


@patch.dict("os.environ", {}, clear=True)
class OutputAndCliTests(unittest.TestCase):
    def test_missing_only_default_and_all_statuses(self) -> None:
        resources = [
            vm("a", powerState="ON"),
            {**vm("b"), "syncStatus": "MISSING"},
            {**vm("c"), "syncStatus": "FAILED"},
            {**vm("d"), "syncStatus": "UNKNOWN"},
            {**vm("e"), "syncStatus": None},
            {**vm("f"), "syncStatus": "MISSING"},
            {**vm("g", zoneId="other"), "syncStatus": "MISSING"},
            vm("h", powerState="MISSING", missing=True, __missing="true"),
        ]
        for flags, expected_ids in (
            ([], ["a", "f"]), (["--all"], ["a", "b", "c", "d", "e", "f", "h"]),
        ):
            with self.subTest(flags=flags), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "vms.csv"
                client = inventory_client(resources)
                # Selection must use fresh details rather than the resource-list state.
                client.responses[RESOURCES + "/a"] = [{**vm("a"), "syncStatus": "MiSsInG"}]
                client.responses[RESOURCES + "/b"] = [{**vm("b"), "syncStatus": "SUCCESS"}]
                with patch.object(app, "authenticated_client", return_value=client), \
                     self.assertLogs(app.LOG):
                    result = app.main([
                        "--host", "host", "--cloudzone", "Production",
                        "--output", str(path), *flags,
                    ])
                self.assertEqual(result, 0)
                with path.open(encoding="utf-8-sig", newline="") as handle:
                    rows = list(csv.DictReader(handle))
                self.assertEqual([item["vm_id"] for item in rows], expected_ids)
                self.assertEqual(rows[0]["status"], "missing")
                if flags:
                    self.assertEqual([item["status"] for item in rows],
                                     ["missing", "SUCCESS", "FAILED", "UNKNOWN", "unknown", "missing", "SUCCESS"])

    def test_default_without_missing_vms_writes_header_only(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "vms.csv"
            with patch.object(app, "authenticated_client", return_value=inventory_client([vm()])), \
                 self.assertLogs(app.LOG):
                result = app.main([
                    "--host", "host", "--cloudzone", "Production", "--output", str(path),
                ])
            self.assertEqual(result, 0)
            with path.open(encoding="utf-8-sig", newline="") as handle:
                self.assertEqual(list(csv.reader(handle)), [list(app.InventoryRow._fields)])

    def test_discovered_flag_removed(self) -> None:
        with patch("sys.stderr", new_callable=io.StringIO), self.assertRaises(SystemExit):
            app.parser().parse_args(["--host", "host", "--cloudzone", "Production", "--discovered"])

    def test_csv_shape_quoting_and_unicode(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "vms.csv"
            rows = [row(name='vm,"one"', status="missing"), row("b", name="vm-\u00e9")]
            app.write_csv(path, rows)
            with path.open(encoding="utf-8-sig", newline="") as handle:
                self.assertEqual(list(csv.reader(handle)), [
                    list(app.InventoryRow._fields), *[list(row) for row in rows],
                ])
            self.assertEqual(len(list(Path(directory).iterdir())), 1)

    def test_main_success_error_and_incomplete(self) -> None:
        for failure, unverified, expected in ((False, 0, 0), (True, 0, 1), (False, 1, 2)):
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "vms.csv"
                path.write_text("existing", encoding="utf-8")

                def collect(inventory: app.Inventory, zone: str, *,
                            include_all: bool = True) -> list[app.InventoryRow]:
                    if failure:
                        raise app.InventoryError("denied")
                    inventory.unverified = unverified
                    return []

                with patch.object(app.Client, "authenticate"), patch.object(
                    app.Inventory, "collect", collect,
                ), self.assertLogs(app.LOG):
                    result = app.main([
                        "--host", "example.invalid", "--username", "user@tenant",
                        "--password", "pass", "--cloudzone", "Production", "--output", str(path),
                    ])
                self.assertEqual(result, expected)
                if failure:
                    self.assertEqual(path.read_text(encoding="utf-8"), "existing")
                else:
                    self.assertEqual(path.read_text(encoding="utf-8-sig").strip(),
                                     ",".join(app.InventoryRow._fields))

    def test_environment_api_token(self) -> None:
        with patch.dict("os.environ", {"VCFA_API_TOKEN": "secret"}):
            args = app.parser().parse_args(["--host", "host", "--cloudzone", "Production"])
            self.assertEqual(args.api_token, "secret")


if __name__ == "__main__":
    unittest.main()
