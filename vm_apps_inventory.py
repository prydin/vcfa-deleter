#!/usr/bin/env python3
"""Export VM Apps machines with individually verified cloud-zone membership."""

from __future__ import annotations

import argparse
import base64
import csv
import getpass
import json
import logging
import math
import os
from pathlib import Path
import ssl
import sys
import tempfile
from typing import Iterator, NamedTuple
from urllib.error import HTTPError, URLError
from urllib.parse import quote, unquote, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener, HTTPSHandler


LOG = logging.getLogger("vm_apps_inventory")
Record = dict[str, object]


class InventoryRow(NamedTuple):
    vm_name: str
    deployment_name: str
    status: str
    vm_id: str
    resource_id: str
    deployment_id: str
    cloudzone: str
    cloudzone_id: str


def is_vm(resource: Record) -> bool:
    resource_type = text(resource, "type")
    return resource_type.startswith("Cloud.") and resource_type.endswith(".Machine")


class InventoryError(Exception):
    """An API or inventory consistency error."""


class ApiError(InventoryError):
    def __init__(self, method: str, path: str, status: int) -> None:
        self.status = status
        super().__init__(f"{method} {path}: HTTP {status}")


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def object_record(value: object, context: str) -> Record:
    if not isinstance(value, dict):
        raise InventoryError(f"{context}: expected a JSON object")
    return value


def text(record: Record, key: str) -> str:
    value = record.get(key)
    return value.strip() if isinstance(value, str) else ""


def required_text(record: Record, key: str, context: str) -> str:
    value = text(record, key)
    if not value:
        raise InventoryError(f"{context}: missing or invalid {key}")
    return value


def properties(record: Record, key: str) -> Record:
    value = record.get(key)
    return {} if value is None else object_record(value, key)


def identifier(value: str) -> str:
    return quote(value, safe="")


