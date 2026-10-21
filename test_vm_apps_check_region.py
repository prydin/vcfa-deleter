import unittest
from unittest.mock import patch
import io
import json

import vm_apps_check_region as check
from test_vm_apps_inventory import inventory_client, ZONE
from vm_apps_inventory import InventoryError


@patch.dict("os.environ", {}, clear=True)
class RegionCheckTests(unittest.TestCase):
    def test_prints_only_selected_identifiers_without_assuming_name_is_provider_id(self) -> None:
        client = inventory_client([])
        client.responses["/iaas/api/regions/region-1"] = [{
            "id": "region-1", "name": "vcf-lab-dc-01",
            "externalRegionId": "Datacenter:datacenter-3",
            "cloudAccountId": "account-1", "unrelated": "not printed",
        }]
        with patch.object(check, "authenticated_client", return_value=client), \
             patch("sys.stdout", new_callable=io.StringIO) as output:
            result = check.main([
                "--host", "example.invalid", "--legacy", "--api-token", "test-refresh",
                "--cloudzone", "Production",
            ])
        self.assertEqual(result, 0)
        record = json.loads(output.getvalue())
        self.assertEqual(record["region"], {
            "id": "region-1", "name": "vcf-lab-dc-01",
            "externalRegionId": "Datacenter:datacenter-3", "cloudAccountId": "account-1",
        })
        self.assertEqual(record["cloudzone"], {"id": "zone-1", "name": "Production"})
        self.assertEqual([path for path, _ in client.calls], [
            "/iaas/api/zones", "/iaas/api/zones/zone-1", "/iaas/api/regions/region-1",
        ])

    def test_rejects_missing_duplicate_or_changed_zone(self) -> None:
        for zones in ([], [ZONE, {**ZONE, "id": "other"}]):
            client = inventory_client([])
            client.responses["/iaas/api/zones"] = [{"content": zones, "totalElements": len(zones)}]
            with self.subTest(zones=zones), self.assertRaises(InventoryError):
                check.check_region(client, "Production")
        client = inventory_client([])
        client.responses["/iaas/api/zones/zone-1"] = [{**ZONE, "name": "changed"}]
        with self.assertRaisesRegex(InventoryError, "changed"):
            check.check_region(client, "Production")

    def test_rejects_unexpected_region_link_without_following_it(self) -> None:
        client = inventory_client([])
        client.responses["/iaas/api/zones/zone-1"] = [{
            **ZONE, "_links": {"region": {"href": "https://elsewhere/region"}},
        }]
        with self.assertRaisesRegex(InventoryError, "Unsupported"):
            check.check_region(client, "Production")

    def test_authentication_error_produces_no_success_output(self) -> None:
        with patch.object(check, "authenticated_client", side_effect=InventoryError("denied")), \
             patch("sys.stdout", new_callable=io.StringIO) as output, self.assertLogs(check.LOG):
            self.assertEqual(check.main([
                "--host", "host", "--cloudzone", "Production",
            ]), 1)
        self.assertEqual(output.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
