#!/usr/bin/env python3
"""Print a cloud zone's region identifiers for placement troubleshooting."""

from __future__ import annotations

import argparse
import json
import logging
import sys

from vm_apps_inventory import (
    Client, InventoryError, Record, add_connection_arguments, authenticated_client,
    identifier, object_record, properties, required_text, text,
)


LOG = logging.getLogger("vm_apps_check_region")


def check_region(client: Client, cloudzone: str) -> Record:
    matches = [
        zone for zone in client.records("/iaas/api/zones")
        if text(zone, "name") == cloudzone
    ]
    if len(matches) != 1:
        raise InventoryError(
            f"Expected one visible cloud zone named {cloudzone!r}; found {len(matches)}"
        )
    zone_id = required_text(matches[0], "id", "cloud zone")
    zone = client.get(f"/iaas/api/zones/{identifier(zone_id)}")
    if text(zone, "id") != zone_id or text(zone, "name") != cloudzone:
        raise InventoryError("Cloud zone changed during lookup; rerun")
    link = object_record(properties(zone, "_links").get("region"), "cloud zone region link")
    path = required_text(link, "href", "cloud zone region link")
    if not path.startswith("/iaas/api/regions/") or "?" in path or "#" in path:
        raise InventoryError("Unsupported cloud-zone region link")
    region = client.get(path)
    return {
        "cloudzone": {"id": zone_id, "name": cloudzone},
        "region_path": path,
        "region": {
            key: text(region, key)
            for key in ("id", "name", "externalRegionId", "cloudAccountId")
        },
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    add_connection_arguments(parser)
    parser.add_argument("--cloudzone", required=True, help="Exact, case-sensitive cloud-zone name")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    try:
        result = check_region(authenticated_client(args), args.cloudzone)
        print(json.dumps(result, indent=2))
        return 0
    except (InventoryError, OSError, EOFError) as exc:
        LOG.error("%s", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