class Client:
    def __init__(
        self, host: str, context: ssl.SSLContext, timeout: float,
        page_size: int, api_version: str, cloudapi_version: str,
    ) -> None:
        parsed = urlsplit(host if "://" in host else f"https://{host}")
        if (
            parsed.scheme != "https" or not parsed.netloc or parsed.username
            or parsed.password or parsed.path not in ("", "/")
            or parsed.query or parsed.fragment
        ):
            raise InventoryError("--host must be an HTTPS hostname or origin, without a path")
        self.base = f"https://{parsed.netloc}"
        self.opener = build_opener(HTTPSHandler(context=context), NoRedirects())
        self.timeout = timeout
        self.page_size = page_size
        self.api_version = api_version
        self.cloudapi_version = cloudapi_version
        self.token = ""

    def request(
        self, method: str, path: str, *, params: Record | None = None,
        data: bytes | None = None, headers: dict[str, str] | None = None,
    ) -> tuple[bytes, dict[str, str]]:
        if not path.startswith("/") or path.startswith("//"):
            raise InventoryError("API paths must be relative to the configured host")
        query = dict(params or {})
        if path.startswith("/iaas/"):
            query["apiVersion"] = self.api_version
        url = self.base + path
        if query:
            url += "?" + urlencode(query)
        request_headers = {"Accept": "application/json"}
        if self.token:
            request_headers["Authorization"] = f"Bearer {self.token}"
        request_headers.update(headers or {})
        request = Request(url, data=data, headers=request_headers, method=method)
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                return response.read(), {k.lower(): v for k, v in response.headers.items()}
        except HTTPError as exc:
            exc.close()
            # Do not echo server bodies, request headers, or credential-bearing URLs.
            raise ApiError(method, path, exc.code) from None
        except (URLError, TimeoutError, OSError) as exc:
            raise InventoryError(
                f"{method} {path}: connection/TLS failure ({type(exc).__name__}); "
                "check connectivity and the CA certificate"
            ) from None

    def get(self, path: str, params: Record | None = None) -> Record:
        body, _ = self.request("GET", path, params=params)
        return self.decode(body, path)

    @staticmethod
    def decode(body: bytes, context: str) -> Record:
        try:
            return object_record(json.loads(body), context)
        except (ValueError, UnicodeError):
            raise InventoryError(f"{context}: invalid JSON response") from None

    def authenticate(self, args: argparse.Namespace) -> None:
        if args.api_token:
            if not args.org:
                raise InventoryError("--org is required for an organization API token")
            body, _ = self.request(
                "POST", f"/oauth/tenant/{identifier(args.org)}/token",
                data=urlencode({
                    "grant_type": "refresh_token", "refresh_token": args.api_token,
                }).encode("utf-8"),
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            )
            self.token = required_text(
                self.decode(body, "token exchange"), "access_token", "token exchange",
            )
        else:
            principal = args.username
            if args.org and not principal.endswith(f"@{args.org}"):
                principal += f"@{args.org}"
            if not args.org and "@" not in principal:
                raise InventoryError("Use --org or an organization-qualified username")
            password = args.password if args.password is not None else getpass.getpass()
            basic = base64.b64encode(f"{principal}:{password}".encode("utf-8")).decode("ascii")
            _, headers = self.request(
                "POST", "/cloudapi/1.0.0/sessions",
                headers={
                    "Authorization": f"Basic {basic}",
                    "Accept": f"application/json;version={self.cloudapi_version}",
                },
                data=b"",
            )
            self.token = headers.get("x-vmware-vcloud-access-token", "")
            if not self.token:
                raise InventoryError("Session response omitted X-VMWARE-VCLOUD-ACCESS-TOKEN")

    def records(self, path: str) -> Iterator[Record]:
        offset = 0
        page_number = 0
        spring = path.startswith("/deployment/")
        seen: set[str] = set()
        while True:
            params = (
                {"page": page_number, "size": self.page_size} if spring
                else {"$top": self.page_size, "$skip": offset}
            )
            page = self.get(path, params)
            content = page.get("content")
            if not isinstance(content, list):
                raise InventoryError(f"{path}: expected a content array")
            if not content:
                total = page.get("totalElements")
                if isinstance(total, int) and offset < total:
                    raise InventoryError(f"{path}: pagination ended before totalElements")
                return
            for value in content:
                record = object_record(value, path)
                record_id = required_text(record, "id", path)
                if record_id in seen:
                    raise InventoryError(
                        f"{path}: repeated ID {record_id}; pagination/inventory changed, rerun"
                    )
                seen.add(record_id)
                yield record
            # Continue even on a short page: the server may cap $top.
            offset += len(content)
            page_number += 1
            total = page.get("totalElements")
            if isinstance(total, int) and offset >= total:
                return
            if spring and page.get("last") is True:
                if isinstance(total, int) and offset < total:
                    raise InventoryError(f"{path}: last page ended before totalElements")
                return


def zone_membership(
    record: Record, zone: Record, *, allow_names: bool = True,
) -> bool | None:
    """None means no explicit zone evidence; never equate externalZoneId with zone ID."""
    zone_id = required_text(zone, "id", "cloud zone")
    zone_name = required_text(zone, "name", "cloud zone")
    sources = [record, properties(record, "customProperties"), properties(record, "properties")]
    ids = {
        value for source in sources for key in ("zoneId", "cloudZoneId")
        if (value := text(source, key))
    }
    links = properties(record, "_links")
    for key in ("zone", "cloud-zone"):
        if key in links:
            link = object_record(links[key], f"_links.{key}")
            href = required_text(link, "href", f"_links.{key}")
            path = urlsplit(href).path.rstrip("/")
            if path.startswith("/iaas/api/zones/"):
                ids.add(unquote(path.rsplit("/", 1)[-1]))
            else:
                raise InventoryError(f"Unsupported cloud-zone link: {path}")
    if ids:
        if len(ids) != 1:
            raise InventoryError("Conflicting explicit cloud-zone IDs in a VM record")
        return zone_id in ids
    if not allow_names:
        return None
    names = {
        value for source in sources for key in ("zone", "zoneName", "cloudZoneName")
        if key != "zone" or not text(source, "computeHostRef")
        if (value := text(source, key))
    }
    if names:
        if len(names) != 1:
            raise InventoryError("Conflicting explicit cloud-zone names in a VM record")
        return zone_name in names
    return None


def sync_status(resource: Record) -> str:
    state = text(resource, "syncStatus")
    if state:
        return "missing" if state.casefold() == "missing" else state
    LOG.warning("VM %s has no valid syncStatus; reporting unknown", text(resource, "id"))
    return "unknown"


class Inventory:
    def __init__(self, client: Client) -> None:
        self.client = client
        self.unverified = 0
        self.zone_computes: list[Record] | None = None
        self.zone_region: Record | None = None

    def compute_membership(self, resource: Record, zone: Record) -> bool | None:
        recorded = properties(resource, "properties")
        reference = text(recorded, "computeHostRef")
        if not reference:
            return None
        if self.zone_region is None:
            links = properties(zone, "_links")
            region_link = object_record(links.get("region"), "cloud zone region link")
            path = required_text(region_link, "href", "cloud zone region link")
            if not path.startswith("/iaas/api/regions/"):
                raise InventoryError("Unsupported cloud-zone region link")
            self.zone_region = self.client.get(path)
        region = self.zone_region
        account = required_text(region, "cloudAccountId", "cloud zone region")
        region_id = required_text(region, "externalRegionId", "cloud zone region")
        endpoint = text(recorded, "endpointId")
        datacenter = text(recorded, "datacenter")
        if not endpoint or not datacenter:
            return None
        if endpoint != account or datacenter != region_id:
            return False
        if self.zone_computes is None:
            zone_id = required_text(zone, "id", "cloud zone")
            self.zone_computes = list(self.client.records(
                f"/iaas/api/zones/{identifier(zone_id)}/computes"
            ))
        aliases = {"Cluster": "ClusterComputeResource"}
        for compute in self.zone_computes:
            compute_type = text(compute, "type")
            expected = f"{aliases.get(compute_type, compute_type)}:{text(compute, 'externalId')}"
            if expected != reference:
                continue
            if text(compute, "externalRegionId") != region_id:
                raise InventoryError("Zone compute has a conflicting region")
            vc_uuid = text(properties(compute, "customProperties"), "vcUuid")
            resource_vc = text(recorded, "vcUuid")
            if not vc_uuid or not resource_vc:
                return None
            if vc_uuid != resource_vc:
                raise InventoryError("Zone compute and VM reference different vCenters")
            return True
        return False

    def collect(self, cloudzone: str, *, include_all: bool = True) -> list[InventoryRow]:
        matches = [
            zone for zone in self.client.records("/iaas/api/zones")
            if text(zone, "name") == cloudzone
        ]
        if len(matches) != 1:
            raise InventoryError(
                f"Expected one visible cloud zone named {cloudzone!r}; found {len(matches)}"
            )
        zone_id = required_text(matches[0], "id", "cloud zone")
        zone = self.client.get(f"/iaas/api/zones/{identifier(zone_id)}")
        if text(zone, "id") != zone_id or text(zone, "name") != cloudzone:
            raise InventoryError("Cloud zone changed during lookup; rerun")
        rows: list[InventoryRow] = []
        seen_machines: set[str] = set()
        for deployment in self.client.records("/deployment/api/deployments"):
            dep_id = required_text(deployment, "id", "deployment")
            dep_name = required_text(deployment, "name", f"Deployment {dep_id}")
            path = f"/deployment/api/deployments/{identifier(dep_id)}/resources"
            for candidate in self.client.records(path):
                resource_type = text(candidate, "type")
                if not is_vm(candidate):
                    continue
                resource_id = required_text(candidate, "id", "deployment resource")
                try:
                    resource = self.client.get(f"{path}/{identifier(resource_id)}")
                except ApiError as exc:
                    if exc.status != 404:
                        raise
                    LOG.warning("VM resource %s disappeared; membership unverified", resource_id)
                    self.unverified += 1
                    continue
                if text(resource, "id") != resource_id or text(resource, "type") != resource_type:
                    raise InventoryError("Deployment resource identity/type changed; rerun")
                recorded = properties(resource, "properties")
                machine_id = text(recorded, "resourceId") or resource_id
                old_machine_id = text(properties(candidate, "properties"), "resourceId")
                if old_machine_id and old_machine_id != machine_id:
                    raise InventoryError("Deployment resource changed its machine association; rerun")
                if machine_id in seen_machines:
                    raise InventoryError(f"VM {machine_id} appears in multiple deployment resources")
                seen_machines.add(machine_id)
                membership = zone_membership(resource, zone)
                if membership is None:
                    membership = self.compute_membership(resource, zone)
                if membership is False:
                    continue
                if membership is None:
                    LOG.warning("VM resource %s: zone membership unverified; excluded", resource_id)
                    self.unverified += 1
                    continue
                status = sync_status(resource)
                if not include_all and status.casefold() != "missing":
                    continue
                name = text(recorded, "resourceName")
                if not name:
                    # Resource name is a blueprint component label, not necessarily the VM name.
                    try:
                        machine = self.client.get(f"/iaas/api/machines/{identifier(machine_id)}")
                    except ApiError as exc:
                        if exc.status != 404:
                            raise
                        LOG.warning("VM resource %s has no recorded VM name; excluded", resource_id)
                        self.unverified += 1
                        continue
                    if text(machine, "id") != machine_id:
                        raise InventoryError("Machine detail returned a different ID")
                    name = required_text(machine, "name", f"VM {machine_id}")
                rows.append(InventoryRow(
                    name, dep_name, status, machine_id, resource_id,
                    dep_id, cloudzone, zone_id,
                ))
        return sorted(rows, key=lambda row: (row[0].casefold(), row[1].casefold()))


def write_csv(path: Path, rows: list[InventoryRow]) -> None:
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8-sig", newline="", dir=path.parent,
            prefix=f".{path.name}.", suffix=".tmp", delete=False,
        ) as handle:
            temporary = Path(handle.name)
            writer = csv.writer(handle)
            writer.writerow(InventoryRow._fields)
            writer.writerows(rows)
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def positive_float(value: str) -> float:
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be a finite positive number")
    return number


def positive_int(value: str) -> int:
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def add_connection_arguments(result: argparse.ArgumentParser) -> None:
    result.add_argument("--host", required=True, help="VCF Automation HTTPS host")
    auth = result.add_mutually_exclusive_group()
    auth.add_argument("--api-token", default=os.environ.get("VCFA_API_TOKEN"),
                      help="Organization API refresh token; also VCFA_API_TOKEN")
    auth.add_argument("--username", help="Organization user; password is prompted if omitted")
    result.add_argument("--password", default=os.environ.get("VCFA_PASSWORD"))
    result.add_argument("--org", help="Organization name (required with --api-token)")
    result.add_argument("--api-version", default="2021-07-15", help="IaaS API version")
    result.add_argument("--cloudapi-version", default="40.0", help="Session API version")
    result.add_argument("--page-size", type=positive_int, default=100)
    result.add_argument("--timeout", type=positive_float, default=60)
    tls = result.add_mutually_exclusive_group()
    tls.add_argument("--ca-bundle", help="PEM CA certificate bundle")
    tls.add_argument("--insecure", action="store_true", help="Disable TLS verification (unsafe)")


def authenticated_client(args: argparse.Namespace) -> Client:
    if not args.api_token and not args.username:
        raise InventoryError("Provide --api-token, VCFA_API_TOKEN, or --username")
    if args.api_token and args.username:
        raise InventoryError("Do not combine VCFA_API_TOKEN/--api-token with --username")
    if args.api_token and args.password is not None:
        raise InventoryError("--password/VCFA_PASSWORD cannot be combined with --api-token")
    context = ssl.create_default_context(cafile=args.ca_bundle)
    if args.insecure:
        LOG.warning("TLS certificate verification is disabled")
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
    client = Client(
        args.host, context, args.timeout, args.page_size,
        args.api_version, args.cloudapi_version,
    )
    client.authenticate(args)
    return client


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    add_connection_arguments(result)
    result.add_argument("--cloudzone", required=True, help="Exact, case-sensitive cloud-zone name")
    result.add_argument("--all", action="store_true",
                        help="Include all VM syncStatus values (default: Missing only)")
    result.add_argument("--output", type=Path, default=Path("vm_inventory.csv"))
    return result


def main(argv: list[str] | None = None) -> int:
    arg_parser = parser()
    args = arg_parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    try:
        client = authenticated_client(args)
        inventory = Inventory(client)
        rows = inventory.collect(args.cloudzone, include_all=args.all)
        write_csv(args.output, rows)
        LOG.info("Wrote %d verified VM(s) to %s", len(rows), args.output)
        if inventory.unverified:
            LOG.error("INCOMPLETE: %d VM(s) could not be verified", inventory.unverified)
            return 2
        return 0
    except (InventoryError, OSError, EOFError) as exc:
        LOG.error("%s", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
